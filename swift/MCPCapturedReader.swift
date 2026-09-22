import Foundation
import MCP

/// The sole adapter from the derived-index read service into supported MCP output.
/// Permission and cancellation are supplied to the query, rechecked for each image.
enum MCPCapturedReader {
    static func read(_ operation: CapturedReadOperation, arguments: [String: Any],
                     service: CapturedReadService) -> MCPServer.ToolResult {
        do {
            let reply = try service.read(operation, arguments: JSONSerialization.data(withJSONObject: arguments),
                                         limits: .agent, delivery: .imageBytes)
            let value = try JSONDecoder().decode(Value.self, from: reply.json)
            let text = String(decoding: reply.json, as: UTF8.self)
            let images: [Tool.Content] = reply.pictures.map { picture in
                .image(data: picture.data.base64EncodedString(), mimeType: picture.mimeType, annotations: nil,
                       _meta: Metadata(additionalFields: ["ai.atika/captureId": .string(picture.id),
                                                         "width": .int(picture.width), "height": .int(picture.height)]))
            }
            return MCPServer.ToolResult(text: text, isError: reply.isError,
                                        content: [.text(text: text, annotations: nil, _meta: nil)] + images, structuredContent: value)
        } catch is CancellationError { return .fail("Request cancelled.") }
        catch { return .fail("Captured read failed: \(error.localizedDescription)") }
    }
}

extension MCPServer {
    /// Device-channel authorization is supplied by the owner. An absent authority
    /// is a visible unavailable connection, never a synthetic observe grant.
    func readCaptured(_ operation: CapturedReadOperation, arguments: [String: Any], session: MCPSession?,
                      cancellation: MCPToolCancellation, index: CapturedIndex, root: URL,
                      progress: @escaping () -> CapturedProgress) -> ToolResult {
        guard let session, authorizeCapturedRead != nil else {
            return .fail("captured_access_unconnected: The device observe-grant authority is not connected. Connecting to MCP does not authorize captured-data access.")
        }
        let query = CapturedQuery(index: index, root: root, indexProgress: progress, mayRead: { [weak self] in
            !cancellation.isCancelled && self?.authorizeCapturedRead?(session) == true
        })
        return MCPCapturedReader.read(operation, arguments: arguments, service: CapturedReadService(query: query))
    }
}
