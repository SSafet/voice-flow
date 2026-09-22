// Copied into the pinned official SDK's test target by sdk-probe.sh. This is an
// adapter fit proof; the application does not install a second MCP server.
import Foundation
import Testing
@testable import MCP

struct CapturedSDKAdapterProbe {
    struct Fixture: Decodable {
        struct Picture: Decodable { let id: String; let data: String; let mimeType: String }
        let json: String
        let pictures: [Picture]
        let isError: Bool
    }
    @Test func productionCapturedReplyFitsSupportedSDK() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VF_CAPTURED_QUERY_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let json = Data(fixture.json.utf8)
        let value = try JSONDecoder().decode(Value.self, from: json)
        let content: [Tool.Content] = [.text(text: fixture.json, annotations: nil, _meta: nil)] + fixture.pictures.map {
            .image(data: $0.data, mimeType: $0.mimeType, annotations: nil,
                   _meta: Metadata(additionalFields: ["ai.atika/captureId": .string($0.id)]))
        }
        let result = CallTool.Result(content: content, structuredContent: Optional.some(value), isError: fixture.isError)
        let encoded = try JSONEncoder().encode(result)
        let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let structured = try #require(wire["structuredContent"] as? [String: Any])
        let item = try #require(structured["item"] as? [String: Any])
        #expect(item["id"] as? String == "shot:s")
        let blocks = try #require(wire["content"] as? [[String: Any]])
        #expect(blocks[0]["text"] as? String == fixture.json)
        let metadata = try #require(blocks[1]["_meta"] as? [String: Any])
        #expect(metadata["ai.atika/captureId"] as? String == "shot:s")
        #expect((Data(base64Encoded: blocks[1]["data"] as? String ?? "")?.count ?? Int.max) <= 400_000)
        #expect(wire["isError"] as? Bool == false)
        #expect(Version.negotiate(clientRequestedVersion: "2025-06-18") == "2025-06-18")
        let params = try JSONDecoder().decode(CallTool.Parameters.self, from: Data(#"{"name":"captured_get","arguments":{"id":"shot:s"},"_meta":{"ai.atika/threadId":"thread-fixture"}}"#.utf8))
        #expect(params._meta?["ai.atika/threadId"] == .string("thread-fixture"))
        #expect(params.arguments?["id"] == .string("shot:s"))
    }
}
