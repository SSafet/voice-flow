import AppKit
import WebKit

/// A native window for the actual matching T3 client served by its environment.
/// The caller owns the environment and existing native services. This host owns
/// no server process, canonical store, socket, scheduler or provider credential.
@MainActor
final class T3ShellWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    typealias Action = @MainActor (ShellCapabilityRequest) async -> ShellCapabilityReceipt

    enum Phase: Equatable { case idle, authenticating, loading, ready, failed(String), closed }
    private(set) var phase: Phase = .idle { didSet { onPhaseChanged?(phase) } }
    var onComposerTargetChanged: ((ShellComposerTarget?) -> Void)?
    var onPhaseChanged: ((Phase) -> Void)?
    let window: NSWindow
    let webView: WKWebView
    private let origin: T3ShellOrigin
    private let authentication: T3BrowserAuthentication
    private let actions: [ShellCapability: Action]
    let inputCustody: ShellInputCustody?
    private let contentController: WKUserContentController
    private let ruleStore: WKContentRuleListStore
    private let downloads: T3ShellDownloads
    private var openPanels: [NSOpenPanel] = []
    private var binding = ShellComposerBinding()
    private var session: T3BrowserAuthentication.Session?
    private var prepared = false
    private var closed = false
    private var renewing = false
    private var authenticationGeneration = 0
    private struct PendingInput {
        let attempt: UUID
        let continuation: CheckedContinuation<ShellInputReceipt, Never>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: PendingInput] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var statusView = NSStackView()

    /// Production supplies a stable, dedicated WKWebsiteDataStore(forIdentifier:)
    /// for this account/environment, never .default(). QA uses .nonPersistent().
    init(origin: T3ShellOrigin, environmentId: String, dataStore: WKWebsiteDataStore, ruleStoreURL: URL,
         actions: [ShellCapability: Action] = [:], inputCustody: ShellInputCustody? = nil) throws {
        guard origin.isLoopback else { throw T3ShellError.invalidOrigin }
        guard !dataStore.isPersistent || dataStore.identifier != nil else { throw T3ShellError.invalidResponse }
        self.origin = origin
        self.authentication = T3BrowserAuthentication(origin: origin, environmentId: environmentId)
        self.actions = actions
        self.inputCustody = inputCustody
        ruleStore = WKContentRuleListStore(url: ruleStoreURL)
        contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        contentController.addUserScript(WKUserScript(source: try VoiceFlowShellScript.source(origin: origin),
                                                     injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        downloads = T3ShellDownloads(window: window, origin: origin)
        super.init()
        window.title = "Voice Flow"
        window.minSize = NSSize(width: 720, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        contentController.addScriptMessageHandler(ShellMessageProxy(owner: self), contentWorld: .page, name: "voiceFlowShell")
        let root = NSView()
        window.contentView = root
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        statusView = NSStackView(views: [statusLabel, retryButton])
        statusView.orientation = .vertical
        statusView.spacing = 12
        statusView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusView)
        statusView.isHidden = true
        statusLabel.setAccessibilityIdentifier("voiceflow.shell.status")
        retryButton.target = self
        retryButton.action = #selector(retryDocument)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor), webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor), webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusView.centerXAnchor.constraint(equalTo: root.centerXAnchor), statusView.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
    }

    func show() {
        guard !closed else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Attach only after the app has approved this exact environment identity and
    /// origin. Its bootstrap credential stays in native code and is not retained.
    func attach(credential: String) async throws {
        guard !closed, session == nil, phase != .authenticating else { throw T3ShellError.unavailable }
        phase = .authenticating
        authenticationGeneration += 1
        let generation = authenticationGeneration
        do {
            try await prepare()
            let session = try await authentication.exchange(credential: credential)
            guard !closed, generation == authenticationGeneration else { throw T3ShellError.unavailable }
            await session.install { [webView] cookie in await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            guard !closed, generation == authenticationGeneration else { throw T3ShellError.unavailable }
            self.session = session
            loadDocument()
        } catch {
            if !closed { showFailure("Could not connect to the environment.", canRetry: false) }
            throw error
        }
    }

    /// Explicit credential renewal, not a connection retry hook. It preserves the
    /// mounted T3 client/composer and asks its existing supervisor to recheck auth.
    func renewCredentials(_ credential: String) async throws {
        guard !closed, session != nil, !renewing else { throw T3ShellError.unavailable }
        renewing = true
        defer { renewing = false }
        let generation = authenticationGeneration
        let next = try await authentication.exchange(credential: credential)
        guard !closed, generation == authenticationGeneration else { throw T3ShellError.unavailable }
        await next.install { [webView] cookie in await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
        guard !closed, generation == authenticationGeneration else { throw T3ShellError.unavailable }
        session = next
        // No webView.reload(): reconnect must not erase the current draft/selection.
        _ = try? await webView.callAsyncJavaScript("window.voiceFlowShell?.__credentialsChanged();", arguments: [:], in: nil, contentWorld: .page)
    }

    /// Freeze this at native capture start, not at transcription completion.
    func freezeComposerTarget(requireKeyWindow: Bool = false) -> ShellFrozenTarget? {
        guard !closed, phase == .ready, window.isVisible, !requireKeyWindow || window.isKeyWindow else { return nil }
        return binding.freeze()
    }

    func deliver(_ input: ShellInput, timeoutSeconds: Double = 10) async -> ShellInputReceipt {
        guard input.isValid else { return ShellInputReceipt(deliveryId: input.deliveryId, status: .rejected) }
        guard !closed, phase == .ready else { return ShellInputReceipt(deliveryId: input.deliveryId, status: .unavailable) }
        // Only an exact native-owned input may reconcile an old durable receipt
        // after remount. The web checks that receipt before target; byte reads
        // still require the currently frozen binding below.
        guard inputCustody?.owns(input) == true else { return ShellInputReceipt(deliveryId: input.deliveryId, status: .rejected) }
        guard pending[input.deliveryId] == nil else { return ShellInputReceipt(deliveryId: input.deliveryId, status: .unconfirmed) }
        guard let body = try? ShellWire.object(input) else { return ShellInputReceipt(deliveryId: input.deliveryId, status: .rejected) }
        return await withCheckedContinuation { continuation in
            let attempt = UUID()
            let timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.1, min(timeoutSeconds, 60)) * 1_000_000_000)) }
                catch { return }
                self?.finish(input.deliveryId, attempt: attempt, status: .unconfirmed)
            }
            pending[input.deliveryId] = PendingInput(attempt: attempt, continuation: continuation, timeout: timeout)
            Task { @MainActor [weak self, webView] in
                do {
                    let value = try await webView.callAsyncJavaScript("return await window.voiceFlowShell.__deliver(input);", arguments: ["input": body], in: nil, contentWorld: .page)
                    if let value, let receipt = try? ShellWire.decode(ShellInputReceipt.self, value), receipt.deliveryId == input.deliveryId {
                        self?.finish(input.deliveryId, attempt: attempt, status: receipt.status)
                    } else { self?.finish(input.deliveryId, attempt: attempt, status: .unconfirmed) }
                } catch { self?.finish(input.deliveryId, attempt: attempt, status: .unconfirmed) }
            }
        }
    }

    /// Called on app/account/environment shutdown, not when the user closes the
    /// window. Existing environment processes remain the app owner's responsibility.
    func shutdown() {
        guard !closed else { return }
        closed = true
        authenticationGeneration += 1
        invalidateDocument()
        authentication.shutdown()
        for panel in openPanels { panel.cancel(nil) }
        openPanels.removeAll()
        downloads.shutdown()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        contentController.removeScriptMessageHandler(forName: "voiceFlowShell", contentWorld: .page)
        contentController.removeAllUserScripts()
        contentController.removeAllContentRuleLists()
        window.orderOut(nil)
        phase = .closed
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func prepare() async throws {
        guard !prepared else { return }
        let rules = try origin.cookieRulesJSON()
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            ruleStore.compileContentRuleList(forIdentifier: "voiceflow-shell-cookie-\(UUID().uuidString)", encodedContentRuleList: rules) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? T3ShellError.invalidResponse) }
            }
        }
        guard !closed else { throw T3ShellError.unavailable }
        contentController.add(list)
        // The compiled object remains retained by WebKit; remove the disk cache's
        // per-attach name so restarting the shell does not leave endless entries.
        try? await ruleStore.removeContentRuleList(forIdentifier: list.identifier)
        prepared = true
    }

    private func loadDocument() {
        guard !closed, prepared, session != nil else { return }
        statusView.isHidden = true
        webView.isHidden = false
        phase = .loading
        webView.load(URLRequest(url: origin.url))
    }

    @objc private func retryDocument() {
        // Only a failed document/process exposes this explicit action. T3 handles
        // ordinary socket reconnect without native reload or composer reset.
        if case .failed = phase { loadDocument() }
    }

    private func showFailure(_ message: String, canRetry: Bool = true) {
        phase = .failed(message)
        webView.isHidden = true
        statusLabel.stringValue = message
        retryButton.isHidden = !canRetry
        statusView.isHidden = false
    }

    private func finish(_ id: String, attempt: UUID, status: ShellInputReceipt.Status) {
        guard let item = pending[id], item.attempt == attempt else { return }
        pending.removeValue(forKey: id)
        item.timeout.cancel()
        if status == .accepted { _ = inputCustody?.acknowledge(.init(deliveryId: id, status: status)) }
        item.continuation.resume(returning: ShellInputReceipt(deliveryId: id, status: status))
    }

    private func invalidateDocument() {
        binding.invalidate()
        onComposerTargetChanged?(nil)
        for (id, item) in Array(pending) { finish(id, attempt: item.attempt, status: .unconfirmed) }
    }

    fileprivate func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        guard !closed, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, origin.isAppDocument(url),
              origin.matchesSecurityOrigin(scheme: message.frameInfo.securityOrigin.protocol,
                                           host: message.frameInfo.securityOrigin.host,
                                           port: message.frameInfo.securityOrigin.port),
              let body = message.body as? [String: Any], body["version"] as? Int == 1,
              let type = body["type"] as? String else { reply(nil, "Untrusted shell message."); return }
        switch type {
        case "describe":
            reply(try? ShellWire.object(ShellDescriptor(documentId: binding.documentId, capabilities: actions.keys.sorted { $0.rawValue < $1.rawValue })), nil)
        case "composer":
            guard let documentId = body["documentId"] as? String, let value = body["target"] else { reply(nil, "Invalid composer target."); return }
            let target: ShellComposerTarget?
            if value is NSNull { target = nil }
            else if let decoded = try? ShellWire.decode(ShellComposerTarget.self, value) { target = decoded }
            else { reply(nil, "Invalid composer target."); return }
            let accepted = binding.publish(target, documentId: documentId)
            if accepted { onComposerTargetChanged?(target) }
            reply(["accepted": accepted], nil)
        case "readCapture":
            guard phase == .ready, window.isVisible, let custody = inputCustody,
                  let value = body["request"], let request = try? ShellWire.decode(ShellCaptureReadRequest.self, value) else {
                reply(nil, "Captured input is unavailable."); return
            }
            do { reply(try ShellWire.object(custody.read(request, binding: binding)), nil) }
            catch { reply(nil, "Captured input is unavailable for this delivery and composer.") }
        case "perform":
            guard let value = body["request"], let request = try? ShellWire.decode(ShellCapabilityRequest.self, value) else { reply(nil, "Invalid capability request."); return }
            guard let action = actions[request.capability] else { reply(["status": "unavailable"], nil); return }
            if [.dictate, .capture].contains(request.capability) {
                guard window.isVisible, let destination = request.destination, binding.matches(destination) else { reply(["status": "rejected"], nil); return }
            }
            if request.capability == .speak {
                guard let text = request.text, !text.isEmpty, text.utf8.count <= 1_048_576 else { reply(["status": "rejected"], nil); return }
            }
            let documentId = binding.documentId
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.phase == .ready, self.window.isVisible,
                      self.binding.documentId == documentId else { reply(["status": "unavailable"], nil); return }
                if [.dictate, .capture].contains(request.capability) {
                    guard let destination = request.destination, self.binding.matches(destination) else { reply(["status": "rejected"], nil); return }
                }
                reply(try? ShellWire.object(await action(request)), nil)
            }
        default: reply(nil, "Unsupported shell request.")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = action.request.url else { decisionHandler(.cancel); return }
        let localBlob = url.scheme == "blob" && URL(string: String(url.absoluteString.dropFirst(5))).map(origin.contains) == true
        if action.shouldPerformDownload {
            // Download attributes are honored only for the actual trusted app;
            // generated previews may not turn themselves into native save prompts.
            decisionHandler(action.sourceFrame.isMainFrame && action.sourceFrame.request.url.map(origin.isAppDocument) == true
                            && (origin.contains(url) || localBlob) ? .download : .cancel)
            return
        }
        if action.targetFrame?.isMainFrame == true {
            if origin.isAppDocument(url) { decisionHandler(.allow); return }
            if action.navigationType == .linkActivated, !origin.contains(url), ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else if action.targetFrame == nil {
            if action.navigationType == .linkActivated, !origin.contains(url), ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else {
            // Sandboxed same-origin file previews keep the original T3 UI. Other
            // environments/previews need an explicit unprivileged host boundary.
            decisionHandler(origin.contains(url) || localBlob || url.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = response.response.url else { decisionHandler(.cancel); return }
        let csp = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Security-Policy")
        if response.isForMainFrame {
            decisionHandler(origin.isAppDocument(url) && response.response.mimeType == "text/html" && !(csp.map(T3ShellOrigin.hasOpaqueSandbox) ?? false) ? .allow : .cancel)
        } else {
            decisionHandler(origin.permitsFrameResponse(url: url, mimeType: response.response.mimeType, contentSecurityPolicy: csp) ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        invalidateDocument()
        phase = .loading
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        phase = .ready
        statusView.isHidden = true
        webView.isHidden = false
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        invalidateDocument()
        showFailure("The environment is unavailable. Your saved drafts remain in T3.")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        invalidateDocument()
        showFailure("The environment page could not load.")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        invalidateDocument()
        showFailure("The page stopped. Retry to reopen your saved drafts.")
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.accept(download)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard !closed, window.isVisible, frame.isMainFrame, frame.request.url.map(origin.isAppDocument) == true else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        openPanels.append(panel)
        panel.beginSheetModal(for: window) { [weak self] result in
            self?.openPanels.removeAll { $0 === panel }
            completionHandler(result == .OK && self?.closed == false ? panel.urls : nil)
        }
    }
}

@MainActor
private final class ShellMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: T3ShellWindow?
    init(owner: T3ShellWindow) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Shell closed."); return }
        owner.receive(message, reply: replyHandler)
    }
}
