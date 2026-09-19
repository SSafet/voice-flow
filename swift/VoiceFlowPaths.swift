import AppKit
import CoreGraphics
import Foundation

/// Immutable identity + geometry for one attached display. Capture runs keep
/// this value so later pointer, window, or session changes cannot reroute them.
///
/// It lives beside `VoiceFlowPaths` because every stand-alone suite that
/// compiles `CaptureRouting.swift` also compiles this file, and no other source
/// is common to all of them.
struct DisplayContext: Equatable {
    let id: CGDirectDisplayID
    let frame: NSRect
    let visibleFrame: NSRect
    let backingScaleFactor: CGFloat
    /// One-based display index accepted by `/usr/sbin/screencapture -D`.
    let captureIndex: Int

    var shotGeometry: (width: Int, height: Int) {
        let scale = min(1.0, 1440.0 / frame.width)
        return (
            Int((frame.width * scale).rounded()),
            Int((frame.height * scale).rounded())
        )
    }

    var annotationPointScale: CGFloat {
        let width = shotGeometry.width
        return width > 0 ? frame.width / CGFloat(width) : 1.0
    }

    /// Convert an AppKit global point (bottom-left origin) into screenshot
    /// pixels (top-left origin) for this display.
    func screenshotPoint(forGlobalPoint point: NSPoint) -> CGPoint {
        let scale = annotationPointScale
        return CGPoint(
            x: (point.x - frame.minX) / scale,
            y: (frame.maxY - point.y) / scale
        )
    }
}

/// One source of truth for Voice Flow's writable data locations.
///
/// Production keeps the historical `~/.config/voice-flow` layout. A QA build
/// or test process can set `VOICE_FLOW_CONFIG_ROOT` to an absolute directory
/// before launch, isolating every store from the user's real data.
struct VoiceFlowPaths: Equatable {
    static let configRootEnvironmentKey = "VOICE_FLOW_CONFIG_ROOT"
    static let shared = VoiceFlowPaths()

    let configRoot: URL
    let isIsolated: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let productionRoot = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("voice-flow", isDirectory: true)
            .standardizedFileURL
        if let raw = environment[Self.configRootEnvironmentKey], !raw.isEmpty,
           NSString(string: raw).isAbsolutePath {
            configRoot = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            // QA authority must describe the resolved storage location, not
            // merely the presence of an environment variable. An explicit
            // production path (including a symlink) is still production.
            isIsolated = configRoot.resolvingSymlinksInPath() != productionRoot.resolvingSymlinksInPath()
        } else {
            configRoot = productionRoot
            isIsolated = false
        }
        try? FileManager.default.createDirectory(
            at: configRoot, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        configRoot.appendingPathComponent(name, isDirectory: false)
    }

    func directory(_ name: String, create: Bool = true) -> URL {
        let url = configRoot.appendingPathComponent(name, isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func contains(_ candidate: URL) -> Bool {
        let root = configRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
}
