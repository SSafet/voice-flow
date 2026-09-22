from pathlib import Path
import unittest

class Wiring(unittest.TestCase):
    def test_native_route_precedes_legacy_send(self):
        source = Path('swift/App.swift').read_text()
        delivery = source[source.index('func maybeDeliverCapture'):source.index('func pruneFinishedCaptureRuns')]
        self.assertLess(delivery.index('deliverCaptureToShell(run)'), delivery.index('AssistantWakeMatcher.resolve'))
        self.assertIn('case .nativeDraft: return', delivery)
        begin = source[source.index('func beginCapture'):source.index('func stopCapture')]
        self.assertLess(begin.index('try source.retainAudio'), begin.index('recorder.start()'))
        self.assertIn('shellInputWindow?.window.isKeyWindow == true', begin)

    def test_boot_and_recovery_are_explicit(self):
        source = Path('swift/App+ShellInput.swift').read_text()
        for prohibited in ['NSApplication.shared', '.attach(credential:', 'deliverToAgent(', 'Process()', 'window.show()', '.reserve(destination)\n        else']:
            self.assertNotIn(prohibited, source)
        self.assertIn('func configureShellInput', source)
        self.assertIn('func reconcileShellInput', source)
        self.assertIn('run.capability == .dictate', source)
        self.assertIn('custody.destination(deliveryId) == destination', source)

    def test_main_frame_gate_wraps_read(self):
        source = Path('swift/Shell/T3ShellWindow.swift').read_text()
        method = source[source.index('func receive('):]
        self.assertLess(method.index('message.frameInfo.isMainFrame'), method.index('case "readCapture"'))
        self.assertLess(method.index('securityOrigin'), method.index('case "readCapture"'))
        self.assertIn('inputCustody?.owns(input)', source)

unittest.main()
