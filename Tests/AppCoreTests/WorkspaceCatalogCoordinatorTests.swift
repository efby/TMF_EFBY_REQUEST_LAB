import EfbyDomain
import EfbyPresentation
import XCTest

@MainActor
final class WorkspaceCatalogCoordinatorTests: XCTestCase {
    private let coordinator = WorkspaceCatalogCoordinator()

    func testSuggestedCollectionNameAvoidsCollisions() {
        let collections = [
            CollectionModel(info: CollectionInfoModel(name: "New Collection")),
            CollectionModel(info: CollectionInfoModel(name: "New Collection 2")),
        ]
        XCTAssertEqual(coordinator.suggestedCollectionName(collections: collections), "New Collection 3")
    }

    func testCollectionNameValidation() {
        let collections = [CollectionModel(info: CollectionInfoModel(name: "Alpha"))]
        XCTAssertEqual(coordinator.collectionNameValidationMessage("", collections: collections), "Name is required.")
        XCTAssertEqual(
            coordinator.collectionNameValidationMessage("alpha", collections: collections),
            "A collection with that name already exists."
        )
        XCTAssertNil(coordinator.collectionNameValidationMessage("Beta", collections: collections))
    }

    func testUtilitySourceValidationDetectsDuplicateGlobals() {
        let utilities = [
            WorkspaceScriptUtility(name: "A", language: "javascript", source: "const sharedHelper = {};"),
        ]
        let message = coordinator.utilityLibrarySourceValidationMessage(
            "const sharedHelper = { ok: true };",
            utilityLibraries: utilities
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("sharedHelper") == true)
    }

    func testCloneCollectionAssignsNewIds() {
        let request = APIRequestModel(name: "Ping", method: .get, url: "https://example.com")
        let node = CollectionNode(name: "Ping", kind: .request, request: request)
        let original = CollectionModel(
            info: CollectionInfoModel(name: "API"),
            items: [node]
        )

        let clone = coordinator.cloneCollection(original)
        XCTAssertNotEqual(clone.id, original.id)
        XCTAssertEqual(clone.info.name, original.info.name)
        XCTAssertNotEqual(clone.items[0].id, original.items[0].id)
        XCTAssertNotEqual(clone.items[0].request?.id, original.items[0].request?.id)
        XCTAssertEqual(clone.items[0].request?.url, "https://example.com")
    }

    func testMakeClonedFlowGetsNewIdentity() {
        let flow = WorkspaceFlowDefinition(name: "Checkout")
        let clone = coordinator.makeClonedFlow(from: flow, named: "Checkout Copy")
        XCTAssertNotEqual(clone.id, flow.id)
        XCTAssertEqual(clone.name, "Checkout Copy")
        XCTAssertEqual(clone.bpmnXML, flow.bpmnXML)
    }

    func testFlowRequestReferencesAreSorted() {
        let requestA = APIRequestModel(name: "Zeta", method: .get, url: "https://a")
        let requestB = APIRequestModel(name: "Alpha", method: .get, url: "https://b")
        let collections = [
            CollectionModel(
                info: CollectionInfoModel(name: "Beta"),
                items: [CollectionNode(name: "Zeta", kind: .request, request: requestA)]
            ),
            CollectionModel(
                info: CollectionInfoModel(name: "Alpha"),
                items: [CollectionNode(name: "Alpha", kind: .request, request: requestB)]
            ),
        ]

        let refs = coordinator.flowRequestReferences(in: collections)
        XCTAssertEqual(refs.map(\.collectionName), ["Alpha", "Beta"])
        XCTAssertEqual(refs.map(\.requestName), ["Alpha", "Zeta"])
    }

    func testSanitizedUtilityIdentifier() {
        XCTAssertEqual(coordinator.sanitizedUtilityIdentifier(from: "My Utils!"), "My_Utils")
        XCTAssertEqual(coordinator.sanitizedUtilityIdentifier(from: "2start"), "u_2start")
    }
}
