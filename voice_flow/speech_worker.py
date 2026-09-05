"""Two bounded API lanes: final speech never waits for a speculative preview."""
from collections import deque
import threading
import time


class SpeechWorker:
    def __init__(self, handler_factory, emit):
        self._condition = threading.Condition()
        self._finals = deque()
        self._preview = None
        self._closed_runs = deque(maxlen=64)
        self._final_active = False
        self._closing = False
        self._emit = emit
        self._threads = [threading.Thread(target=self._work, args=(partial, handler_factory()), daemon=True)
                         for partial in (False, True)]
        for thread in self._threads:
            thread.start()

    def submit(self, command):
        partial = command.get('cmd') == 'partial_transcribe'
        with self._condition:
            if partial:
                if command.get('run_id') in self._closed_runs:
                    return
                self._preview = (command, time.monotonic())
            else:
                run = command.get('request_id')
                if run is not None:
                    self._closed_runs.append(run)
                if self._preview and self._preview[0].get('run_id') == run:
                    self._preview = None
                if len(self._finals) >= 8:
                    self._emit({'event': 'error', 'request_id': run,
                                'message': 'Transcription queue is full. Your saved audio can be retried.'})
                    return
                self._finals.append((command, time.monotonic()))
            self._condition.notify_all()

    def close(self):
        with self._condition:
            self._closing = True
            self._condition.notify_all()
        for thread in self._threads:
            thread.join()

    def _work(self, partial, handler):
        while True:
            with self._condition:
                while True:
                    available = (self._preview is not None and not self._finals and not self._final_active
                                 if partial else bool(self._finals))
                    if available:
                        break
                    if self._closing and (not partial or self._preview is None):
                        return
                    self._condition.wait()
                if partial:
                    command, received = self._preview
                    self._preview = None
                else:
                    command, received = self._finals.popleft()
                    self._final_active = True
            started = time.monotonic()

            def emit(event):
                with self._condition:
                    if partial and command.get('run_id') in self._closed_runs:
                        return
                    self._emit(event)
            try:
                handler(command, emit)
            except Exception as exc:
                emit({'event': 'error', 'request_id': command.get('request_id'), 'message': str(exc)})
            finally:
                # Timings contain no text, audio, vocabulary or credentials.
                self._emit({'event': 'speech_metrics', 'lane': 'preview' if partial else 'final',
                            'request_id': command.get('request_id'),
                            'queue_ms': round((started - received) * 1000, 2),
                            'service_ms': round((time.monotonic() - started) * 1000, 2)})
                with self._condition:
                    if not partial:
                        self._final_active = False
                    self._condition.notify_all()
