"""
Voice Flow — local speech-to-text dictation with LLM cleanup.

Hold Right Option to record, release to transcribe + clean + paste.
Double-tap Right Option for hands-free mode (tap again to stop).
Click the floating dots to view history. Right-click for settings/quit.
"""

import signal
import subprocess
import sys
import threading
import time
from datetime import datetime

from PyQt6.QtCore import QObject, pyqtSignal
from PyQt6.QtWidgets import QApplication
from pynput import keyboard

from voice_flow.config import Settings
from voice_flow.recorder import Recorder
from voice_flow.transcriber import Transcriber
from voice_flow.cleaner import Cleaner
from voice_flow.paster import paste_text
from voice_flow.ui import (
    MenuBarIcon,
    FloatingIndicator,
    AppWindow,
    SettingsDialog,
    State,
)


# ── map config string → pynput key ─────────────────────

_KEY_MAP = {
    "alt_r": keyboard.Key.alt_r,
    "alt_l": keyboard.Key.alt_l,
    "ctrl_r": keyboard.Key.ctrl_r,
    "ctrl_l": keyboard.Key.ctrl_l,
    "fn": keyboard.KeyCode.from_vk(63),  # macOS Fn/Globe key
    "f5": keyboard.Key.f5,
    "f6": keyboard.Key.f6,
    "f7": keyboard.Key.f7,
    "f8": keyboard.Key.f8,
}

_KEY_LABELS = {
    "alt_r": "Right Option",
    "alt_l": "Left Option",
    "ctrl_r": "Right Control",
    "ctrl_l": "Left Control",
    "fn": "Fn (Globe)",
    "f5": "F5",
    "f6": "F6",
    "f7": "F7",
    "f8": "F8",
}


# ── sound helper ────────────────────────────────────────

