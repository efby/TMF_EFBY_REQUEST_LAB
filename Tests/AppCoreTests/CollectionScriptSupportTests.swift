import EfbyDomain
import EfbyPresentation
import XCTest

final class CollectionScriptSupportTests: XCTestCase {
    func testMergeScriptsDeduplicatesByContent() {
        let script = ScriptDefinition(name: "pre", listen: .preRequest, language: "text/javascript", source: "pm.test()")
        let merged = CollectionScriptSupport.mergeScripts([script], [script], [script])
        XCTAssertEqual(merged.count, 1)
    }

    func testEnrichedRequestInheritsCollectionAuthAndFolderScripts() {
        let folderID = UUID()
        let requestID = UUID()
        let folderScript = ScriptDefinition(name: "folder", listen: .preRequest, language: "text/javascript", source: "1")
        let requestScript = ScriptDefinition(name: "req", listen: .test, language: "text/javascript", source: "2")
        let request = APIRequestModel(
            id: requestID,
            name: "Ping",
            method: .get,
            url: "https://example.com",
            scripts: [requestScript]
        )
        let folder = CollectionNode(
            id: folderID,
            name: "Folder",
            kind: .folder,
            scripts: [folderScript],
            children: [CollectionNode(name: "Ping", kind: .request, request: request)]
        )
        let collection = CollectionModel(
            info: CollectionInfoModel(name: "API"),
            auth: AuthConfiguration(type: .bearer, token: "secret"),
            scripts: [],
            items: [folder]
        )

        let leafNodeID = folder.children[0].id
        let enriched = CollectionScriptSupport.enrichedRequest(
            from: request,
            collection: collection,
            sourceNodeID: leafNodeID
        )

        XCTAssertEqual(enriched.auth.type, .bearer)
        XCTAssertEqual(enriched.auth.token, "secret")
        XCTAssertEqual(enriched.scripts.map(\.name), ["folder", "req"])
    }

    func testMergeScriptsIntoSavedRequestUsesNodeScripts() {
        let nodeScript = ScriptDefinition(name: "node", listen: .preRequest, language: "text/javascript", source: "a")
        let requestScript = ScriptDefinition(name: "body", listen: .test, language: "text/javascript", source: "b")
        let node = CollectionNode(
            name: "R",
            kind: .request,
            request: APIRequestModel(name: "R", scripts: [requestScript]),
            scripts: [nodeScript]
        )

        let saved = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)
        XCTAssertEqual(saved.scripts.map(\.name), ["node", "body"])
    }
}
