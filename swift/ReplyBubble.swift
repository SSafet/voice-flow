import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Reply Bubble — facade over the pill's grown surface
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  There is no separate bubble window anymore: everything renders inside
//  FloatingIndicator's own growing panel — content above, the live dots in
//  the bottom band of the same shape. This class keeps the familiar API
//  and forwards to the pill.

final class ReplyBubble {
    /// ✕ — close and keep (a pending ask stays pending; the session's
    /// preview slot survives for the picker).
    var onClosed: (() -> Void)?
    /// Trash — delete: cancels a pending ask, clears the preview slot.
    var onTrashed: (() -> Void)?
    /// Speaker icon — read the visible text aloud.
    var onSpeakRequested: ((String) -> Void)?

    private let indicator: FloatingIndicator

    var isVisible: Bool { indicator.isGrownVisible }

    init(indicator: FloatingIndicator) {
        self.indicator = indicator
        indicator.onGrownSpeak = { [weak self] text in self?.onSpeakRequested?(text) }
        indicator.onGrownTrash = { [weak self] in self?.onTrashed?() }
        indicator.onGrownClose = { [weak self] in self?.onClosed?() }
    }

    /// Suppression died with the separate window — kept for call sites.
    func resetSuppression() {}

    func showThinking(echo: String?) {
        indicator.showGrown(FloatingIndicator.GrownSpec(
            title: "Thinking…",
            text: echo.map { "You: \($0)" } ?? ""))
    }

    func beginStreaming() {
        indicator.beginGrownStream(title: "Replying…")
    }

    func appendDelta(_ delta: String) {
        indicator.appendGrownDelta(delta)
    }

    func finishStreaming(_ fullText: String) {
        indicator.finishGrownStream(fullText, title: nil)
    }

    /// A message grown out of the pill; `from` becomes the amber header.
    /// The hint line + brighter border mark a push that wants an answer.
    func showMessage(from title: String?, text: String, hint: String? = nil, isAsk: Bool = false) {
        indicator.showGrown(FloatingIndicator.GrownSpec(
            title: title, text: text, hint: hint, isAsk: isAsk))
    }

    func showNote(_ text: String) {
        showMessage(from: nil, text: text)
    }

    /// Legacy action-button variant — buttons are gone (the corner icons
    /// took their place); the text still shows.
    func showNote(_ text: String, actionTitle: String?, action: (() -> Void)?) {
        showMessage(from: nil, text: text)
    }

    /// Short receipts flash as a one-line stretch of the pill. Skipped
    /// while grown content is showing — hide() first when a receipt must
    /// replace it (e.g. after answering an ask).
    func showTransient(_ text: String, seconds: TimeInterval = 4,
                       actionTitle: String? = nil, action: (() -> Void)? = nil,
                       isError: Bool = false) {
        guard !indicator.isGrownVisible else { return }
        indicator.flashMessage(text, seconds: seconds, isError: isError)
    }

    func showAsk(prompt: String, hint: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        showMessage(from: nil, text: prompt, hint: hint, isAsk: true)
    }

    /// The old status line is gone — the hint line belongs to asks only.
    func setStatus(_ text: String) {}

    func hide() {
        indicator.hideGrown()
    }
}
