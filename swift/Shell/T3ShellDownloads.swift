import AppKit
import WebKit

/// Uses WebKit's authenticated download, then the system save panel. It never
/// turns a web-supplied path into a write destination or opens downloaded bytes.
@MainActor
final class T3ShellDownloads: NSObject, WKDownloadDelegate {
    private weak var window: NSWindow?
    private let origin: T3ShellOrigin
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var panels: [ObjectIdentifier: NSSavePanel] = [:]
    private var stopped = false

    init(window: NSWindow, origin: T3ShellOrigin) { self.window = window; self.origin = origin }

    func accept(_ download: WKDownload) {
        guard !stopped else { download.cancel { _ in }; return }
        downloads[ObjectIdentifier(download)] = download
        download.delegate = self
    }

    func shutdown() {
        stopped = true
        for panel in Array(panels.values) { panel.cancel(nil) }
        panels.removeAll()
        for download in Array(downloads.values) { download.cancel { _ in } }
        downloads.removeAll()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !stopped, let window else { completionHandler(nil); return }
        let id = ObjectIdentifier(download)
        let panel = NSSavePanel()
        // A suggested name is a label, never a path. The user chooses placement.
        let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.nameFieldStringValue = name.isEmpty || name == "/" ? "Download" : name
        panel.canCreateDirectories = true
        panels[id] = panel
        panel.beginSheetModal(for: window) { [weak self] result in
            self?.panels.removeValue(forKey: id)
            completionHandler(result == .OK && self?.stopped == false ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(!stopped && request.url.map(origin.contains) == true ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        guard !stopped, (error as NSError).code != NSURLErrorCancelled, let window else { return }
        let alert = NSAlert()
        alert.messageText = "The file could not be saved."
        alert.informativeText = "Try downloading it again."
        alert.beginSheetModal(for: window)
    }
}
