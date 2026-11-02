#!/usr/bin/env python3
"""Export a macOS XCTest result bundle without concealing the test runner's result."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


class ExportError(Exception):
    pass


def run_xcresult(arguments):
    command = ["xcrun", "xcresulttool", *arguments]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ExportError(f"Could not run xcresulttool: {error}") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "No diagnostic output"
        raise ExportError(f"xcresulttool exited {result.returncode}: {detail}")
    return result.stdout


def read_report(kind, bundle):
    raw = run_xcresult(["get", "test-results", kind, "--path", str(bundle)])
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ExportError(f"Invalid {kind} JSON from xcresulttool: {error}") from error
    if not isinstance(value, dict):
        raise ExportError(f"Expected an object for the {kind} report")
    return value


def duration_seconds(node):
    duration = node.get("durationInSeconds")
    if isinstance(duration, (int, float)) and not isinstance(duration, bool):
        if math.isfinite(duration) and duration >= 0:
            return float(duration)
        raise ExportError("Test duration must be finite and nonnegative")
    text = node.get("duration", "")
    if not isinstance(text, str):
        raise ExportError("Invalid test duration")
    units = {"d": 86400, "h": 3600, "m": 60, "s": 1}
    return sum(float(number) * units[unit] for number, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([dhms])", text))


def failure_messages(node):
    if not isinstance(node, dict) or not isinstance(node.get("children", []), list):
        raise ExportError("Malformed test node")
    messages = []
    if node.get("nodeType") == "Failure Message":
        for value in [node.get("name"), node.get("details")]:
            if value is not None and not isinstance(value, str):
                raise ExportError("Malformed failure message")
            if value:
                messages.append(value)
    for child in node.get("children", []):
        messages.extend(failure_messages(child))
    return list(dict.fromkeys(messages))


def test_cases(report):
    if not isinstance(report.get("testNodes"), list):
        raise ExportError("The tests report has no testNodes array")
    cases = []

    def visit(node, suite="UI tests"):
        if not isinstance(node, dict) or not isinstance(node.get("children", []), list):
            raise ExportError("Malformed test node")
        if node.get("nodeType") == "Test Suite":
            suite = node.get("name", suite)
        if node.get("nodeType") == "Test Case":
            name = node.get("name")
            identifier = node.get("nodeIdentifier")
            result = node.get("result")
            if not isinstance(name, str) or not name or not isinstance(identifier, str) or not identifier:
                raise ExportError("A test case is missing its name or identifier")
            if not isinstance(result, str) or result not in {"Passed", "Failed", "Skipped", "Expected Failure"}:
                raise ExportError(f"Unknown result for {identifier}: {result!r}")
            identifier_url = node.get("nodeIdentifierURL") or identifier
            if not isinstance(identifier_url, str):
                raise ExportError(f"Invalid test identifier URL for {identifier}")
            cases.append({
                "name": name, "identifier": identifier,
                "identifierURL": identifier_url,
                "class": suite, "result": result, "duration": duration_seconds(node),
                "failures": failure_messages(node),
            })
            return
        for child in node.get("children", []):
            visit(child, suite)

    for root in report["testNodes"]:
        visit(root)
    return cases


def validate_summary(summary, cases):
    if not isinstance(summary.get("result"), str) or summary["result"] not in {"Passed", "Failed", "Skipped", "Expected Failure"}:
        raise ExportError("Invalid or missing summary result")
    keys = ["totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"]
    for key in keys:
        if not isinstance(summary.get(key), int) or isinstance(summary[key], bool) or summary[key] < 0:
            raise ExportError(f"Invalid or missing summary count: {key}")
    counts = Counter(case["result"] for case in cases)
    expected = {"passedTests": "Passed", "failedTests": "Failed", "skippedTests": "Skipped", "expectedFailures": "Expected Failure"}
    if summary["totalTestCount"] != len(cases) or any(summary[key] != counts[result] for key, result in expected.items()):
        raise ExportError("The summary and test-case counts do not match")
    if not cases:
        raise ExportError("The result bundle contains no executed or skipped test cases")


def attach_failure_details(summary, cases):
    failures = summary.get("testFailures", [])
    if isinstance(failures, dict):
        failures = [failures]
    if not isinstance(failures, list):
        raise ExportError("Invalid testFailures in summary")
    for case in cases:
        for failure in failures:
            if not isinstance(failure, dict):
                raise ExportError("Malformed failure in summary")
            if any(failure.get(key) is not None and not isinstance(failure[key], str)
                   for key in ["testIdentifierString", "testIdentifierURL", "failureText"]):
                raise ExportError("Malformed failure fields in summary")
            identifiers = {failure.get("testIdentifierString"), failure.get("testIdentifierURL")}
            if case["identifier"] in identifiers or case["identifierURL"] in identifiers:
                if failure.get("failureText"):
                    case["failures"].append(failure["failureText"])
        case["failures"] = list(dict.fromkeys(case["failures"]))


def xml_text(value):
    return re.sub(r"[^\x09\x0a\x0d\x20-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]", "\ufffd", str(value))


def write_junit(destination, cases, diagnostic=None):
    counts = Counter(case["result"] for case in cases)
    suite = ET.Element("testsuite", {
        "name": "EfbyRequestLabUITests", "tests": str(len(cases)),
        "failures": str(counts["Failed"]), "errors": "0",
        "skipped": str(counts["Skipped"] + counts["Expected Failure"]),
        "time": f"{sum(case['duration'] for case in cases):.6f}",
    })
    for case in cases:
        item = ET.SubElement(suite, "testcase", {
            "classname": xml_text(case["class"]), "name": xml_text(case["name"]),
            "time": f"{case['duration']:.6f}",
        })
        if case["result"] == "Failed":
            message = "\n".join(case["failures"]) or "XCTest reported a failure. Open the .xcresult bundle for details."
            failure = ET.SubElement(item, "failure", {"type": "XCTestFailure", "message": xml_text(message)})
            failure.text = xml_text(message)
        elif case["result"] in {"Skipped", "Expected Failure"}:
            ET.SubElement(item, "skipped", {"message": case["result"]})
    if diagnostic:
        ET.SubElement(suite, "system-err").text = xml_text(diagnostic)
    ET.indent(suite)
    ET.ElementTree(suite).write(destination, encoding="utf-8", xml_declaration=True)


def markdown_text(value):
    return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def write_markdown(destination, summary, cases, errors, exit_code):
    result = "Report incomplete" if errors else summary.get("result", "Unavailable")
    lines = ["## macOS UI tests", "", f"Result: **{markdown_text(result)}**", ""]
    if exit_code is not None:
        lines.extend([f"Test runner exit code: `{exit_code}`.", ""])
    if cases:
        counts = Counter(case["result"] for case in cases)
        lines.extend([
            f"{len(cases)} tests: {counts['Passed']} passed, {counts['Failed']} failed, "
            f"{counts['Skipped']} skipped, {counts['Expected Failure']} expected failures.", "",
            "| Test | Result | Seconds |", "| --- | --- | ---: |",
        ])
        lines.extend(f"| {markdown_text(case['identifier'])} | {case['result']} | {case['duration']:.3f} |" for case in cases)
        lines.append("")
    else:
        lines.extend(["No test-case results are available; this is not a successful test run.", ""])
    for error in errors:
        lines.extend([f"Export error: {markdown_text(error)}", ""])
    if any(case["result"] == "Failed" for case in cases):
        lines.extend(["Failure screenshots, accessibility hierarchies, and other test attachments are in `attachments/`.", ""])
    lines.append("CI also retains the runner log and the original `.xcresult` bundle when one was produced.")
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")


def export_results(bundle, output, exit_code=None):
    bundle, output = Path(bundle), Path(output)
    if output.resolve().is_relative_to(bundle.resolve()):
        raise ExportError("The output directory must be outside the result bundle")
    if output.exists() and any(output.iterdir()):
        raise ExportError("The output directory must be new or empty to avoid stale reports")
    output.mkdir(parents=True, exist_ok=True)
    summary = {"title": "macOS UI tests", "result": "Unavailable", "totalTestCount": 0,
               "passedTests": 0, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
    tests, cases, errors = {"testNodes": []}, [], []
    try:
        if not bundle.is_dir():
            raise ExportError(f"No result bundle was produced at {bundle}. The app or test runner may have failed to build or launch.")
        summary = read_report("summary", bundle)
        tests = read_report("tests", bundle)
        cases = test_cases(tests)
        validate_summary(summary, cases)
        attach_failure_details(summary, cases)
        for index, case in enumerate(case for case in cases if case["result"] == "Failed"):
            # XCTest custom attachments are not always marked as associated with
            # a failure. Export by failed test, not --only-failures, to retain them.
            try:
                run_xcresult([
                    "export", "attachments", "--path", str(bundle),
                    "--test-id", case["identifierURL"],
                    "--output-path", str(output / "attachments" / f"failed-test-{index + 1:03d}"),
                ])
            except ExportError as error:
                errors.append(f"Attachments for {case['identifier']}: {error}")
    except ExportError as error:
        errors.append(str(error))
    for name, value in [("summary.json", summary), ("tests.json", tests)]:
        (output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_junit(output / "junit.xml", cases, "\n".join(errors) or None)
    write_markdown(output / "summary.md", summary, cases, errors, exit_code)
    if errors:
        (output / "export-errors.txt").write_text("\n".join(errors) + "\n", encoding="utf-8")
    return 1 if errors else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-bundle", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--test-exit-code", type=int)
    options = parser.parse_args(argv)
    try:
        return export_results(options.result_bundle, options.output_directory, options.test_exit_code)
    except (ExportError, OSError) as error:
        print(f"UI result export failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
