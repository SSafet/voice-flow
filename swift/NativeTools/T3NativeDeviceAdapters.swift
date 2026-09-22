import AppKit
import Foundation
import ApplicationServices

/// Production dependency handles only; constructing these does not capture,
/// control the Mac, start a server, or select a UI thread.
enum T3NativeDeviceAdapters {
    static func computer(screenCapture: ScreenCapture,
                         controlAllowed: @escaping @Sendable () -> Bool) -> T3NativeComputerPrimitives {
        // Dedicated instance prevents another runtime from replacing its
        // checkpoint or image geometry. The CGEvent engine itself is reused.
        let control = ComputerControl()
        return T3NativeComputerPrimitives(capture: {
            guard CGPreflightScreenCaptureAccess() else { throw T3NativeToolFailure(code: "native_screen_permission_required") }
            guard let display = await MainActor.run(body: { DisplayTopology.underMouse ?? DisplayTopology.primary }) else {
                throw T3NativeToolFailure(code: "native_display_unavailable")
            }
            let bounds = CGDisplayBounds(display.id)
            return try await T3NativeScreenImage(displayId: display.id, bounds: bounds, image: screenCapture.captureImage(on: display))
        }, geometry: { id in
            await MainActor.run { DisplayTopology.display(id: id).map { CGDisplayBounds($0.id) } }
        }, cursor: { await MainActor.run { CGEvent(source: nil)?.location ?? .zero } }, perform: { command, checkpoint in
            try await MainActor.run {
                let verify = {
                    try checkpoint.check()
                    guard controlAllowed(), AXIsProcessTrusted() else { throw T3NativeToolFailure(code: "native_computer_control_disabled") }
                }
                try verify()
                control.imageToScreenScale = 1 // adapter already mapped to Quartz global points
                control.checkpoint = verify
                defer { control.checkpoint = nil }
                switch command.action {
                case "mouse_move": control.move(to: command.point!)
                case "left_click", "right_click", "double_click": control.click(action: command.action, at: command.point!, modifiers: nil)
                case "drag": control.drag(from: command.start!, to: command.point!)
                case "scroll": control.scroll(at: command.point!, direction: command.direction!, amount: command.amount!)
                case "type": control.typeText(command.text!)
                case "key": guard control.pressKeyCombo(command.text!) else { throw T3NativeToolFailure(code: "native_key_unsupported") }
                default: throw T3NativeToolFailure(code: "native_action_unsupported")
                }
                if let error = control.lastFailure { throw error }
                try verify()
            }
        })
    }
    static func overlays(_ manager: OverlayManager) -> T3NativeOverlayPrimitives {
        .init(list: { manager.list().map(\.id) }, read: { manager.read(id: $0) }, write: { id, payload in
            guard manager.write(id: id, dict: payload) != nil else { throw T3NativeToolFailure(code: "native_overlay_write_failed") }
        }, remove: { id in
            guard manager.remove(id: id), manager.read(id: id) == nil else { throw T3NativeToolFailure(code: "native_overlay_remove_failed") }
        })
    }
    static func captured(index: CapturedIndex, root: URL, progress: @escaping () -> CapturedProgress)
        -> (T3NativeToolCheckpoint) -> CapturedReadService {
        { checkpoint in CapturedReadService(query: CapturedQuery(index: index, root: root, indexProgress: progress,
            mayRead: { (try? checkpoint.check()) != nil })) }
    }
}
