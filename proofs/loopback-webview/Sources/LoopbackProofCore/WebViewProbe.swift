import AppKit
import Foundation
import WebKit

@MainActor
public final class WebViewProbe: NSObject, WKNavigationDelegate {
    private let port: Int
    private let state: ProofState
    private var webView: WKWebView?
    private var navigationRows: [ProofRow] = []
    private var navigationSettled = false

    public init(port: Int, state: ProofState) {
        self.port = port
        self.state = state
    }

    /// Loads the page in a web view that belongs to no window, and waits for the
    /// page to post its rows back.
    public func run(storeDirectory: URL, snapshotPath: URL?) async -> [ProofRow] {
        var rows: [ProofRow] = []
        _ = storeDirectory

        let configuration = WKWebViewConfiguration()
        let descriptor = WKUserScript(
            source: "window.__shellDescriptor = {v:1, shell:\"mac\", secret:\"\(state.secret)\"};",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(descriptor)

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
        view.navigationDelegate = self
        webView = view

        guard let url = URL(string: "http://localhost:\(port)/") else {
            rows.append(ProofRow(kind: .check, name: "page_loads", passed: false, detail: "bad URL"))
            return rows
        }
        view.load(URLRequest(url: url))

        let navigated = await waitForNavigation(seconds: 20)
        if !navigated {
            rows.append(ProofRow(kind: .check, name: "page_loads", passed: false,
                                 detail: "the web view neither finished nor failed within 20 seconds"))
            return rows
        }
        rows.append(contentsOf: navigationRows)

        let reported = await state.waitForPageReport(seconds: 30)
        if !reported {
            rows.append(ProofRow(kind: .check, name: "page_reported", passed: false,
                                 detail: "the page did not post its results within 30 seconds"))
            return rows
        }
        rows.append(ProofRow(kind: .check, name: "page_reported", passed: true,
                             detail: "the page posted its results to /probe/report"))

        if let snapshotPath {
            let detail = await snapshot(of: view, to: snapshotPath)
            rows.append(ProofRow(kind: .observation, name: "page_snapshot", passed: nil, detail: detail))
        }
        return rows
    }

    /// Grows the view to the height of the page and gives WebKit a moment to draw it
    /// before the picture is taken. There is no window: the view is never added to
    /// one, so nothing appears on any display.
    private func fitToContent(_ view: WKWebView) async {
        let height = try? await view.evaluateJavaScript("document.documentElement.scrollHeight") as? Int
        if let height = height ?? nil, height > 0 {
            view.frame = NSRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(height) + 24)
        }
        view.setNeedsDisplay(view.bounds)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    private func snapshot(of view: WKWebView, to path: URL) async -> String {
        await fitToContent(view)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            configuration.rect = view.bounds
            view.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(returning: "takeSnapshot failed: \(error)")
                    return
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else {
                    continuation.resume(returning: "takeSnapshot returned no image")
                    return
                }
                do {
                    try png.write(to: path)
                    continuation.resume(returning: "written to \(path.path)")
                } catch {
                    continuation.resume(returning: "could not write the snapshot: \(error)")
                }
            }
        }
    }

    // MARK: navigation

    private func waitForNavigation(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !navigationSettled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return navigationSettled
    }

    private func settleNavigation(_ row: ProofRow) {
        guard !navigationSettled else { return }
        navigationRows.append(row)
        navigationSettled = true
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settleNavigation(ProofRow(kind: .check, name: "page_loads", passed: true,
                                  detail: "http://localhost:\(port)/ finished loading"))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settleNavigation(ProofRow(kind: .check, name: "page_loads", passed: false, detail: "didFail: \(error)"))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settleNavigation(ProofRow(kind: .check, name: "page_loads", passed: false,
                                  detail: "didFailProvisionalNavigation: \(error)"))
    }
}
