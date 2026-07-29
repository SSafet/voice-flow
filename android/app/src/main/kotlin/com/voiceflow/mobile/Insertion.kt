package com.voiceflow.mobile

import android.accessibilityservice.AccessibilityService
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/// The "lands where the cursor is" half of the bubble (ticket VF-51) — the
/// Android kin of the Mac's Paster. An accessibility service can reach the
/// focused text field of whatever app is frontmost and set its text; the
/// bubble calls insert() with the finished transcript. Passive otherwise:
/// no events are consumed, nothing is read except the field being typed into.
class InsertionService : AccessibilityService() {

    override fun onServiceConnected() {
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /// Insert text at the cursor of the focused editable field. Returns false
    /// when there is nothing usable (no focus, non-editable, password box) —
    /// the caller falls back to the clipboard.
    fun insert(text: String): Boolean {
        val node = focusedEditable() ?: return false
        if (node.isPassword) return false
        val existing = if (node.isShowingHintText) "" else (node.text?.toString() ?: "")
        var selStart = node.textSelectionStart
        var selEnd = node.textSelectionEnd
        if (selStart < 0 || selStart > existing.length) selStart = existing.length
        if (selEnd < selStart || selEnd > existing.length) selEnd = selStart
        val before = existing.substring(0, selStart)
        val glue = if (before.isNotEmpty() && !before.last().isWhitespace()) " " else ""
        val args = Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
            before + glue + text + existing.substring(selEnd),
        )
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return false
        val cursor = selStart + glue.length + text.length
        val sel = Bundle()
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
        return true
    }

    private fun focusedEditable(): AccessibilityNodeInfo? {
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?.let { if (it.isEditable) return it }
        // Multi-window / IME-visible cases: the active window isn't always the
        // one holding input focus.
        for (w in windows) {
            val f = w.root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: continue
            if (f.isEditable) return f
        }
        return null
    }

    companion object {
        /// Same-process singleton: set while the user has the service enabled
        /// in Accessibility settings, null otherwise.
        var instance: InsertionService? = null
            private set
    }
}
