import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import MCP

struct T3NativeScreenImage { let displayId: UInt32; let bounds: CGRect; let image: CGImage }
struct T3NativeComputerCommand {
    let action: String; var point: CGPoint?; var start: CGPoint?
    var text: String?; var direction: String?; var amount: Int?
}
struct T3NativeComputerPrimitives {
    let capture: () async throws -> T3NativeScreenImage
    let geometry: (UInt32) async -> CGRect?
    let cursor: () async -> CGPoint
    let perform: (T3NativeComputerCommand, T3NativeToolCheckpoint) async throws -> Void
}
struct T3NativeOverlayPrimitives {
    let list: () -> [String]
    let read: (String) -> [String: Any]?
    let write: (String, [String: Any]) throws -> Void
    let remove: (String) throws -> Void
}
/// Adapts existing native services. It holds only the latest screenshot geometry
/// per active turn; no source, draft, transcript, or approval store is created.
actor T3NativeToolPrimitives {
    private struct Frame { let id: String; let displayId: UInt32; let bounds: CGRect; let width: Int; let height: Int }
    private let binding: T3NativeToolBinding
    private let computer: T3NativeComputerPrimitives?
    private let overlays: T3NativeOverlayPrimitives?
    private let captured: ((T3NativeToolCheckpoint) -> CapturedReadService)?
    private var frames: [String: Frame] = [:]
    init(binding: T3NativeToolBinding, computer: T3NativeComputerPrimitives?, overlays: T3NativeOverlayPrimitives?,
         captured: ((T3NativeToolCheckpoint) -> CapturedReadService)?) {
        self.binding = binding; self.computer = computer; self.overlays = overlays; self.captured = captured
    }
    func closeTurn(threadId: String, turnId: String) { frames.removeValue(forKey: "\(threadId)\0\(turnId)") }
    func execute(_ call: T3NativeToolCall, _ operation: T3NativeToolOperation, _ checkpoint: T3NativeToolCheckpoint) async throws -> CallTool.Result {
        try checkpoint.check()
        if let read = CapturedReadOperation(rawValue: call.tool) {
            guard let captured else { throw failure("native_captured_unavailable") }
            let reply = MCPCapturedReader.read(read, arguments: operation.arguments, service: captured(checkpoint)).sdkResult
            try checkpoint.check(); return reply
        }
        if call.tool == "voiceflow_overlay" { return try await overlay(call, operation.arguments, checkpoint) }
        guard call.tool == "voiceflow_computer", let computer else { throw failure("native_computer_unavailable") }
        let args = operation.arguments, action = args["action"] as! String
        let scope = "\(call.threadId)\0\(call.turnId)"
        switch action {
        case "screenshot":
            guard frames[scope] != nil || frames.count < 128 else { throw failure("native_screen_capacity") }
            let shot = try await computer.capture()
            try checkpoint.check()
            guard await computer.geometry(shot.displayId) == shot.bounds else { throw failure("native_screen_changed") }
            try checkpoint.check()
            var dimension: CGFloat = 1568
            var encoded: Data?
            for _ in 0..<5 {
                encoded = ImageUtils.jpeg(from: shot.image, maxDimension: dimension, quality: 0.65)
                if let encoded, encoded.count <= 400_000 { break }
                dimension *= 0.7
            }
            guard let encoded, encoded.count <= 400_000,
                  let source = CGImageSourceCreateWithData(encoded as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw failure("native_image_unavailable") }
            try checkpoint.check()
            let frame = Frame(id: UUID().uuidString, displayId: shot.displayId, bounds: shot.bounds, width: decoded.width, height: decoded.height)
            frames[scope] = frame
            let metadata: [String: Any] = ["screenId": frame.id, "displayId": frame.displayId, "width": frame.width, "height": frame.height,
                                           "coordinateSpace": "screenshot pixels, top-left origin"]
            return try result(metadata, images: [.image(data: encoded.base64EncodedString(), mimeType: "image/jpeg", annotations: nil,
                                                       _meta: Metadata(additionalFields: ["screenId": .string(frame.id)]))])
        case "cursor_position":
            let cursor = await computer.cursor(); try checkpoint.check()
            guard let frame = frames[scope], await computer.geometry(frame.displayId) == frame.bounds else { throw failure("native_screenshot_required") }
            try checkpoint.check()
            return try result(["screenId": frame.id, "coordinate": [(cursor.x-frame.bounds.minX)*CGFloat(frame.width)/frame.bounds.width,
                                                                       (cursor.y-frame.bounds.minY)*CGFloat(frame.height)/frame.bounds.height]])
        case "wait":
            try await Task.sleep(nanoseconds: UInt64((args["duration"] as! NSNumber).doubleValue * 1_000_000_000))
            try checkpoint.check(); return try result(["waited": true])
        default:
            var command = T3NativeComputerCommand(action: action)
            if let coordinate = args["coordinate"] as? [NSNumber] {
                guard let frame = frames[scope], frame.id == args["screenId"] as? String,
                      await computer.geometry(frame.displayId) == frame.bounds else { throw failure("native_screen_changed") }
                try checkpoint.check()
                guard frames[scope]?.id == frame.id else { throw failure("native_screen_changed") }
                func point(_ values: [NSNumber]) throws -> CGPoint {
                    let x = values[0].doubleValue, y = values[1].doubleValue
                    guard x < Double(frame.width), y < Double(frame.height) else { throw failure("native_coordinate_outside_image") }
                    return CGPoint(x: frame.bounds.minX + x*frame.bounds.width/Double(frame.width),
                                   y: frame.bounds.minY + y*frame.bounds.height/Double(frame.height))
                }
                command.point = try point(coordinate)
                if let start = args["start_coordinate"] as? [NSNumber] { command.start = try point(start) }
            }
            command.text = args["text"] as? String; command.direction = args["direction"] as? String; command.amount = (args["amount"] as? NSNumber)?.intValue
            try checkpoint.check(); try await computer.perform(command, checkpoint); try checkpoint.check()
            return try result(["performed": action])
        }
    }
    static func overlayOwner(binding: T3NativeToolBinding, threadId: String) -> String {
        // Explicit T3 owner, never the legacy Assistant/picker selection.
        let data = Data("\(binding.ownerId)\0\(binding.deviceId)\0\(binding.homeId)\0\(binding.environment.environmentId)\0\(threadId)".utf8)
        return "t3-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func overlay(_ call: T3NativeToolCall, _ args: [String: Any], _ checkpoint: T3NativeToolCheckpoint) async throws -> CallTool.Result {
        guard let overlays else { throw failure("native_overlay_unavailable") }
        let owner = Self.overlayOwner(binding: binding, threadId: call.threadId)
        let operation = args["operation"] as! String
        try checkpoint.check()
        if operation == "list" {
            let rows: [[String: Any]] = overlays.list().compactMap { id in
                guard let doc = overlays.read(id), doc["session"] as? String == owner,
                      let sourceId = doc["t3NativeId"] as? String else { return nil }
                return ["id": sourceId, "type": doc["type"] as? String ?? "unknown", "visible": doc["visible"] as? Bool ?? true]
            }
            try checkpoint.check(); return try result(["overlays": Array(rows.prefix(100)), "truncated": rows.count > 100])
        }
        let sourceId = args["id"] as! String
        let id = "t3-" + SHA256.hash(data: Data("\(owner)\0\(sourceId)".utf8)).map { String(format: "%02x", $0) }.joined()
        let old = overlays.read(id)
        if let old, old["session"] as? String != owner { throw failure("native_overlay_owner_mismatch") }
        if operation == "remove" {
            guard old != nil else { throw failure("native_overlay_missing") }
            try checkpoint.check(); try overlays.remove(id); try checkpoint.check()
            guard overlays.read(id) == nil else { throw failure("native_overlay_remove_failed") }
            return try result(["id": sourceId, "removed": true])
        }
        if operation == "update_guide", old?["type"] as? String != "guide" { throw failure("native_overlay_missing") }
        var payload = operation == "update_guide" ? old! : [:]
        for (key, value) in args["payload"] as! [String: Any] { payload[key] = value }
        // The caller cannot forge another owner, durable system overlay, or a
        // path. The existing manager interprets this bounded overlay document.
        payload["session"] = owner; payload["t3NativeId"] = sourceId; payload["system"] = false
        payload["type"] = operation == "annotate" ? "annotations" : operation == "show_panel" ? "panel" : "guide"
        if operation == "annotate" {
            let scope = "\(call.threadId)\0\(call.turnId)"
            guard let computer, let frame = frames[scope], frame.id == args["screenId"] as? String,
                  await computer.geometry(frame.displayId) == frame.bounds, frames[scope]?.id == frame.id,
                  let items = payload["items"] as? [[String: Any]], items.count <= 100 else { throw failure("native_screen_changed") }
            try checkpoint.check()
            // Existing OverlayManager uses DisplayContext.shotGeometry (1440 px
            // maximum width). Convert this turn's actual encoded screenshot into
            // that existing coordinate space; never assume image pixels == points.
            let width = (min(1, 1440 / frame.bounds.width) * frame.bounds.width).rounded()
            let scale = width / CGFloat(frame.width)
            payload["items"] = try items.map { item -> [String: Any] in
                var item = item
                guard ["circle", "rect", "arrow", "line", "label"].contains(item["type"] as? String ?? "") else { throw failure("native_arguments_invalid") }
                for key in ["center", "rect", "from", "to", "position"] where item[key] != nil {
                    guard let values = item[key] as? [NSNumber], values.count == (key == "rect" ? 4 : 2),
                          values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && abs($0.doubleValue) <= 100_000 }) else { throw failure("native_arguments_invalid") }
                    item[key] = values.map { $0.doubleValue * scale }
                }
                for key in ["radius", "size"] where item[key] != nil {
                    guard let value = item[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                          value.doubleValue.isFinite, (0...100_000).contains(value.doubleValue) else { throw failure("native_arguments_invalid") }
                    item[key] = value.doubleValue * scale
                }
                return item
            }
            payload["display_id"] = frame.displayId
        }
        guard try JSONSerialization.data(withJSONObject: payload).count <= 64 * 1024 else { throw failure("native_overlay_too_large") }
        try checkpoint.check(); try overlays.write(id, payload); try checkpoint.check()
        return try result(["id": sourceId, "updated": true])
    }
    private func result(_ value: [String: Any], images: [Tool.Content] = []) throws -> CallTool.Result {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard bytes.count <= 64 * 1024 else { throw failure("native_result_too_large") }
        return try .init(content: [.text(text: String(decoding: bytes, as: UTF8.self), annotations: nil, _meta: nil)] + images,
                     structuredContent: try JSONDecoder().decode(Value.self, from: bytes), isError: false)
    }
    private func failure(_ code: String) -> T3NativeToolFailure { .init(code: code) }
}
