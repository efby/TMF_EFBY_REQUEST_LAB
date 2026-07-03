import EfbyPresentation
import Foundation
import XCTest

final class MainViewModelEnvironmentFlowTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EFBYPostmanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        RequestExecutionFlowMockURLProtocol.handler = nil
        if let temporaryDirectoryURL, FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    @MainActor
    func testPreAndPostScriptsUpdateEnvironmentForNextSendWithoutTouchingSharedFilesUntilSave() async throws {
        let repositoryRoot = temporaryDirectoryURL.appendingPathComponent("shared", isDirectory: true)
        let workspaceName = "default"
        let workspaceDirectory = repositoryRoot.appendingPathComponent(workspaceName, isDirectory: true)
        let workspaceStorageURL = temporaryDirectoryURL.appendingPathComponent("workspace.json", isDirectory: false)

        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

        let sharedRepository = SharedCollectionsRepository()
        let environment = EnvironmentProfile(
            name: "QA",
            variables: [
                VariableValue(key: "transactionId", value: "1000000"),
                VariableValue(key: "transactionCode", value: "500"),
            ]
        )
        let collection = CollectionModel(
            info: CollectionInfoModel(name: "Flow Collection"),
            items: [
                CollectionNode(
                    name: "Step A",
                    kind: .request,
                    request: APIRequestModel(
                        name: "Step A",
                        method: .post,
                        url: "https://api.example.com/step-a",
                        scripts: [
                            ScriptDefinition(
                                name: "Prepare next transaction",
                                listen: .preRequest,
                                language: "text/javascript",
                                source: """
                                var currentId = pm.environment.get("transactionId");
                                var sTrxId = String(Number(currentId) + 1);
                                pm.environment.set("transactionId", sTrxId);
                                """
                            ),
                            ScriptDefinition(
                                name: "Persist next code",
                                listen: .test,
                                language: "text/javascript",
                                source: """
                                if (pm.response.to.have.status(200)) {
                                    var currentCode = pm.environment.get("transactionCode");
                                    var sTrxCode = String(Number(currentCode) + 2);
                                    pm.environment.set("transactionCode", sTrxCode);
                                }
                                """
                            ),
                        ]
                    )
                ),
                CollectionNode(
                    name: "Step B",
                    kind: .request,
                    request: APIRequestModel(
                        name: "Step B",
                        method: .post,
                        url: "https://api.example.com/step-b",
                        body: RequestBodyModel(
                            kind: .json,
                            raw: #"{"transactionId":"{{transactionId}}","transactionCode":"{{transactionCode}}"}"#
                        )
                    )
                ),
            ]
        )

        try await sharedRepository.saveCollections([collection], to: workspaceDirectory)
        try await sharedRepository.saveEnvironments([environment], to: workspaceDirectory)

        let initialWorkspace = WorkspaceState(
            sharedCollectionsDirectoryPath: repositoryRoot.path,
            activeWorkspaceName: workspaceName,
            collections: [collection],
            environments: [environment],
            activeEnvironmentID: environment.id
        )

        let repository = WorkspaceRepository(storageURL: workspaceStorageURL)
        try await repository.save(initialWorkspace)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestExecutionFlowMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let executor = RequestExecutionService(session: session)

        RequestExecutionFlowMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/step-a":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"ok":true}"#.utf8))
            case "/step-b":
                XCTAssertEqual(
                    requestExecutionFlowBodyString(from: request),
                    #"{"transactionId":"1000001","transactionCode":"502"}"#
                )
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"ok":true}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.example.com/unexpected")!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data())
            }
        }

        let viewModel = MainViewModel(
            repository: repository,
            sharedCollectionsRepository: sharedRepository,
            executor: executor,
            autoloadWorkspace: false
        )
        viewModel.workspace = initialWorkspace

        let firstNode = collection.items[0]
        let secondNode = collection.items[1]
        await viewModel.open(request: firstNode, in: collection)
        guard let firstTab = viewModel.currentTab else {
            XCTFail("Expected first request tab to open")
            return
        }

        viewModel.sendCurrentRequest()
        try await waitUntil("first request finishes") {
            firstTab.isSending == false && firstTab.response?.statusCode == 200
        }

        XCTAssertEqual(
            viewModel.workspace.environments.first?.variables.first(where: { $0.key == "transactionId" })?.value,
            "1000001"
        )
        XCTAssertEqual(
            viewModel.workspace.environments.first?.variables.first(where: { $0.key == "transactionCode" })?.value,
            "502"
        )
        XCTAssertFalse(viewModel.hasPendingRequestEditorChanges(for: firstTab))
        XCTAssertTrue(viewModel.hasPendingEnvironmentChanges(for: firstTab))
        XCTAssertTrue(viewModel.hasPendingEnvironmentStoreChanges)

        let persistedLocalWorkspace = try await repository.load()
        let localDraft = persistedLocalWorkspace.requestDrafts.first(where: { $0.nodeID == firstNode.id })
        XCTAssertEqual(
            localDraft?.pendingEnvironmentVariables?.first(where: { $0.key == "transactionId" })?.value,
            "1000001"
        )
        XCTAssertEqual(
            localDraft?.pendingEnvironmentVariables?.first(where: { $0.key == "transactionCode" })?.value,
            "502"
        )

        let environmentsAfterFirstSend = try await sharedRepository.loadEnvironments(from: workspaceDirectory)
        XCTAssertEqual(
            environmentsAfterFirstSend.first?.variables.first(where: { $0.key == "transactionId" })?.value,
            "1000000"
        )
        XCTAssertEqual(
            environmentsAfterFirstSend.first?.variables.first(where: { $0.key == "transactionCode" })?.value,
            "500"
        )

        await viewModel.open(request: secondNode, in: collection)
        guard let secondTab = viewModel.currentTab else {
            XCTFail("Expected second request tab to open")
            return
        }

        viewModel.sendCurrentRequest()
        try await waitUntil("second request finishes") {
            secondTab.isSending == false && secondTab.response?.statusCode == 200
        }

        let environmentsAfterSecondSend = try await sharedRepository.loadEnvironments(from: workspaceDirectory)
        XCTAssertEqual(
            environmentsAfterSecondSend.first?.variables.first(where: { $0.key == "transactionId" })?.value,
            "1000000"
        )
        XCTAssertEqual(
            environmentsAfterSecondSend.first?.variables.first(where: { $0.key == "transactionCode" })?.value,
            "500"
        )

        viewModel.selectedTabID = firstTab.id
        XCTAssertFalse(viewModel.hasPendingRequestEditorChanges(for: firstTab))
        viewModel.saveCurrentRequest()

        let environmentsAfterRequestSave = try await sharedRepository.loadEnvironments(from: workspaceDirectory)
        XCTAssertEqual(
            environmentsAfterRequestSave.first?.variables.first(where: { $0.key == "transactionId" })?.value,
            "1000000"
        )
        XCTAssertEqual(
            environmentsAfterRequestSave.first?.variables.first(where: { $0.key == "transactionCode" })?.value,
            "500"
        )

        viewModel.saveCurrentEnvironmentChanges()

        try await waitUntil("shared environment file updates after save") {
            let savedEnvironments = try await sharedRepository.loadEnvironments(from: workspaceDirectory)
            return savedEnvironments.first?.variables.first(where: { $0.key == "transactionId" })?.value == "1000001"
                && savedEnvironments.first?.variables.first(where: { $0.key == "transactionCode" })?.value == "502"
        }
    }

    @MainActor
    func testCloningCollectionRequiresUniqueNameAndCreatesIndependentIdentifiers() async throws {
        let repositoryRoot = temporaryDirectoryURL.appendingPathComponent("shared-clone", isDirectory: true)
        let workspaceName = "default"
        let workspaceDirectory = repositoryRoot.appendingPathComponent(workspaceName, isDirectory: true)
        let workspaceStorageURL = temporaryDirectoryURL.appendingPathComponent("workspace-clone.json", isDirectory: false)

        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

        let request = APIRequestModel(
            name: "Login",
            method: .post,
            url: "https://api.example.com/login"
        )
        let originalNode = CollectionNode(
            name: request.name,
            kind: .request,
            request: request
        )
        let originalCollection = CollectionModel(
            info: CollectionInfoModel(name: "Auth"),
            items: [originalNode]
        )

        let initialWorkspace = WorkspaceState(
            sharedCollectionsDirectoryPath: repositoryRoot.path,
            activeWorkspaceName: workspaceName,
            collections: [originalCollection]
        )

        let repository = WorkspaceRepository(storageURL: workspaceStorageURL)
        try await repository.save(initialWorkspace)

        let viewModel = MainViewModel(
            repository: repository,
            sharedCollectionsRepository: SharedCollectionsRepository(),
            autoloadWorkspace: false
        )
        viewModel.workspace = initialWorkspace

        viewModel.duplicateCollection(originalCollection, named: "Auth Copy")

        try await waitUntil("collection clone finishes") {
            viewModel.workspace.collections.count == 2
        }

        XCTAssertEqual(viewModel.workspace.collections.map(\.info.name), ["Auth", "Auth Copy"])

        let clonedCollection = try XCTUnwrap(viewModel.workspace.collections.last)
        XCTAssertNotEqual(clonedCollection.id, originalCollection.id)
        XCTAssertEqual(clonedCollection.items.count, 1)
        XCTAssertNotEqual(clonedCollection.items[0].id, originalNode.id)
        XCTAssertNotEqual(clonedCollection.items[0].request?.id, request.id)

        viewModel.errorMessage = nil
        viewModel.duplicateCollection(originalCollection, named: "Auth")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.workspace.collections.count, 2)
        XCTAssertEqual(viewModel.errorMessage, "A collection with that name already exists.")
    }

    @MainActor
    func testRequestSaveAndEnvironmentSavePersistIndependently() async throws {
        let repositoryRoot = temporaryDirectoryURL.appendingPathComponent("shared-independent-save", isDirectory: true)
        let workspaceName = "default"
        let workspaceDirectory = repositoryRoot.appendingPathComponent(workspaceName, isDirectory: true)
        let workspaceStorageURL = temporaryDirectoryURL.appendingPathComponent("workspace-independent-save.json", isDirectory: false)

        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

        let environment = EnvironmentProfile(
            name: "QA",
            variables: [VariableValue(key: "transactionId", value: "1000")]
        )
        let request = APIRequestModel(
            name: "Step A",
            method: .post,
            url: "https://api.example.com/step-a",
            body: RequestBodyModel(kind: .json, raw: #"{"transactionId":"1000"}"#)
        )
        let node = CollectionNode(
            name: request.name,
            kind: .request,
            request: request
        )
        let collection = CollectionModel(
            info: CollectionInfoModel(name: "Flow Collection"),
            items: [node]
        )

        let sharedRepository = SharedCollectionsRepository()
        try await sharedRepository.saveCollections([collection], to: workspaceDirectory)
        try await sharedRepository.saveEnvironments([environment], to: workspaceDirectory)

        let initialWorkspace = WorkspaceState(
            sharedCollectionsDirectoryPath: repositoryRoot.path,
            activeWorkspaceName: workspaceName,
            collections: [collection],
            environments: [environment],
            activeEnvironmentID: environment.id
        )

        let repository = WorkspaceRepository(storageURL: workspaceStorageURL)
        try await repository.save(initialWorkspace)

        let viewModel = MainViewModel(
            repository: repository,
            sharedCollectionsRepository: sharedRepository,
            autoloadWorkspace: false
        )
        viewModel.workspace = initialWorkspace

        await viewModel.open(request: node, in: collection)
        let tab = try XCTUnwrap(viewModel.currentTab)

        tab.request.body.raw = #"{"transactionId":"2000"}"#
        viewModel.saveCurrentRequest()

        try await waitUntil("request save writes collection only") {
            let collections = try await sharedRepository.loadCollections(from: workspaceDirectory)
            let environments = try await sharedRepository.loadEnvironments(from: workspaceDirectory)
            return collections.first?.items.first?.request?.body.raw == #"{"transactionId":"2000"}"#
                && environments.first?.variables.first(where: { $0.key == "transactionId" })?.value == "1000"
        }

        var updatedEnvironment = environment
        updatedEnvironment.variables = [VariableValue(key: "transactionId", value: "3000")]
        viewModel.updateEnvironment(updatedEnvironment)

        let environmentsAfterLocalEdit = try await sharedRepository.loadEnvironments(from: workspaceDirectory)
        XCTAssertEqual(
            environmentsAfterLocalEdit.first?.variables.first(where: { $0.key == "transactionId" })?.value,
            "1000"
        )

        viewModel.saveCurrentEnvironmentChanges()

        try await waitUntil("environment save writes environment only") {
            let collections = try await sharedRepository.loadCollections(from: workspaceDirectory)
            let environments = try await sharedRepository.loadEnvironments(from: workspaceDirectory)
            return collections.first?.items.first?.request?.body.raw == #"{"transactionId":"2000"}"#
                && environments.first?.variables.first(where: { $0.key == "transactionId" })?.value == "3000"
        }
    }

    @MainActor
    func testUpdatingUtilityLibraryRejectsDuplicateGlobalConstant() async throws {
        let workspaceStorageURL = temporaryDirectoryURL.appendingPathComponent("workspace-utility-validation.json", isDirectory: false)
        let repository = WorkspaceRepository(storageURL: workspaceStorageURL)
        let viewModel = MainViewModel(repository: repository, autoloadWorkspace: false)

        let firstUtility = WorkspaceScriptUtility(
            name: "Token Utils",
            language: "javascript",
            source: """
            const TokenUtils = {
                genera: function() {
                    return "ok";
                }
            };
            """
        )
        let secondUtility = WorkspaceScriptUtility(
            name: "Body Utils",
            language: "javascript",
            source: """
            const BodyUtils = {
                generar: function() {
                    return {};
                }
            };
            """
        )

        viewModel.workspace = WorkspaceState(utilityLibraries: [firstUtility, secondUtility])

        var editedSecondUtility = secondUtility
        editedSecondUtility.source = """
        const TokenUtils = {
            generar: function() {
                return {};
            }
        };
        """

        let didSave = viewModel.updateUtilityLibrary(editedSecondUtility)

        XCTAssertFalse(didSave)
        XCTAssertEqual(
            viewModel.errorMessage,
            "The global constant or function 'TokenUtils' already exists in another utility library."
        )
        XCTAssertEqual(viewModel.workspace.utilityLibraries[1].source, secondUtility.source)
    }

    @MainActor
    func testUpdatingUtilityLibraryIgnoresNestedPrivateFunctionsDuringDuplicateValidation() async throws {
        let workspaceStorageURL = temporaryDirectoryURL.appendingPathComponent("workspace-utility-private-functions.json", isDirectory: false)
        let repository = WorkspaceRepository(storageURL: workspaceStorageURL)
        let viewModel = MainViewModel(repository: repository, autoloadWorkspace: false)

        let firstUtility = WorkspaceScriptUtility(
            name: "Token Utils",
            language: "javascript",
            source: """
            const TokenUtils = {
                generar: function() {
                    function formatInterno(value) {
                        return "A-" + value;
                    }
                    return formatInterno("ok");
                }
            };
            """
        )
        let secondUtility = WorkspaceScriptUtility(
            name: "Body Utils",
            language: "javascript",
            source: """
            const BodyUtils = {
                generar: function() {
                    return {};
                }
            };
            """
        )

        viewModel.workspace = WorkspaceState(utilityLibraries: [firstUtility, secondUtility])

        var editedSecondUtility = secondUtility
        editedSecondUtility.source = """
        const BodyUtils = {
            generar: function() {
                function formatInterno(value) {
                    return "B-" + value;
                }
                return { value: formatInterno("ok") };
            }
        };
        """

        let didSave = viewModel.updateUtilityLibrary(editedSecondUtility)

        XCTAssertTrue(didSave)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.workspace.utilityLibraries[1].source, editedSecondUtility.source)
    }

    @MainActor
    func testUtilityLibrariesAndFlowsPersistToSharedWorkspaceAndReload() async throws {
        let repositoryRoot = temporaryDirectoryURL.appendingPathComponent("shared-utilities-flows", isDirectory: true)
        let workspaceName = "default"
        let workspaceDirectory = repositoryRoot.appendingPathComponent(workspaceName, isDirectory: true)
        let workspaceStorageURL = temporaryDirectoryURL.appendingPathComponent("workspace-utilities-flows.json", isDirectory: false)

        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

        let sharedRepository = SharedCollectionsRepository()
        let initialWorkspace = WorkspaceState(
            sharedCollectionsDirectoryPath: repositoryRoot.path,
            activeWorkspaceName: workspaceName
        )

        let repository = WorkspaceRepository(storageURL: workspaceStorageURL)
        try await repository.save(initialWorkspace)

        let viewModel = MainViewModel(
            repository: repository,
            sharedCollectionsRepository: sharedRepository,
            autoloadWorkspace: false
        )
        viewModel.workspace = initialWorkspace

        let utility = try XCTUnwrap(viewModel.addUtilityLibrary(named: "Token Utils"))
        var updatedUtility = utility
        updatedUtility.source = """
        const TokenUtils = {
            generar: function() {
                return "ok";
            }
        };
        """
        XCTAssertTrue(viewModel.updateUtilityLibrary(updatedUtility))

        let flow = try XCTUnwrap(viewModel.addFlow(named: "Authorization Flow"))
        var updatedFlow = flow
        updatedFlow.bpmnXML = "<bpmn:definitions id=\"Definitions_1\"></bpmn:definitions>"
        updatedFlow.taskBindings = [WorkspaceFlowTaskBinding(elementID: "Task_1")]
        XCTAssertTrue(viewModel.updateFlow(updatedFlow))

        try await waitUntil("utilities and flows save into shared workspace") {
            let savedUtilities = try await sharedRepository.loadUtilityLibraries(from: workspaceDirectory)
            let savedFlows = try await sharedRepository.loadFlows(from: workspaceDirectory)
            return savedUtilities.count == 1
                && savedUtilities.first?.name == "Token Utils"
                && savedUtilities.first?.source == updatedUtility.source
                && savedFlows.count == 1
                && savedFlows.first?.name == "Authorization Flow"
                && savedFlows.first?.bpmnXML == updatedFlow.bpmnXML
                && savedFlows.first?.taskBindings == updatedFlow.taskBindings
        }

        let localWorkspaceWithoutSharedManagedContent = WorkspaceState(
            sharedCollectionsDirectoryPath: repositoryRoot.path,
            activeWorkspaceName: workspaceName
        )
        try await repository.save(localWorkspaceWithoutSharedManagedContent)

        let reloadedViewModel = MainViewModel(
            repository: repository,
            sharedCollectionsRepository: sharedRepository,
            autoloadWorkspace: false
        )
        reloadedViewModel.workspace = localWorkspaceWithoutSharedManagedContent
        reloadedViewModel.loadCollectionsFromSharedDirectory()

        try await waitUntil("utilities and flows reload from shared workspace") {
            reloadedViewModel.workspace.utilityLibraries.count == 1
                && reloadedViewModel.workspace.utilityLibraries.first?.name == "Token Utils"
                && reloadedViewModel.workspace.utilityLibraries.first?.source == updatedUtility.source
                && reloadedViewModel.workspace.flows.count == 1
                && reloadedViewModel.workspace.flows.first?.name == "Authorization Flow"
                && reloadedViewModel.workspace.flows.first?.bpmnXML == updatedFlow.bpmnXML
                && reloadedViewModel.workspace.flows.first?.taskBindings == updatedFlow.taskBindings
        }
    }

    @MainActor
    func testCancelBackgroundFlowRunEndsSession() async throws {
        let workspaceStorageURL = temporaryDirectoryURL.appendingPathComponent("workspace-flow-cancel.json", isDirectory: false)
        let repository = WorkspaceRepository(storageURL: workspaceStorageURL)

        let requestID = UUID()
        let collectionNodeID = UUID()
        let request = APIRequestModel(
            id: requestID,
            name: "Slow Request",
            method: .get,
            url: "https://api.example.com/slow-step"
        )
        let collection = CollectionModel(
            info: CollectionInfoModel(name: "Demo Collection"),
            items: [
                CollectionNode(
                    id: collectionNodeID,
                    name: "Slow Request",
                    kind: .request,
                    request: request
                ),
            ]
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestExecutionFlowMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let executor = RequestExecutionService(session: session)

        RequestExecutionFlowMockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/slow-step")
            Thread.sleep(forTimeInterval: 3.0)
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        let viewModel = MainViewModel(
            repository: repository,
            executor: executor,
            autoloadWorkspace: false
        )

        let flowID = UUID()
        let flow = WorkspaceFlowDefinition(
            id: flowID,
            name: "Cancel me",
            taskBindings: [WorkspaceFlowTaskBinding(elementID: "Task_1", requestID: requestID)]
        )
        let graph = WorkspaceFlowGraphSnapshot(
            nodes: [
                WorkspaceFlowGraphNode(id: "StartEvent_1", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent, outgoingIDs: ["Task_1"]),
                WorkspaceFlowGraphNode(id: "Task_1", name: "Slow Request", bpmnType: "bpmn:Task", nodeType: .task, incomingIDs: ["StartEvent_1"], outgoingIDs: ["EndEvent_1"]),
                WorkspaceFlowGraphNode(id: "EndEvent_1", name: "End", bpmnType: "bpmn:EndEvent", nodeType: .endEvent, incomingIDs: ["Task_1"]),
            ],
            connections: [
                WorkspaceFlowGraphConnection(id: "Flow_1", sourceID: "StartEvent_1", targetID: "Task_1"),
                WorkspaceFlowGraphConnection(id: "Flow_2", sourceID: "Task_1", targetID: "EndEvent_1"),
            ]
        )

        viewModel.workspace = WorkspaceState(collections: [collection])

        XCTAssertTrue(viewModel.validateFlow(flow, graph: graph).isValid)

        try viewModel.startBackgroundFlowExecution(flow, graph: graph)
        XCTAssertTrue(viewModel.hasActiveFlowRun(for: flowID))

        try await Task.sleep(nanoseconds: 50_000_000)
        viewModel.cancelFlowExecution(flowID: flowID)

        try await waitUntil("background flow session to stop running") {
            viewModel.hasActiveFlowRun(for: flowID) == false
        }

        let endedSession: WorkspaceFlowRunSession = try XCTUnwrap(viewModel.flowRunSession(for: flowID))
        XCTAssertFalse(endedSession.isRunning)
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private final class RequestExecutionFlowMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("Handler not configured")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestExecutionFlowBodyString(from request: URLRequest) -> String? {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8)
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }

    return String(data: data, encoding: .utf8)
}
