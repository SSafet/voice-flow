import Cocoa
import SwiftUI
import ObjectiveC

// Disposable UI fixture only. The production sources are unchanged. Requests
// for this reserved host are forwarded to the existing loopback-only Atika
// test server. This exercises controller/forms/Keychain, not TLS or email delivery.
final class UIFixtureProtocol: URLProtocol {
    private var forwardTask: URLSessionDataTask?
    private var session: URLSession?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "native-ui.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let source = request.url!
            guard source.path.hasPrefix("/api/v1/") else { throw URLError(.unsupportedURL) }
            let file = ProcessInfo.processInfo.environment["VF_UI_FIXTURE"]!
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
            let origin = fixture["origin"] as! String
            guard origin.range(of: #"^http://127\.0\.0\.1:\d+$"#, options: .regularExpression) != nil else { throw URLError(.unsupportedURL) }
            var target = URLComponents(url: source, resolvingAgainstBaseURL: false)!
            let local = URLComponents(string: origin)!
            target.scheme = local.scheme; target.host = local.host; target.port = local.port
            var forwarded = request
            forwarded.url = target.url
            if forwarded.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.requestBodyStreamExhausted) }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                    guard bytes.count <= 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                }
                forwarded.httpBodyStream = nil; forwarded.httpBody = bytes
            }
            let configuration = URLSessionConfiguration.default
            configuration.httpShouldSetCookies = false; configuration.urlCache = nil
            let session = URLSession(configuration: configuration); self.session = session
            forwardTask = session.dataTask(with: forwarded) { data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
                guard let response = response as? HTTPURLResponse else { self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
                fputs("Fixture \(source.path) HTTP \(response.statusCode)\n", stderr)
                let visible = HTTPURLResponse(url: source, statusCode: response.statusCode, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: visible, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data ?? Data())
                self.client?.urlProtocolDidFinishLoading(self)
            }
            forwardTask?.resume()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { forwardTask?.cancel(); session?.invalidateAndCancel() }
}
extension URLSessionConfiguration {
    @objc class func uiFixtureEphemeral() -> URLSessionConfiguration {
        let config = uiFixtureEphemeral()
        config.protocolClasses = [UIFixtureProtocol.self] + (config.protocolClasses ?? [])
        return config
    }
}
method_exchangeImplementations(class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral))!, class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.uiFixtureEphemeral))!)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 920, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Voice Flow — Sync UI Test"
window.contentView = NSHostingView(rootView: CloudSyncSettingsView())
window.appearance = NSAppearance(named: .darkAqua)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let captureTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/voice-flow-cloud-settings-ui/latest.png"))
}
app.run()
