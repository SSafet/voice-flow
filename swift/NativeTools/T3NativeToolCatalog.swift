import Foundation
import MCP
import CoreFoundation

enum T3NativeToolCatalog {
    static func tools(computer: Bool, captured: Bool, overlay: Bool) throws -> [Tool] {
        let string: [String: Any] = ["type": "string"]
        let point: [String: Any] = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        var definitions: [[String: Any]] = []
        if computer {
            definitions.append(tool("voiceflow_computer", "Observe or control the Mac. Screenshot returns actual image bytes and a screenId. Coordinates are pixels in that screenshot; every coordinate action requires its screenId. A new screenshot replaces this turn's old screenId. Screen changes require a new screenshot.", [
                "action": ["type": "string", "enum": ["screenshot", "cursor_position", "left_click", "right_click", "double_click", "mouse_move", "drag", "type", "key", "scroll", "wait"]],
                "screenId": string, "coordinate": point, "start_coordinate": point,
                "text": ["type": "string", "maxLength": 4096],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "amount": ["type": "integer", "minimum": 1, "maximum": 30],
                "duration": ["type": "number", "minimum": 0, "maximum": 5]
            ], required: ["action"]))
        }
        // Reuse the established captured domain schemas, without creating its
        // public MCP server or any MCPSession/picker state.
        if captured { definitions += MCPServer.capturedToolDefinitions }
        if overlay {
            definitions.append(tool("voiceflow_overlay", "Manage only this T3 thread's native overlays. annotate requires the latest screenId and items in that screenshot's pixels. Guide/panel position is a named anchor. No paths or other threads' overlays are returned.", [
                "operation": ["type": "string", "enum": ["show_guide", "update_guide", "show_panel", "annotate", "remove", "list"]],
                "id": ["type": "string", "maxLength": 80], "screenId": string,
                "payload": ["type": "object", "additionalProperties": true]
            ], required: ["operation"]))
        }
        return try JSONDecoder().decode([Tool].self, from: JSONSerialization.data(withJSONObject: definitions))
    }
    static func validate(tool: String, arguments: [String: Any]) throws -> T3NativeToolOperation {
        func invalid() -> T3NativeToolFailure { .init(code: "native_arguments_invalid") }
        func string(_ key: String, max: Int = 256) throws -> String {
            guard let s = arguments[key] as? String, !s.isEmpty, s.utf8.count <= max, !s.contains("\0") else { throw invalid() }; return s
        }
        func number(_ key: String, range: ClosedRange<Double>, integer: Bool = false) throws -> Double {
            guard let n = arguments[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  range.contains(n.doubleValue), !integer || n.doubleValue.rounded() == n.doubleValue else { throw invalid() }; return n.doubleValue
        }
        func point(_ key: String) throws -> [Double] {
            guard let p = arguments[key] as? [NSNumber], p.count == 2,
                  p.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && (0...100_000).contains($0.doubleValue) }) else { throw invalid() }
            return p.map(\.doubleValue)
        }
        if tool == "voiceflow_computer" {
            let action = try string("action")
            var allowed: Set<String> = ["action"]
            let capability: T3NativeToolAction
            var detail = action
            switch action {
            case "screenshot", "cursor_position": capability = .observe
            case "left_click", "right_click", "double_click", "mouse_move", "drag", "scroll":
                capability = .control; allowed.formUnion(["screenId", "coordinate"])
                _ = try string("screenId"); let p = try point("coordinate"); detail += " at \(p)"
                if action == "drag" { allowed.insert("start_coordinate"); let start = try point("start_coordinate"); detail += " from \(start)" }
                if action == "scroll" { allowed.formUnion(["direction", "amount"]); let direction = try string("direction")
                    guard ["up", "down", "left", "right"].contains(direction) else { throw invalid() }
                    let amount = try number("amount", range: 1...30, integer: true); detail += " \(direction), \(Int(amount)) lines"
                }
            case "type", "key":
                capability = .control; allowed.insert("text"); let text = try string("text", max: 4096)
                // Typed text can be a password; do not put it in approval history.
                detail += " (\(text.count) characters; [redacted])"
            case "wait": capability = .observe; allowed.insert("duration"); let duration = try number("duration", range: 0...5); detail += " \(duration)s"
            default: throw invalid()
            }
            guard Set(arguments.keys).isSubset(of: allowed) else { throw invalid() }
            return .init(action: capability, arguments: arguments, review: "Mac computer: \(detail)")
        }
        if CapturedReadOperation(rawValue: tool) != nil {
            guard let definition = MCPServer.capturedToolDefinitions.first(where: { $0["name"] as? String == tool }),
                  let schema = definition["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any],
                  Set(arguments.keys).isSubset(of: Set(properties.keys)),
                  (schema["required"] as? [String] ?? []).allSatisfy({ arguments[$0] != nil }) else { throw invalid() }
            // CapturedReadService validates generated DTOs, ranges, and source
            // access again. No query text or capture IDs enter approval history.
            return .init(action: .capturedRead, arguments: arguments, review: "Read captured data: \(tool) (query [redacted])")
        }
        if tool == "voiceflow_overlay" {
            let operation = try string("operation")
            guard ["show_guide", "update_guide", "show_panel", "annotate", "remove", "list"].contains(operation) else { throw invalid() }
            if operation == "list" {
                guard arguments.count == 1 else { throw invalid() }
            } else {
                let id = try string("id", max: 80)
                guard id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }),
                      Set(arguments.keys).isSubset(of: operation == "annotate" ? ["operation", "id", "payload", "screenId"] : ["operation", "id", "payload"]) else { throw invalid() }
                if operation == "annotate" { _ = try string("screenId") }
                if operation != "remove" {
                    guard let payload = arguments["payload"] as? [String: Any] else { throw invalid() }
                    let permitted: Set<String> = ["title", "note", "steps", "active_step", "blocks", "position", "width", "visible", "items", "session", "system"]
                    guard Set(payload.keys).isSubset(of: permitted), payload["position"] == nil || payload["position"] is String else { throw invalid() }
                }
                else if arguments["payload"] != nil { throw invalid() }
            }
            return .init(action: operation == "list" ? .overlayRead : .overlayWrite, arguments: arguments,
                         review: "Mac overlay: \(operation) ([redacted])")
        }
        throw T3NativeToolFailure(code: "native_tool_unavailable")
    }
}