def _play_sound(name: str) -> None:
    if not Settings.get().sounds_enabled:
        return
    sounds = {
        "start": "/System/Library/Sounds/Tink.aiff",
        "done": "/System/Library/Sounds/Pop.aiff",
    }
    path = sounds.get(name)
    if path:
        subprocess.Popen(
            ["afplay", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


# ── dictation engine ────────────────────────────────────


class DictationEngine(QObject):
    """Record → transcribe → clean → paste pipeline."""

    state_changed = pyqtSignal(str)
    dictation_complete = pyqtSignal(str, str)  # cleaned text, timestamp

    def __init__(self):
        super().__init__()
        self.recorder = Recorder()
        self.transcriber = Transcriber()
        self.cleaner = Cleaner()
        self._busy = False

    def load_models(self):
        """Load both ML models (call from a background thread)."""
        print("[voice-flow] loading Parakeet STT model …")
        self.transcriber.load()
        print("[voice-flow] loading cleanup LLM …")
        self.cleaner.load()
        key_label = _KEY_LABELS.get(Settings.get().hotkey, Settings.get().hotkey)
        print(f"[voice-flow] ready — hold {key_label} to dictate, double-tap for hands-free")

    def start_recording(self):
        if self._busy:
            return
        _play_sound("start")
        self.state_changed.emit(State.RECORDING)
        self.recorder.start()

    def stop_recording(self):
        if not self.recorder.is_recording:
            return

        audio = self.recorder.stop()
        if len(audio) < 1600:  # < 100 ms of audio at 16 kHz → skip
            self.state_changed.emit(State.IDLE)
            return

        self._busy = True
        self.state_changed.emit(State.PROCESSING)
        threading.Thread(target=self._process, args=(audio,), daemon=True).start()

    def set_hands_free(self, active: bool):
        """Visual feedback for hands-free mode."""
        if active:
            self.state_changed.emit(State.HANDS_FREE)

    def _process(self, audio):
        try:
            raw = self.transcriber.transcribe(audio)
            if not raw:
                self.state_changed.emit(State.IDLE)
                return

            print(f"[voice-flow] raw: {raw}")
            cleaned = self.cleaner.clean(raw)
            print(f"[voice-flow] cleaned: {cleaned}")
            paste_text(cleaned)
            _play_sound("done")

            ts = datetime.now().strftime("%H:%M:%S")
            self.dictation_complete.emit(cleaned, ts)
            self.state_changed.emit(State.DONE)
        except Exception as exc:
            print(f"[voice-flow] error: {exc}")
            self.state_changed.emit(State.IDLE)
        finally:
            self._busy = False


# ── hotkey listener with double-tap hands-free ──────────


class HotkeyListener:
    """Global push-to-talk + double-tap hands-free via pynput."""

    def __init__(self, on_press, on_release, on_hands_free=None, key_name=None):
        self._on_press = on_press
        self._on_release = on_release
        self._on_hands_free = on_hands_free  # callback(bool)

        key_name = key_name or Settings.get().hotkey
        self._key = _KEY_MAP.get(key_name, keyboard.Key.alt_r)
        # For KeyCode keys (like Fn), compare by vk instead of identity
        self._vk = getattr(self._key, 'vk', None)

        self._pressed = False
        self._hands_free = False
        self._press_time = 0.0
        self._pending_release = False
        self._pending_timer: threading.Timer | None = None
        self._listener = None

    @property
    def is_hands_free(self):
        return self._hands_free

    def start(self):
        self._listener = keyboard.Listener(
            on_press=self._handle_press,
            on_release=self._handle_release,
        )
        self._listener.daemon = True
        self._listener.start()

    def stop(self):
        if self._listener:
            self._listener.stop()

    def update_key(self, key_name: str):
        """Change the hotkey without restarting the listener."""
        self._key = _KEY_MAP.get(key_name, keyboard.Key.alt_r)
        self._vk = getattr(self._key, 'vk', None)
        self._pressed = False
        self._hands_free = False
        self._pending_release = False
        if self._pending_timer:
            self._pending_timer.cancel()
            self._pending_timer = None
        label = _KEY_LABELS.get(key_name, key_name)
        print(f"[voice-flow] hotkey changed to {label}")

    def _key_matches(self, key):
        if self._vk is not None:
            return getattr(key, 'vk', None) == self._vk
        return key == self._key

    def _handle_press(self, key):
        if not self._key_matches(key):
            return

        # In hands-free mode: any tap stops it
        if self._hands_free:
            self._hands_free = False
            if self._on_hands_free:
                self._on_hands_free(False)
            self._on_release()
            return

        # Second tap while pending → double-tap → hands-free
        if self._pending_release:
            self._pending_release = False
            if self._pending_timer:
                self._pending_timer.cancel()
                self._pending_timer = None
            self._hands_free = True
            if self._on_hands_free:
                self._on_hands_free(True)
            # Recording already started from first tap — keep going
            return

        # Normal press → start recording
        if not self._pressed:
            self._pressed = True
            self._press_time = time.time()
            self._on_press()

    def _handle_release(self, key):
        if not self._key_matches(key) or not self._pressed:
            return

        # In hands-free: don't stop on release
        if self._hands_free:
            self._pressed = False
            return

        hold_ms = (time.time() - self._press_time) * 1000
        self._pressed = False
        dt_threshold = Settings.get().double_tap_ms

        if hold_ms < dt_threshold * 0.6:
            # Short tap — might be first of a double-tap; delay the stop
            self._pending_release = True
            self._pending_timer = threading.Timer(
                dt_threshold / 1000.0,
                self._finalize_release,
            )
            self._pending_timer.daemon = True
            self._pending_timer.start()
        else:
            # Normal hold release → stop immediately
            self._on_release()

    def _finalize_release(self):
        """Timer expired with no second tap → complete the stop."""
        if self._pending_release:
            self._pending_release = False
            self._on_release()


# ── main ────────────────────────────────────────────────


def _check_accessibility():
    """Check if we have Accessibility permission (non-blocking).

    Only shows the macOS prompt if permission is NOT yet granted.
    """
    try:
        from ApplicationServices import AXIsProcessTrustedWithOptions
        from Foundation import NSDictionary

        # First check WITHOUT prompting
        opts_quiet = NSDictionary.dictionaryWithObject_forKey_(False, "AXTrustedCheckOptionPrompt")
        trusted = AXIsProcessTrustedWithOptions(opts_quiet)
        if trusted:
            print("[voice-flow] accessibility permission OK")
            return True

        # Not trusted — now prompt the user
        opts_prompt = NSDictionary.dictionaryWithObject_forKey_(True, "AXTrustedCheckOptionPrompt")
        AXIsProcessTrustedWithOptions(opts_prompt)
        print("[voice-flow] accessibility not granted — macOS should prompt you")
        return False
    except Exception as e:
        print(f"[voice-flow] could not check accessibility: {e}")
        return True  # assume OK if we can't check


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    from pathlib import Path
    icon_path = Path(__file__).parent.parent / "assets" / "icon_app_512.png"

    try:
        from AppKit import NSApplication, NSImage
        ns_app = NSApplication.sharedApplication()
        # Do NOT call setActivationPolicy_ — any policy transition kills
        # the NSStatusBar item. LSUIElement=true in Info.plist handles dock.
        if icon_path.exists():
            ns_icon = NSImage.alloc().initByReferencingFile_(str(icon_path))
            ns_app.setApplicationIconImage_(ns_icon)
    except ImportError:
        pass

    _check_accessibility()

    app = QApplication(sys.argv)
    app.setApplicationName("Voice Flow")
    app.setQuitOnLastWindowClosed(False)

    from PyQt6.QtGui import QIcon
    if icon_path.exists():
        app.setWindowIcon(QIcon(str(icon_path)))

    # ── UI components ───────────────────────────────────

    menu_bar = MenuBarIcon()
    menu_bar.show()

    indicator = FloatingIndicator()
    indicator.show()
    indicator.position_on_screen()

    app_window = AppWindow()

    # ── wiring: open app window ─────────────────────────

    def toggle_app_window():
        if app_window.isVisible():
            app_window.hide()
        else:
            app_window.show()
            app_window.raise_()
            app_window.activateWindow()

    indicator.clicked.connect(toggle_app_window)
    menu_bar.history_action.triggered.connect(toggle_app_window)

    # ── wiring: settings dialog ─────────────────────────

    def open_settings():
        dlg = SettingsDialog()
        if dlg.exec():
            # Settings saved — update status text
            key = _KEY_LABELS.get(Settings.get().hotkey, Settings.get().hotkey)
            print(f"[voice-flow] settings saved — hotkey: {key} (restart to apply hotkey change)")

    menu_bar.settings_action.triggered.connect(open_settings)
    app_window.settings_btn.clicked.connect(open_settings)

    # ── engine ──────────────────────────────────────────

    engine = DictationEngine()

    def on_state(state):
        menu_bar.set_state(state)
        indicator.set_state(state)
        app_window.set_state(state)

    engine.state_changed.connect(on_state)
    engine.dictation_complete.connect(app_window.add_entry)

    on_state(State.LOADING)

    def _load():
        engine.load_models()
        engine.state_changed.emit(State.IDLE)

    threading.Thread(target=_load, daemon=True).start()

    # ── hotkey ──────────────────────────────────────────

    hotkey = HotkeyListener(
        on_press=engine.start_recording,
        on_release=engine.stop_recording,
        on_hands_free=engine.set_hands_free,
    )
    hotkey.start()

    # ── re-wire settings to apply hotkey live ──────────

    _orig_open_settings = open_settings

    def open_settings_live():
        old_key = Settings.get().hotkey
        dlg = SettingsDialog()
        if dlg.exec():
            new_key = Settings.get().hotkey
            if new_key != old_key:
                hotkey.update_key(new_key)

    menu_bar.settings_action.triggered.disconnect()
    app_window.settings_btn.clicked.disconnect()
    menu_bar.settings_action.triggered.connect(open_settings_live)
    app_window.settings_btn.clicked.connect(open_settings_live)

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
