import EfbyPresentation
import Foundation
import XCTest

final class MainViewModelFlowCloneTests: XCTestCase {
    @MainActor
    func testCloneFlowNewIdSameContentAndUniqueDefaultName() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainViewModelFlowCloneTests-\(UUID().uuidString).json", isDirectory: false)
        let viewModel = MainViewModel(repository: WorkspaceRepository(storageURL: storage), autoloadWorkspace: false)

        let original = try XCTUnwrap(viewModel.addFlow(named: "Checkout"))
        var edited = original
        edited.bpmnXML = "<bpmn:definitions id=\"X\"></bpmn:definitions>"
        edited.taskBindings = [WorkspaceFlowTaskBinding(elementID: "Task_1", requestID: UUID())]
        XCTAssertTrue(viewModel.updateFlow(edited))

        let reloaded = try XCTUnwrap(viewModel.workspace.flows.first(where: { $0.id == edited.id }))
        let clone = try XCTUnwrap(viewModel.cloneFlow(reloaded, named: "Checkout Copy"))

        XCTAssertEqual(viewModel.workspace.flows.count, 2)
        XCTAssertNotEqual(clone.id, reloaded.id)
        XCTAssertEqual(clone.name, "Checkout Copy")
        XCTAssertEqual(clone.bpmnXML, reloaded.bpmnXML)
        XCTAssertEqual(clone.taskBindings, reloaded.taskBindings)

        let clone2 = try XCTUnwrap(viewModel.cloneFlow(reloaded, named: ""))
        XCTAssertEqual(viewModel.workspace.flows.count, 3)
        XCTAssertEqual(clone2.name, "Checkout Copy 2")
    }

    @MainActor
    func testSuggestedFlowCloneNameAvoidsCollision() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainViewModelFlowCloneTests2-\(UUID().uuidString).json", isDirectory: false)
        let viewModel = MainViewModel(repository: WorkspaceRepository(storageURL: storage), autoloadWorkspace: false)

        _ = try XCTUnwrap(viewModel.addFlow(named: "A"))
        let source = try XCTUnwrap(viewModel.addFlow(named: "B"))
        _ = try XCTUnwrap(viewModel.addFlow(named: "B Copy"))

        XCTAssertEqual(viewModel.suggestedFlowCloneName(for: source), "B Copy 2")
    }
}
