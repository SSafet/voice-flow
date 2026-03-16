import subprocess
import time


def paste_text(text: str) -> None:
    """Copy text to clipboard and paste into the currently active text field."""
    copy_to_clipboard(text)
    time.sleep(0.05)  # let clipboard settle
    subprocess.run(
        [
            "osascript",
            "-e",
            'tell application "System Events" to keystroke "v" using command down',
        ],
        capture_output=True,
    )


def copy_to_clipboard(text: str) -> None:
    """Copy text to the macOS clipboard (no paste)."""
    process = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
    process.communicate(text.encode("utf-8"))
