"""
Voice Flow UI — Warm Amber & Gold theme.

Three components:
  1. MenuBarIcon   – native NSStatusBar icon in the macOS menu bar
  2. FloatingIndicator – small pill at bottom-center of screen (fixed)
  3. AppWindow     – main window with dictation history
"""

import math
import time
from pathlib import Path

from PyQt6.QtCore import Qt, QPoint, QTimer, pyqtSignal, QSize
from PyQt6.QtGui import (
    QPainter, QColor, QBrush, QPainterPath, QIcon, QPixmap,
    QShortcut, QKeySequence, QLinearGradient, QPen, QFont,
)

_ASSETS = Path(__file__).parent.parent / "assets"
from PyQt6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QLabel,
    QMenu,
    QPushButton,
    QScrollArea,
    QSpinBox,
    QSystemTrayIcon,
    QVBoxLayout,
    QWidget,
)

from voice_flow.paster import copy_to_clipboard


# ── state constants ─────────────────────────────────────


class State:
    IDLE = "idle"
    LOADING = "loading"
    RECORDING = "recording"
    PROCESSING = "processing"
    DONE = "done"
    HANDS_FREE = "hands_free"


# ── warm amber/gold palette ─────────────────────────────

_BG = "#1c1a18"
_BG_LIGHTER = "#242018"
_CARD = "rgba(255, 245, 230, 8)"
_CARD_HOVER = "rgba(255, 245, 230, 16)"
_BORDER = "rgba(255, 220, 180, 16)"
_BORDER_HOVER = "rgba(255, 220, 180, 28)"
_TEXT = "#f0e6d6"
_TEXT2 = "#b0a090"
_TEXT3 = "#786858"
_SCROLL_HANDLE = "rgba(255, 220, 180, 30)"
_ACCENT = "#D4A853"
_ACCENT_DIM = "#A07830"
_ACCENT_GLOW = "rgba(212, 168, 83, 25)"

_CLR_IDLE = QColor(160, 140, 120)
_CLR_REC = QColor(220, 80, 60)
_CLR_PROC = QColor(212, 168, 83)
_CLR_PROC_HI = QColor(240, 210, 140)
_CLR_DONE = QColor(120, 180, 100)
_CLR_HF = QColor(230, 160, 50)

# State colors for status indicators
_STATE_COLORS = {
    State.IDLE: _TEXT3,
    State.LOADING: _ACCENT,
    State.RECORDING: "#DC5040",
    State.PROCESSING: _ACCENT,
    State.DONE: "#78B464",
    State.HANDS_FREE: "#E6A032",
}

_STATE_LABELS = {
    State.IDLE: "Ready",
    State.LOADING: "Loading\u2026",
    State.RECORDING: "Recording",
    State.PROCESSING: "Processing\u2026",
    State.DONE: "Done",
    State.HANDS_FREE: "Hands-Free",
}


# ── helpers ─────────────────────────────────────────────


def _make_logo_pixmap(size: int) -> QPixmap:
    """Load the app icon (glassmorphic, transparent bg) and scale it."""
    src_path = _ASSETS / "icon_app_512.png"
    src = QPixmap(str(src_path))
    if src.isNull():
        pm = QPixmap(size, size)
        pm.fill(Qt.GlobalColor.transparent)
        return pm

    dpr = 2.0
    real = int(size * dpr)
    scaled = src.scaled(
        QSize(real, real),
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )
    scaled.setDevicePixelRatio(dpr)

    return scaled


def _make_dot_icon(color: QColor) -> QIcon:
    """Render a three-dot QIcon for the menu bar (22x22 pt @2x)."""
    size = 44
    pixmap = QPixmap(size, size)
    pixmap.fill(Qt.GlobalColor.transparent)
    pixmap.setDevicePixelRatio(2.0)

    p = QPainter(pixmap)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setBrush(QBrush(color))
    p.setPen(Qt.PenStyle.NoPen)

    cy, r, sp = 11, 3, 6
    sx = 11 - sp

    for i in range(3):
        p.drawEllipse(QPoint(sx + i * sp, cy), r, r)

    p.end()
    return QIcon(pixmap)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  1. MENU BAR ICON (native NSStatusBar)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def _create_template_nsimage():
    """Create a proper template NSImage: pure black wave+dots on transparent.

    macOS template images MUST be pure black shapes on a transparent
    background. macOS then automatically tints them for light/dark mode.
    """
    from AppKit import NSImage, NSBezierPath, NSColor, NSGraphicsContext
    from Foundation import NSSize, NSRect, NSPoint, NSMakeRect

    size = NSSize(18, 18)
    img = NSImage.alloc().initWithSize_(size)
    img.lockFocus()

    NSColor.blackColor().setFill()

    # Draw three dots with connecting wave curves
    path = NSBezierPath.bezierPath()

    # Dot positions (matching the icon motif)
    dots = [(3.5, 9), (9, 9), (14.5, 9)]
    r = 2.0

    # Draw dots
    for x, y in dots:
        dot_rect = NSMakeRect(x - r, y - r, r * 2, r * 2)
        path.appendBezierPathWithOvalInRect_(dot_rect)

    # Draw wave connecting lines
    wave = NSBezierPath.bezierPath()
    wave.setLineWidth_(1.5)
    wave.moveToPoint_(NSPoint(3.5, 9))
    wave.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(9, 9), NSPoint(5.5, 4), NSPoint(7, 4)
    )
    wave.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(14.5, 9), NSPoint(11, 14), NSPoint(12.5, 14)
    )

    NSColor.blackColor().setStroke()
    wave.stroke()
    path.fill()

    img.unlockFocus()
    img.setTemplate_(True)
    return img


