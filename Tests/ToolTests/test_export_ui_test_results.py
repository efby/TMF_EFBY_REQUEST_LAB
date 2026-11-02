import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).resolve().parents[2] / "Tools" / "export_ui_test_results.py"
SPEC = importlib.util.spec_from_file_location("export_ui_test_results", SCRIPT)
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)


def case(name, result="Passed", **extra):
    identifier = f"RequestLabUITests/{name}()"
    return {
        "nodeType": "Test Case", "name": f"{name}()", "result": result,
        "nodeIdentifier": identifier, "nodeIdentifierURL": f"test://bundle/{identifier}",
        "durationInSeconds": 1.25, **extra,
    }


def reports(cases):
    results = [item["result"] for item in cases]
    summary = {
        "title": "UI tests", "result": "Failed" if "Failed" in results else "Passed",
        "totalTestCount": len(cases), "passedTests": results.count("Passed"),
        "failedTests": results.count("Failed"), "skippedTests": results.count("Skipped"),
        "expectedFailures": results.count("Expected Failure"), "testFailures": [],
    }
    tree = {"testNodes": [{"nodeType": "Test Plan", "name": "Test plan", "children": [
        {"nodeType": "UI test bundle", "name": "EfbyRequestLabUITests", "children": [
            {"nodeType": "Test Suite", "name": "RequestLabUITests", "children": cases}
        ]}
    ]}]}
    return summary, tree


class ExportUITestResultsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="efby-ui-export-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "UI.xcresult"
        self.bundle.mkdir()
        self.output = self.root / "reports"
        self.commands = []

    def fake_xcrun(self, summary, tree, attachment_error=False):
        def run(command, **options):
            self.commands.append(command)
            self.assertEqual(command[:2], ["xcrun", "xcresulttool"])
            self.assertTrue(options["capture_output"])
            self.assertTrue(options["text"])
            if command[2:4] == ["export", "attachments"]:
                if attachment_error:
                    return subprocess.CompletedProcess(command, 1, "", "Attachment extraction failed")
                output = Path(command[command.index("--output-path") + 1])
                output.mkdir(parents=True)
                (output / "failure.png").write_bytes(b"test screenshot")
                (output / "hierarchy.txt").write_text("UI hierarchy", encoding="utf-8")
                (output / "manifest.json").write_text("[]", encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "Exported attachments", "")
            report = summary if command[4] == "summary" else tree
            return subprocess.CompletedProcess(command, 0, json.dumps(report), "")
        return run

    def test_passed_tests_generate_junit_and_readable_report(self):
        summary, tree = reports([case("testNavigation"), case("testTabs")])
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree)):
            result = exporter.main(["--result-bundle", str(self.bundle), "--output-directory", str(self.output), "--test-exit-code", "0"])
        self.assertEqual(result, 0)
        xml = ET.parse(self.output / "junit.xml").getroot()
        self.assertEqual(xml.attrib["tests"], "2")
        self.assertEqual(xml.attrib["failures"], "0")
        self.assertEqual(xml.attrib["skipped"], "0")
        self.assertEqual(xml.attrib["time"], "2.500000")
        self.assertEqual(xml[0].attrib["classname"], "RequestLabUITests")
        self.assertIn("Result: **Passed**", (self.output / "summary.md").read_text())
        self.assertEqual(json.loads((self.output / "summary.json").read_text()), summary)
        self.assertEqual(len(self.commands), 2)

    def test_failed_test_exports_custom_attachments_by_test_instead_of_failure_flag(self):
        failed = case("testCancel", "Failed", children=[{"nodeType": "Failure Message", "name": "Expected idle <after> cancellation & retry\u0001"}])
        summary, tree = reports([case("testSend"), failed, case("testExternal", "Skipped")])
        summary["testFailures"] = [{"testIdentifierString": failed["nodeIdentifier"], "failureText": "Server connection stayed open."}]
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree)):
            result = exporter.export_results(self.bundle, self.output, exit_code=65)
        self.assertEqual(result, 0, "Export success must not replace the separately retained runner exit code")
        xml = ET.parse(self.output / "junit.xml").getroot()
        self.assertEqual(xml.attrib["tests"], "3")
        self.assertEqual(xml.attrib["failures"], "1")
        self.assertEqual(xml.attrib["skipped"], "1")
        failure = xml.findall("testcase")[1].find("failure")
        self.assertIn("Server connection stayed open.", failure.text)
        self.assertIn("Expected idle <after> cancellation & retry\ufffd", failure.text)
        command = self.commands[-1]
        self.assertEqual(command[command.index("--test-id") + 1], failed["nodeIdentifierURL"])
        self.assertNotIn("--only-failures", command)
        self.assertTrue((self.output / "attachments/failed-test-001/failure.png").is_file())
        self.assertTrue((self.output / "attachments/failed-test-001/hierarchy.txt").is_file())
        self.assertIn("Test runner exit code: `65`", (self.output / "summary.md").read_text())

    def test_expected_failure_is_reported_as_skipped_not_an_unexpected_failure(self):
        summary, tree = reports([case("testKnownIssue", "Expected Failure")])
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree)):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 0)
        xml = ET.parse(self.output / "junit.xml").getroot()
        self.assertEqual(xml.attrib["failures"], "0")
        self.assertEqual(xml.attrib["skipped"], "1")
        self.assertEqual(xml.find("testcase/skipped").attrib["message"], "Expected Failure")

    def test_missing_bundle_records_no_tests_and_returns_failure(self):
        with patch.object(exporter.subprocess, "run") as run:
            self.assertEqual(exporter.export_results(self.root / "missing.xcresult", self.output, exit_code=1), 1)
        run.assert_not_called()
        xml = ET.parse(self.output / "junit.xml").getroot()
        self.assertEqual(xml.attrib["tests"], "0")
        self.assertEqual(xml.findall("testcase"), [])
        self.assertIn("No result bundle", xml.find("system-err").text)
        self.assertIn("not a successful test run", (self.output / "summary.md").read_text())

    def test_malformed_json_cannot_create_a_successful_report(self):
        with patch.object(exporter.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "{broken", "")):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 1)
        self.assertIn("Report incomplete", (self.output / "summary.md").read_text())
        self.assertIn("Invalid summary JSON", (self.output / "export-errors.txt").read_text())

    def test_counts_mismatch_is_a_report_failure(self):
        summary, tree = reports([case("testOnly")])
        summary["totalTestCount"] = 6
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree)):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 1)
        self.assertIn("counts do not match", (self.output / "export-errors.txt").read_text())

    def test_empty_result_bundle_is_not_treated_as_passing_tests(self):
        summary, tree = reports([])
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree)):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 1)
        self.assertIn("no executed or skipped test cases", (self.output / "export-errors.txt").read_text())

    def test_attachment_failure_keeps_summary_and_fails_export(self):
        summary, tree = reports([case("testFailed", "Failed")])
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree, attachment_error=True)):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 1)
        self.assertTrue((self.output / "junit.xml").is_file())
        self.assertTrue((self.output / "tests.json").is_file())
        self.assertIn("Attachment extraction failed", (self.output / "export-errors.txt").read_text())

    def test_attachment_failure_does_not_prevent_exporting_other_failed_cases(self):
        summary, tree = reports([case("testFirst", "Failed"), case("testSecond", "Failed")])
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree, attachment_error=True)):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 1)
        attachment_commands = [command for command in self.commands if command[2:4] == ["export", "attachments"]]
        self.assertEqual(len(attachment_commands), 2)
        self.assertIn("testFirst", attachment_commands[0][attachment_commands[0].index("--test-id") + 1])
        self.assertIn("testSecond", attachment_commands[1][attachment_commands[1].index("--test-id") + 1])

    def test_missing_xcrun_is_diagnostic_instead_of_uncaught_exception(self):
        with patch.object(exporter.subprocess, "run", side_effect=FileNotFoundError("xcrun not found")):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 1)
        self.assertIn("Could not run xcresulttool", (self.output / "export-errors.txt").read_text())

    def test_output_cannot_overwrite_old_reports_or_modify_input_bundle(self):
        self.output.mkdir()
        marker = self.output / "old-report.txt"
        marker.write_text("keep me", encoding="utf-8")
        with self.assertRaisesRegex(exporter.ExportError, "new or empty"):
            exporter.export_results(self.bundle, self.output)
        self.assertEqual(marker.read_text(), "keep me")
        with self.assertRaisesRegex(exporter.ExportError, "outside the result bundle"):
            exporter.export_results(self.bundle, self.bundle / "reports")

    def test_malformed_test_node_is_diagnostic(self):
        summary, tree = reports([case("testBroken", children=["not a node"])])
        with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree)):
            self.assertEqual(exporter.export_results(self.bundle, self.output), 1)
        self.assertIn("Malformed test node", (self.output / "export-errors.txt").read_text())

    def test_malformed_failure_fields_are_reported_without_a_traceback(self):
        broken_cases = [
            case("testMalformedResult", result={"unexpected": "object"}),
            case("testMalformedFailure", "Failed", children=[{"nodeType": "Failure Message", "name": {"unexpected": "object"}}]),
            case("testMalformedURL", nodeIdentifierURL={"unexpected": "object"}),
        ]
        for index, broken in enumerate(broken_cases):
            with self.subTest(index=index):
                summary, tree = reports([case("placeholder")])
                tree["testNodes"][0]["children"][0]["children"][0]["children"] = [broken]
                output = self.root / f"malformed-{index}"
                with patch.object(exporter.subprocess, "run", side_effect=self.fake_xcrun(summary, tree)):
                    self.assertEqual(exporter.export_results(self.bundle, output), 1)
                self.assertTrue((output / "export-errors.txt").is_file())

    def test_human_duration_fallback_preserves_elapsed_time(self):
        self.assertEqual(exporter.duration_seconds({"duration": "1m 2.5s"}), 62.5)
        with self.assertRaises(exporter.ExportError):
            exporter.duration_seconds({"durationInSeconds": float("nan")})


if __name__ == "__main__":
    unittest.main()
