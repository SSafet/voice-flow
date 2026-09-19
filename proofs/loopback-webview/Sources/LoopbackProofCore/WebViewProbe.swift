import AppKit
import Foundation
import WebKit

@MainActor
public final class WebViewProbe: NSObject, WKNavigationDelegate {
    private let port: Int
    private let previewPort: Int
    private let state: ProofState
    private var webView: WKWebView?
    private var navigationRows: [ProofRow] = []
    private var navigationSettled = false

    public init(port: Int, previewPort: Int, state: ProofState) {
        self.port = port
        self.previewPort = previewPort
        self.state = state
    }

    /// Compiles the content rule list that asks WebKit to add the header itself.
    /// Returns the row describing what happened, and the list when it compiled.
    private func compileRuleList(storeDirectory: URL) async -> (ProofRow, WKContentRuleList?) {
        let secret = state.secret
        // Two rules. The first is the mechanism under test: can WebKit itself put the
        // header on every request the page makes? The second is the control: a plain
        // block on one path under the same filter, so that a failure of the first
        // cannot be blamed on a filter that never matched.
        let json = """
        [{"trigger":{"url-filter":"probe/ruled/"},\
        "action":{"type":"modify-headers","priority":1,\
        "request-headers":[{"operation":"set","header":"x-loopback-secret","value":"\(secret)"}]}},\
        {"trigger":{"url-filter":"probe/ruled/blocked"},"action":{"type":"block"}}]
        """
        guard let store = WKContentRuleListStore(url: storeDirectory) else {
            return (ProofRow(kind: .observation, name: "rule_list_compiled",
                             passed: nil, detail: "WKContentRuleListStore(url:) returned nil"), nil)
        }
        do {
            let list = try await store.compileContentRuleList(forIdentifier: "loopback-proof", encodedContentRuleList: json)
            return (ProofRow(kind: .observation, name: "rule_list_compiled", passed: nil,
                             detail: list == nil ? "compiled to nil" : "modify-headers compiled"), list)
        } catch {
            return (ProofRow(kind: .observation, name: "rule_list_compiled", passed: nil,
                             detail: "did not compile: \(error)"), nil)
        }
    }

    /// Loads the page in a web view that belongs to no window, and waits for the
    /// page to post its rows back.
    public func run(storeDirectory: URL, snapshotPath: URL?) async -> [ProofRow] {
        var rows: [ProofRow] = []
        let (ruleRow, ruleList) = await compileRuleList(storeDirectory: storeDirectory)
        rows.append(ruleRow)

        let configuration = WKWebViewConfiguration()
        let descriptor = WKUserScript(
            source: "window.__shellDescriptor = {v:1, shell:\"mac\", secret:\"\(state.secret)\", previewPort:\(previewPort)};",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(descriptor)
        if let ruleList { configuration.userContentController.add(ruleList) }

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

        for path in ["/api/v1/threads/socket", "/probe/ruled/socket"] {
            let seen = await state.upgradeHeader(path: path)
            let detail: String
            switch seen {
            case .none: detail = "no upgrade request reached \(path)"
            case .some(""): detail = "the upgrade request to \(path) carried no x-loopback-secret header"
            case .some(let value): detail = "the upgrade request to \(path) carried x-loopback-secret = \(value.prefix(8))…"
            }
            rows.append(ProofRow(kind: .observation, name: "upgrade_header\(path.replacingOccurrences(of: "/", with: "_"))",
                                 passed: nil, detail: detail))
        }

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