class MenuBarIcon:
    """Native macOS status bar icon with a dropdown menu."""

    def __init__(self):
        self._native = False
        self._qt_tray = None
        self.history_action = None
        self.settings_action = None
        self._status_action = None

        try:
            self._init_native()
        except Exception as e:
            print(f"[voice-flow] native menu bar failed ({e}), using Qt fallback")
            self._init_qt_fallback()

    def _init_native(self):
        from AppKit import (
            NSStatusBar, NSVariableStatusItemLength,
            NSMenu, NSMenuItem,
        )
        from Foundation import NSObject
        import objc

        bar = NSStatusBar.systemStatusBar()
        self._status_item = bar.statusItemWithLength_(NSVariableStatusItemLength)

        # Create proper template image programmatically
        try:
            img = _create_template_nsimage()
            self._status_item.button().setImage_(img)
            self._status_item.button().setTitle_("")
        except Exception as e:
            print(f"[voice-flow] template image failed ({e}), using text")
            self._status_item.button().setTitle_("\u2022\u2022\u2022")

        # Build native menu
        menu = NSMenu.alloc().init()

        self._ns_status_item = menu.addItemWithTitle_action_keyEquivalent_(
            "Voice Flow \u2014 Loading\u2026", None, ""
        )
        self._ns_status_item.setEnabled_(False)

        menu.addItem_(NSMenuItem.separatorItem())

        class _Delegate(NSObject):
            _callbacks = {}

            @objc.python_method
            def register(self, name, callback):
                self._callbacks[name] = callback

            def menuAction_(self, sender):
                title = sender.title()
                cb = self._callbacks.get(title)
                if cb:
                    cb()

        self._delegate = _Delegate.alloc().init()

        for title in ("Show History", "Settings\u2026"):
            item = menu.addItemWithTitle_action_keyEquivalent_(
                title, "menuAction:", ""
            )
            item.setTarget_(self._delegate)

        menu.addItem_(NSMenuItem.separatorItem())

        quit_item = menu.addItemWithTitle_action_keyEquivalent_(
            "Quit Voice Flow", "menuAction:", ""
        )
        quit_item.setTarget_(self._delegate)
        self._delegate.register("Quit Voice Flow", lambda: QApplication.quit())

        self._status_item.setMenu_(menu)
        self._native = True

        # Signal proxies for compatibility with app.py wiring
        class _SignalProxy:
            def __init__(self):
                self._callbacks = []
            def connect(self, cb):
                self._callbacks.append(cb)
            def disconnect(self):
                self._callbacks.clear()

        self.history_action = type('obj', (object,), {'triggered': _SignalProxy()})()
        self.settings_action = type('obj', (object,), {'triggered': _SignalProxy()})()

        def _on_history():
            for cb in self.history_action.triggered._callbacks:
                cb()

        def _on_settings():
            for cb in self.settings_action.triggered._callbacks:
                cb()

        self._delegate.register("Show History", _on_history)
        self._delegate.register("Settings\u2026", _on_settings)

    def _init_qt_fallback(self):
        self._qt_tray = QSystemTrayIcon()
        self._icons = {
            State.IDLE: _make_dot_icon(_CLR_IDLE),
            State.LOADING: _make_dot_icon(_CLR_PROC),
            State.RECORDING: _make_dot_icon(_CLR_REC),
            State.PROCESSING: _make_dot_icon(_CLR_PROC),
            State.DONE: _make_dot_icon(_CLR_DONE),
            State.HANDS_FREE: _make_dot_icon(_CLR_HF),
        }
        self._qt_tray.setIcon(self._icons[State.IDLE])

        menu = QMenu()
        self._status_action = menu.addAction("Voice Flow \u2014 Loading\u2026")
        self._status_action.setEnabled(False)
        menu.addSeparator()
        self.history_action = menu.addAction("Show History")
        self.settings_action = menu.addAction("Settings\u2026")
        menu.addSeparator()
        quit_action = menu.addAction("Quit Voice Flow")
        quit_action.triggered.connect(QApplication.quit)
        self._qt_tray.setContextMenu(menu)

    def show(self):
        if self._native:
            print("[voice-flow] native menu bar icon active")
        elif self._qt_tray:
            self._qt_tray.setVisible(True)
            self._qt_tray.show()
            print(f"[voice-flow] tray icon visible: {self._qt_tray.isVisible()}")

    def set_state(self, state: str):
        labels = {
            State.IDLE: "Voice Flow \u2014 Ready",
            State.LOADING: "Voice Flow \u2014 Loading\u2026",
            State.RECORDING: "Voice Flow \u2014 Recording",
            State.PROCESSING: "Voice Flow \u2014 Processing\u2026",
            State.DONE: "Voice Flow \u2014 Done",
            State.HANDS_FREE: "Voice Flow \u2014 Hands-Free",
        }
        label = labels.get(state, "Voice Flow")
        if self._native:
            self._ns_status_item.setTitle_(label)
        elif self._qt_tray:
            self._qt_tray.setIcon(self._icons.get(state, self._icons[State.IDLE]))
            if self._status_action:
                self._status_action.setText(label)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  2. FLOATING INDICATOR  (bottom-center, fixed, no drag)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class FloatingIndicator(QWidget):
    """Tiny frosted-glass pill with three dots. Fixed at bottom-center.

    Uses macOS Core Animation for GPU-composited rendering when available.
    """

    clicked = pyqtSignal()

    DOT_R = 3
    DOT_SP = 10
    W = 48
    H = 22

    def __init__(self):
        super().__init__()
        self.state = State.IDLE

        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setFixedSize(self.W, self.H)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

        self._native = False
        self._init_native()

        if not self._native:
            self._t0 = time.monotonic()
            self._timer = QTimer(self)
            self._timer.setTimerType(Qt.TimerType.PreciseTimer)
            self._timer.timeout.connect(self.repaint)
            self._timer.start(16)

    def _init_native(self):
        try:
            import objc
            from ctypes import c_void_p
            from AppKit import NSFloatingWindowLevel
            from Quartz import (
                CALayer, CABasicAnimation, CAKeyframeAnimation,
                CAMediaTimingFunction, CATransaction,
                CGColorCreate, CGColorSpaceCreateDeviceRGB,
            )

            ns_view = objc.objc_object(c_void_p=c_void_p(int(self.winId())))
            ns_win = ns_view.window()
            ns_win.setLevel_(NSFloatingWindowLevel)
            ns_win.setCollectionBehavior_((1 << 0) | (1 << 4))
            ns_win.setHasShadow_(False)

            ns_view.setWantsLayer_(True)
            root = ns_view.layer()

            self._CABasic = CABasicAnimation
            self._CAKeyframe = CAKeyframeAnimation
            self._CATiming = CAMediaTimingFunction
            self._CATx = CATransaction
            self._ca_space = CGColorSpaceCreateDeviceRGB()
            self._CGColor = CGColorCreate

            self._ca_pill = CALayer.layer()
            self._ca_pill.setFrame_(((0.5, 0.5), (self.W - 1, self.H - 1)))
            self._ca_pill.setCornerRadius_(11.0)
            self._ca_pill.setBorderWidth_(1.0)
            root.addSublayer_(self._ca_pill)

            spec = CALayer.layer()
            spec_h = self.H * 0.42
            spec.setFrame_(((1.5, self.H - 1.0 - spec_h),
                            (self.W - 3, spec_h)))
            spec.setCornerRadius_(10.0)
            spec.setBackgroundColor_(self._cg(255, 245, 230, 10))
            root.addSublayer_(spec)

            self._ca_dots = []
            cy = self.H / 2.0
            sx = (self.W - 2 * self.DOT_SP) / 2.0
            for i in range(3):
                dot = CALayer.layer()
                x = sx + i * self.DOT_SP
                dot.setFrame_(((x - self.DOT_R, cy - self.DOT_R),
                               (self.DOT_R * 2, self.DOT_R * 2)))
                dot.setCornerRadius_(self.DOT_R)
                root.addSublayer_(dot)
                self._ca_dots.append(dot)

            self._native = True
            self._apply_ca_state()

        except Exception as e:
            print(f"[voice-flow] CA not available ({e}), using QPainter fallback")
            self._native = False
            try:
                from AppKit import NSFloatingWindowLevel
                from ctypes import c_void_p
                import objc
                ns_view = objc.objc_object(c_void_p=int(self.winId()))
                ns_win = ns_view.window()
                ns_win.setLevel_(NSFloatingWindowLevel)
                ns_win.setCollectionBehavior_((1 << 0) | (1 << 4))
            except Exception:
                pass

    def _cg(self, r, g, b, a):
        return self._CGColor(self._ca_space, (r / 255, g / 255, b / 255, a / 255))

    def position_on_screen(self):
        geo = QApplication.primaryScreen().geometry()
        self.move((geo.width() - self.W) // 2, geo.height() - self.H - 4)

    def set_state(self, state: str):
        self.state = state
        if self._native:
            self._apply_ca_state()
        else:
            self._t0 = time.monotonic()
        if state == State.DONE:
            QTimer.singleShot(800, self._auto_idle)

    def _auto_idle(self):
        if self.state == State.DONE:
            self.state = State.IDLE
            if self._native:
                self._apply_ca_state()

    def _apply_ca_state(self):
        self._ca_pill.removeAllAnimations()
        for dot in self._ca_dots:
            dot.removeAllAnimations()

        self._CATx.begin()
        self._CATx.setDisableActions_(True)

        s = self.state
        if s == State.RECORDING:
            self._ca_pill.setBackgroundColor_(self._cg(110, 50, 45, 115))
            self._ca_pill.setBorderColor_(self._cg(220, 160, 140, 45))
            for d in self._ca_dots:
                d.setBackgroundColor_(self._cg(255, 240, 220, 180))
            self._CATx.commit()
            self._ca_add_pulse(1.45)
            self._ca_add_dot_scale(cycle=2.4)

        elif s == State.HANDS_FREE:
            self._ca_pill.setBackgroundColor_(self._cg(100, 75, 30, 120))
            self._ca_pill.setBorderColor_(self._cg(230, 190, 100, 50))
            for d in self._ca_dots:
                d.setBackgroundColor_(self._cg(255, 240, 200, 190))
            self._CATx.commit()
            self._ca_add_pulse(1.6)
            self._ca_add_dot_scale(cycle=2.8)

        elif s in (State.PROCESSING, State.LOADING):
            self._ca_pill.setBackgroundColor_(self._cg(100, 80, 40, 110))
            self._ca_pill.setBorderColor_(self._cg(212, 168, 83, 45))
            for d in self._ca_dots:
                d.setBackgroundColor_(self._cg(255, 240, 200, 170))
            self._CATx.commit()
            self._ca_add_pulse(1.8)
            self._ca_add_dot_bounce(cycle=2.1)

        elif s == State.DONE:
            self._ca_pill.setBackgroundColor_(self._cg(60, 90, 50, 120))
            self._ca_pill.setBorderColor_(self._cg(160, 210, 140, 50))
            for d in self._ca_dots:
                d.setBackgroundColor_(self._cg(255, 245, 220, 190))
            self._CATx.commit()

        else:
            self._ca_pill.setBackgroundColor_(self._cg(55, 48, 40, 80))
            self._ca_pill.setBorderColor_(self._cg(255, 220, 180, 14))
            for d in self._ca_dots:
                d.setBackgroundColor_(self._cg(255, 240, 220, 110))
            self._CATx.commit()

    def _ca_add_pulse(self, duration):
        ease = self._CATiming.functionWithName_("easeInEaseOut")
        anim = self._CABasic.animationWithKeyPath_("opacity")
        anim.setFromValue_(0.72)
        anim.setToValue_(1.0)
        anim.setDuration_(duration)
        anim.setAutoreverses_(True)
        anim.setRepeatCount_(1e9)
        anim.setTimingFunction_(ease)
        self._ca_pill.addAnimation_forKey_(anim, "pulse")

    def _ca_add_dot_scale(self, cycle):
        ease = self._CATiming.functionWithName_("easeInEaseOut")
        for i, dot in enumerate(self._ca_dots):
            anim = self._CAKeyframe.animationWithKeyPath_("transform.scale")
            anim.setValues_([1.0, 1.35, 1.0])
            anim.setKeyTimes_([0.0, 0.5, 1.0])
            anim.setTimingFunctions_([ease, ease])
            anim.setDuration_(cycle)
            anim.setRepeatCount_(1e9)
            anim.setTimeOffset_((2 - i) * cycle / 3.0)
            dot.addAnimation_forKey_(anim, "scale")

    def _ca_add_dot_bounce(self, cycle):
        ease = self._CATiming.functionWithName_("easeInEaseOut")
        cy = self.H / 2.0
        for i, dot in enumerate(self._ca_dots):
            anim = self._CAKeyframe.animationWithKeyPath_("position.y")
            anim.setValues_([cy, cy + 2.5, cy])
            anim.setKeyTimes_([0.0, 0.5, 1.0])
            anim.setTimingFunctions_([ease, ease])
            anim.setDuration_(cycle)
            anim.setRepeatCount_(1e9)
            anim.setTimeOffset_((2 - i) * cycle / 3.0)
            dot.addAnimation_forKey_(anim, "bounce")

    # ── QPainter fallback ────────────────────────────────

    def paintEvent(self, event):
        if self._native:
            return

        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        t = time.monotonic() - self._t0

        if self.state == State.RECORDING:
            pulse = 0.5 + 0.5 * math.sin(t * 2.2)
            bg_fill = QColor(110, 50, 45, int(100 + 30 * pulse))
            border_c = QColor(220, 160, 140, int(35 + 20 * pulse))
            dot_c = QColor(255, 240, 220, int(160 + 40 * pulse))
        elif self.state == State.HANDS_FREE:
            pulse = 0.5 + 0.5 * math.sin(t * 1.9)
            bg_fill = QColor(100, 75, 30, int(110 + 25 * pulse))
            border_c = QColor(230, 190, 100, int(40 + 20 * pulse))
            dot_c = QColor(255, 240, 200, int(170 + 40 * pulse))
        elif self.state in (State.PROCESSING, State.LOADING):
            sh = 0.5 + 0.5 * math.sin(t * 1.75)
            bg_fill = QColor(100, 80, 40, int(100 + 20 * sh))
            border_c = QColor(212, 168, 83, int(30 + 25 * sh))
            dot_c = QColor(255, 240, 200, int(150 + 40 * sh))
        elif self.state == State.DONE:
            bg_fill = QColor(60, 90, 50, 120)
            border_c = QColor(160, 210, 140, 50)
            dot_c = QColor(255, 245, 220, 190)
        else:
            bg_fill = QColor(55, 48, 40, 80)
            border_c = QColor(255, 220, 180, 14)
            dot_c = QColor(255, 240, 220, 110)

        pill = QPainterPath()
        pill.addRoundedRect(0.5, 0.5, self.W - 1, self.H - 1, 11.0, 11.0)
        p.fillPath(pill, bg_fill)
        p.setPen(border_c)
        p.drawPath(pill)

        spec = QPainterPath()
        spec.addRoundedRect(1.5, 1.0, self.W - 3, self.H * 0.42, 10.0, 10.0)
        p.fillPath(spec, QColor(255, 245, 230, 10))

        cy = self.H / 2.0
        sx = (self.W - 2 * self.DOT_SP) / 2.0
        p.setPen(Qt.PenStyle.NoPen)
        for i in range(3):
            y_off = 0.0
            if self.state in (State.RECORDING, State.HANDS_FREE):
                speed = 1.5 if self.state == State.HANDS_FREE else 1.75
                phase = (t * speed - i * 1.0) % (math.pi * 2)
                v = max(0.0, math.sin(phase))
                eased = v * v * (3.0 - 2.0 * v)
                r = max(1, round(self.DOT_R * (1.0 + eased * 0.35)))
                p.setBrush(QBrush(dot_c))
                p.drawEllipse(QPoint(int(sx + i * self.DOT_SP), int(cy)), r, r)
                continue
            if self.state in (State.PROCESSING, State.LOADING):
                phase = t * 3.0 - i * 0.9
                y_off = -abs(math.sin(phase)) * 2.5
            p.setBrush(QBrush(dot_c))
            p.drawEllipse(QPoint(int(sx + i * self.DOT_SP), int(cy + y_off)),
                          self.DOT_R, self.DOT_R)
        p.end()

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()

    def contextMenuEvent(self, event):
        menu = QMenu()
        menu.setStyleSheet(
            f"QMenu {{ background: #2a2520; color: {_TEXT}; border: 1px solid {_BORDER};"
            "        border-radius: 6px; padding: 4px; }"
            "QMenu::item { padding: 4px 16px; }"
            f"QMenu::item:selected {{ background: {_ACCENT_DIM}; }}"
        )
        show_hist = menu.addAction("Show History")
        menu.addSeparator()
        quit_act = menu.addAction("Quit Voice Flow")
        action = menu.exec(event.globalPos())
        if action == quit_act:
            QApplication.quit()
        elif action == show_hist:
            self.clicked.emit()


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  3. APP WINDOW  (dictation history)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def _set_dock_visible(visible: bool):
    """Show/hide dock icon by toggling activation policy.

    Only switch TO regular (show dock). Never switch back to accessory
    because that kills the NSStatusBar item. LSUIElement=true in
    Info.plist handles the initial dock-hidden state.
    """
    if not visible:
        return  # let LSUIElement handle hiding; don't kill status bar
    try:
        from AppKit import (
            NSApplication,
            NSApplicationActivationPolicyRegular,
        )
        NSApplication.sharedApplication().setActivationPolicy_(
            NSApplicationActivationPolicyRegular
        )
    except Exception:
        pass


class HistoryEntry(QFrame):
    """Single dictation card."""

    def __init__(self, text: str, timestamp: str, parent=None):
        super().__init__(parent)
        self.full_text = text
        self.setObjectName("card")
        self._apply_default_style()

        lay = QHBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 10)
        lay.setSpacing(10)

        left = QVBoxLayout()
        left.setSpacing(3)

        lbl = QLabel(text)
        lbl.setWordWrap(True)
        lbl.setStyleSheet(
            f"color: {_TEXT}; font-size: 13px;"
            " background: transparent; border: none;"
        )
        left.addWidget(lbl)

        ts = QLabel(timestamp)
        ts.setStyleSheet(
            f"color: {_TEXT3}; font-size: 10px;"
            " background: transparent; border: none;"
        )
        left.addWidget(ts)

        lay.addLayout(left, stretch=1)

        btn = QPushButton("Copy")
        btn.setFixedHeight(24)
        btn.setCursor(Qt.CursorShape.PointingHandCursor)
        btn.setStyleSheet(
            "QPushButton {"
            f"  background: transparent; color: {_TEXT3};"
            f"  border: 1px solid {_BORDER}; border-radius: 4px;"
            "  font-size: 11px; padding: 0 10px;"
            "}"
            "QPushButton:hover {"
            f"  background: {_ACCENT_GLOW}; color: {_ACCENT};"
            f"  border-color: {_ACCENT_DIM};"
            "}"
        )
        btn.clicked.connect(self._copy)
        lay.addWidget(btn, alignment=Qt.AlignmentFlag.AlignTop)

    def _apply_default_style(self):
        self.setStyleSheet(
            "#card {"
            f"  background: {_CARD};"
            f"  border: 1px solid {_BORDER};"
            "  border-radius: 8px;"
            "}"
            "#card:hover {"
            f"  background: {_CARD_HOVER};"
            f"  border: 1px solid {_BORDER_HOVER};"
            "}"
        )

    def _copy(self):
        copy_to_clipboard(self.full_text)
        self.setStyleSheet(
            f"#card {{ background: rgba(120, 180, 100, 15);"
            f"  border: 1px solid rgba(120, 180, 100, 30); border-radius: 8px; }}"
        )
        QTimer.singleShot(400, self._apply_default_style)


