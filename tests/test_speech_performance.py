import io
import json
import threading
import unittest
from unittest import mock

import numpy as np

from voice_flow.openai_transcriber import OpenAITranscriber, _read_transcript_stream
from voice_flow.speech_worker import SpeechWorker


def sse(*events):
    return io.BytesIO(''.join('data: '+json.dumps(e, ensure_ascii=False)+'\r\n\r\n' for e in events).encode())


class StreamingTests(unittest.TestCase):
    def test_unicode_deltas_are_replaceable_and_done_is_authoritative(self):
        seen=[]
        result=_read_transcript_stream(sse({'type':'transcript.text.delta','delta':'Здравей'},
            {'type':'transcript.text.delta','delta':' FLORA'},
            {'type':'transcript.text.done','text':'Здравей, FLORA!'}),seen.append)
        self.assertEqual(seen,['Здравей','Здравей FLORA'])
        self.assertEqual(result,{'text':'Здравей, FLORA!'})

    def test_disconnect_resets_preview_retries_same_audio_and_commits_once(self):
        seen=[]
        with mock.patch('urllib.request.urlopen',side_effect=[
            sse({'type':'transcript.text.delta','delta':'old'}),
            sse({'type':'transcript.text.delta','delta':'new'}, {'type':'transcript.text.done','text':'new final'})]) as request, mock.patch('time.sleep'):
            text=OpenAITranscriber().transcribe(np.ones(3200,dtype=np.float32),'fixture',on_delta=seen.append)
        self.assertEqual(text,'new final');self.assertEqual(seen,['old','','new'])
        self.assertEqual(request.call_args_list[0].args[0].data,request.call_args_list[1].args[0].data)
        self.assertIn(b'"stream"',request.call_args.args[0].data)

    def test_incomplete_stream_never_commits_partial_text(self):
        with mock.patch('urllib.request.urlopen',side_effect=lambda *a,**k:sse({'type':'transcript.text.delta','delta':'not final'})), mock.patch('time.sleep'):
            with self.assertRaisesRegex(RuntimeError,'after 3 attempt'):
                OpenAITranscriber().transcribe(np.ones(3200,dtype=np.float32),'fixture',on_delta=lambda x:None)

    def test_prompt_echo_still_cannot_be_final_text(self):
        with mock.patch('urllib.request.urlopen',return_value=sse({'type':'transcript.text.done','text':'Correct spellings: FLORA, Codex'})):
            self.assertEqual(OpenAITranscriber().transcribe(np.ones(3200,dtype=np.float32),'fixture',on_delta=lambda x:None),'')


class WorkerTests(unittest.TestCase):
    def test_final_finishes_while_preview_is_blocked_and_stale_text_is_suppressed(self):
        entered=threading.Event();release=threading.Event();final=threading.Event();events=[]
        def handler(cmd,emit):
            if cmd['cmd']=='partial_transcribe': entered.set();release.wait(3)
            emit({'event':'partial_result' if cmd['cmd']=='partial_transcribe' else 'result','request_id':cmd['request_id']})
        def emit(event):
            events.append(event)
            if event['event']=='result':final.set()
        worker=SpeechWorker(lambda:handler,emit)
        try:
            worker.submit({'cmd':'partial_transcribe','run_id':'r','request_id':1})
            self.assertTrue(entered.wait(1))
            for i in range(2,100):worker.submit({'cmd':'partial_transcribe','run_id':'r','request_id':i})
            worker.submit({'cmd':'transcribe','request_id':'r'})
            self.assertTrue(final.wait(1),'final must not wait for the blocked preview')
        finally:release.set();worker.close()
        self.assertFalse(any(e['event']=='partial_result' for e in events))
        self.assertEqual(len([e for e in events if e.get('lane')=='preview']),1)

    def test_only_latest_pending_preview_is_requested(self):
        entered=threading.Event();release=threading.Event();calls=[]
        def handler(cmd,emit):
            calls.append(cmd['request_id'])
            if cmd['request_id']==1:entered.set();release.wait(3)
        worker=SpeechWorker(lambda:handler,lambda e:None)
        try:
            worker.submit({'cmd':'partial_transcribe','run_id':'r','request_id':1});self.assertTrue(entered.wait(1))
            for i in range(2,100):worker.submit({'cmd':'partial_transcribe','run_id':'r','request_id':i})
        finally:release.set();worker.close()
        self.assertEqual(calls,[1,99])

    def test_queue_limit_fails_visibly_and_preserves_accepted_finals(self):
        entered=threading.Event();release=threading.Event();events=[]
        def handler(cmd,emit):
            if cmd['request_id']=='0':entered.set();release.wait(3)
            emit({'event':'result','request_id':cmd['request_id']})
        worker=SpeechWorker(lambda:handler,events.append)
        try:
            worker.submit({'cmd':'transcribe','request_id':'0'});self.assertTrue(entered.wait(1))
            for i in range(1,11):worker.submit({'cmd':'transcribe','request_id':str(i)})
        finally:release.set();worker.close()
        self.assertEqual([e['request_id'] for e in events if e['event']=='result'],list(map(str,range(9))))
        self.assertEqual([e['request_id'] for e in events if e['event']=='error'],['9','10'])

if __name__=='__main__':unittest.main()
