import Foundation

extension MCPServer {
    /// Domain schemas describe the existing CapturedReadService; SDK Tool Codable
    /// owns the MCP representation. No separate query implementation lives here.
    static var capturedToolDefinitions: [[String: Any]] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let date: [String: Any] = ["type": "string", "format": "date-time"]
        func number(_ minimum: Int, _ maximum: Int) -> [String: Any] {
            ["type": "integer", "minimum": minimum, "maximum": maximum]
        }
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description + " Requires the calling thread's device observe grant; an MCP connection alone grants no access.",
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
        }
        return [
            tool("captured_search", "Search captured text and metadata, newest first. Returns at most 20 hits; use nextCursor for more.", [
                "text": string, "apps": strings, "kinds": strings, "from": date, "to": date,
                "threadId": string, "cursor": string, "limit": number(1, 20)]),
            tool("captured_get", "Read one captured item, context, marks and bounded text. Pictures are MCP image blocks, each at most 400 KB, identified by captureId metadata. Private and unavailable sources return explicit errors/states.", [
                "id": string, "picture": ["type": "boolean"], "textOffset": number(0, 10_000_000),
                "variant": ["type": "string", "enum": ["marked", "clean"]],
                "region": ["type": "array", "items": ["type": "integer", "minimum": 0], "minItems": 4, "maxItems": 4]], ["id"]),
            tool("captured_frames", "Read activity and representative pictures in a range (at most 12 images, 4.8 MB total).", [
                "from": date, "to": date, "apps": strings, "maxPictures": number(1, 12)], ["from", "to"]),
            tool("captured_around", "Read context around an item id or timestamp; follow picture IDs with captured_get.", [
                "id": string, "at": date, "windowMinutes": number(1, 60)]),
            tool("captured_summary", "Summarize screen activity in a range of at most 31 days, with at most 25 groups.", [
                "from": date, "to": date, "groupBy": ["type": "string", "enum": ["app", "title", "urlHost", "hour", "day"]]], ["from", "to"]),
        ]
    }
}