class AppWindow(QWidget):
    """Main app window — dictation history with branded design."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Voice Flow")
        self.setMinimumSize(420, 360)
        self.resize(460, 620)

        icon_path = _ASSETS / "icon_marketing_512.png"
        if icon_path.exists():
            self.setWindowIcon(QIcon(str(icon_path)))

        QShortcut(QKeySequence("Ctrl+W"), self, activated=self.close)

        self.setStyleSheet(
            f"QWidget {{ background: {_BG}; color: {_TEXT};"
            f"  font-family: 'SF Pro Text', 'Helvetica Neue', sans-serif; }}"
        )

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # ── header ──────────────────────────────────────
        header = QWidget()
        header.setObjectName("header")
        header.setFixedHeight(80)
        header.setStyleSheet(
            f"#header {{ background: {_BG_LIGHTER};"
            f"  border-bottom: 1px solid {_BORDER}; }}"
        )
        hdr = QHBoxLayout(header)
        hdr.setContentsMargins(20, 0, 16, 0)
        hdr.setSpacing(14)

        # Logo — programmatic amber/gold on transparent
        logo_pm = _make_logo_pixmap(44)
        self._logo = QLabel()
        self._logo.setPixmap(logo_pm)
        self._logo.setStyleSheet("border: none; background: transparent;")
        hdr.addWidget(self._logo)

        # Title block
        title_block = QVBoxLayout()
        title_block.setSpacing(2)

        title = QLabel("Voice Flow")
        title.setStyleSheet(
            f"color: {_ACCENT}; font-size: 17px; font-weight: 700;"
            " border: none; background: transparent;"
        )
        title_block.addWidget(title)

        subtitle = QLabel("Local speech-to-text dictation")
        subtitle.setStyleSheet(
            f"color: {_TEXT3}; font-size: 11px;"
            " border: none; background: transparent;"
        )
        title_block.addWidget(subtitle)

        hdr.addLayout(title_block)
        hdr.addStretch()

        # Status pill
        self._status_pill = QLabel()
        self._status_pill.setFixedHeight(22)
        self._status_pill.setStyleSheet(
            f"background: {_ACCENT_GLOW}; color: {_ACCENT};"
            " font-size: 11px; font-weight: 500;"
            " border-radius: 11px; padding: 0 10px;"
            " border: none;"
        )
        self._status_pill.setText("Loading\u2026")
        hdr.addWidget(self._status_pill)

        # Settings gear
        self.settings_btn = QPushButton("\u2699")
        self.settings_btn.setFixedSize(30, 30)
        self.settings_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.settings_btn.setToolTip("Settings")
        self.settings_btn.setStyleSheet(
            "QPushButton {"
            f"  background: transparent; color: {_TEXT3};"
            "  border: none; font-size: 17px;"
            "}"
            "QPushButton:hover {"
            f"  color: {_ACCENT};"
            "}"
        )
        hdr.addWidget(self.settings_btn)

        root.addWidget(header)

        # ── content ─────────────────────────────────────
        content = QWidget()
        content.setStyleSheet("background: transparent; border: none;")
        clayout = QVBoxLayout(content)
        clayout.setContentsMargins(20, 16, 20, 20)
        clayout.setSpacing(10)

        # Section header row
        sec_row = QHBoxLayout()
        sec = QLabel("DICTATIONS")
        sec.setStyleSheet(
            f"color: {_TEXT3}; font-size: 10px;"
            " letter-spacing: 1.5px; font-weight: 600;"
        )
        sec_row.addWidget(sec)
        sec_row.addStretch()
        clayout.addLayout(sec_row)

        # Scroll area
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet(
            "QScrollArea { border: none; background: transparent; }"
            " QScrollBar:vertical { width: 4px; background: transparent; }"
            f" QScrollBar::handle:vertical {{"
            f"  background: {_SCROLL_HANDLE}; border-radius: 2px; min-height: 24px;"
            f" }}"
            " QScrollBar::add-line:vertical,"
            " QScrollBar::sub-line:vertical { height: 0; }"
        )

        self._container = QWidget()
        self._container.setStyleSheet("background: transparent;")
        self._entries = QVBoxLayout(self._container)
        self._entries.setContentsMargins(0, 0, 0, 0)
        self._entries.setSpacing(6)
        self._entries.addStretch()

        scroll.setWidget(self._container)
        clayout.addWidget(scroll)

        root.addWidget(content)

        # ── empty state ─────────────────────────────────
        empty_widget = QWidget()
        empty_widget.setStyleSheet("background: transparent; border: none;")
        empty_lay = QVBoxLayout(empty_widget)
        empty_lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        empty_lay.setSpacing(8)

        # Show logo in empty state
        empty_icon = QLabel()
        empty_icon.setPixmap(_make_logo_pixmap(72))
        empty_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        empty_icon.setStyleSheet("border: none; background: transparent;")
        empty_lay.addWidget(empty_icon)

        empty_title = QLabel("No dictations yet")
        empty_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        empty_title.setStyleSheet(
            f"color: {_TEXT2}; font-size: 14px; font-weight: 500;"
        )
        empty_lay.addWidget(empty_title)

        empty_hint = QLabel("Hold Right Option to start dictating")
        empty_hint.setAlignment(Qt.AlignmentFlag.AlignCenter)
        empty_hint.setStyleSheet(f"color: {_TEXT3}; font-size: 12px;")
        empty_lay.addWidget(empty_hint)

        self._empty = empty_widget
        self._entries.insertWidget(0, self._empty)

    # ── public api ──────────────────────────────────────

    def set_state(self, state: str):
        text = _STATE_LABELS.get(state, "")
        color = _STATE_COLORS.get(state, _TEXT3)
        self._status_pill.setText(text)
        if state == State.IDLE:
            self._status_pill.setStyleSheet(
                f"background: transparent; color: {_TEXT3};"
                " font-size: 11px; font-weight: 500;"
                " border-radius: 11px; padding: 0 10px;"
                f" border: 1px solid {_BORDER};"
            )
        else:
            self._status_pill.setStyleSheet(
                f"background: rgba({_qcolor_to_rgb(color)}, 0.12);"
                f" color: {color};"
                " font-size: 11px; font-weight: 500;"
                " border-radius: 11px; padding: 0 10px;"
                " border: none;"
            )

    def add_entry(self, text: str, timestamp: str):
        if self._empty.isVisible():
            self._empty.hide()

        from datetime import date
        today = date.today()
        today_str = today.isoformat()
        if not hasattr(self, "_last_day") or self._last_day != today_str:
            self._last_day = today_str
            day_text = "Today" if today == date.today() else today.strftime("%A, %B %-d")
            day_lbl = QLabel(day_text)
            day_lbl.setStyleSheet(
                f"color: {_TEXT2}; font-size: 11px; font-weight: 600;"
                " letter-spacing: 0.5px; padding: 8px 0 2px 0;"
            )
            self._entries.insertWidget(0, day_lbl)

        entry = HistoryEntry(text, timestamp)
        self._entries.insertWidget(1 if hasattr(self, "_last_day") else 0, entry)

        while self._entries.count() > 62:
            item = self._entries.itemAt(self._entries.count() - 2)
            w = item.widget() if item else None
            if w and w is not self._empty:
                w.deleteLater()

    def closeEvent(self, event):
        event.ignore()
        self.hide()


def _qcolor_to_rgb(hex_color: str) -> str:
    """Convert '#RRGGBB' or named color to 'R, G, B' for rgba()."""
    c = QColor(hex_color)
    return f"{c.red()}, {c.green()}, {c.blue()}"


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  4. SETTINGS DIALOG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


_HOTKEY_OPTIONS = [
    ("Right Option", "alt_r"),
    ("Left Option", "alt_l"),
    ("Right Control", "ctrl_r"),
    ("Left Control", "ctrl_l"),
    ("Fn (Globe)", "fn"),
    ("F5", "f5"),
    ("F6", "f6"),
    ("F7", "f7"),
    ("F8", "f8"),
]


class SettingsDialog(QDialog):
    """Settings dialog — hotkey, sounds, double-tap threshold."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Voice Flow Settings")
        self.setFixedSize(360, 240)
        QShortcut(QKeySequence("Ctrl+W"), self, activated=self.close)

        self.setStyleSheet(
            f"QDialog {{ background: {_BG}; color: {_TEXT};"
            f"  font-family: 'SF Pro Text', 'Helvetica Neue', sans-serif; }}"
            f" QLabel {{ color: {_TEXT}; font-size: 13px; }}"
            f" QComboBox {{ background: #2a2520; color: {_TEXT};"
            f"  border: 1px solid {_BORDER}; border-radius: 6px;"
            f"  padding: 4px 8px; font-size: 13px; }}"
            f" QComboBox::drop-down {{ border: none; }}"
            f" QComboBox QAbstractItemView {{ background: #2a2520; color: {_TEXT};"
            f"  selection-background-color: {_ACCENT_DIM}; border: 1px solid {_BORDER}; }}"
            f" QSpinBox {{ background: #2a2520; color: {_TEXT};"
            f"  border: 1px solid {_BORDER}; border-radius: 6px;"
            f"  padding: 4px 8px; font-size: 13px; }}"
            f" QCheckBox {{ color: {_TEXT}; font-size: 13px; spacing: 6px; }}"
            f" QCheckBox::indicator {{ width: 16px; height: 16px;"
            f"  border: 1px solid {_BORDER}; border-radius: 4px;"
            f"  background: #2a2520; }}"
            f" QCheckBox::indicator:checked {{ background: {_ACCENT};"
            f"  border-color: {_ACCENT}; }}"
        )

        from voice_flow.config import Settings

        self._settings = Settings.get()

        form = QFormLayout(self)
        form.setContentsMargins(24, 24, 24, 20)
        form.setSpacing(14)

        self._hotkey_combo = QComboBox()
        self._hotkey_combo.setMinimumWidth(180)
        current_idx = 0
        for i, (label, value) in enumerate(_HOTKEY_OPTIONS):
            self._hotkey_combo.addItem(label, value)
            if value == self._settings.hotkey:
                current_idx = i
        self._hotkey_combo.setCurrentIndex(current_idx)
        form.addRow("Hotkey:", self._hotkey_combo)

        self._sounds_cb = QCheckBox("Enable sounds")
        self._sounds_cb.setChecked(self._settings.sounds_enabled)
        form.addRow("", self._sounds_cb)

        self._dt_spin = QSpinBox()
        self._dt_spin.setRange(200, 800)
        self._dt_spin.setSingleStep(50)
        self._dt_spin.setSuffix(" ms")
        self._dt_spin.setValue(self._settings.double_tap_ms)
        form.addRow("Double-tap window:", self._dt_spin)

        btn_box = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        btn_box.setStyleSheet(
            f"QPushButton {{ background: #2a2520; color: {_TEXT};"
            f"  border: 1px solid {_BORDER}; border-radius: 6px;"
            f"  padding: 6px 16px; font-size: 13px; }}"
            f" QPushButton:hover {{ background: {_ACCENT_DIM}; color: #fff; }}"
        )
        btn_box.accepted.connect(self._save)
        btn_box.rejected.connect(self.reject)
        form.addRow(btn_box)

    def _save(self):
        self._settings.hotkey = self._hotkey_combo.currentData()
        self._settings.sounds_enabled = self._sounds_cb.isChecked()
        self._settings.double_tap_ms = self._dt_spin.value()
        self._settings.save()
        self.accept()
