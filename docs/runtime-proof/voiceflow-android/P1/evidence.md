p1-phone-check.sh observes 08 section 8 item 1 on Safet's phone: it builds and installs the debug APK with the repository's own wrapper, records `adb shell dumpsys activity services com.voiceflow.mobile` before and after one dictation the operator performs by hand into another app's text field, and records `adb logcat -d` filtered to the app and to `ForegroundServiceStartNotAllowedException` and "Foreground service started from background can not have microphone access". Whether the text reached the cursor is the screen recording's to show; each run appends one line naming its result and the recording by absolute path below.

## Runs

No run recorded yet.
