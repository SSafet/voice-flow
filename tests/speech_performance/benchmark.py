"""Before/after proof using the actual backend protocol and TTS controller.
Run with --root pointing to a baseline checkout or current source.
Provider latency is deliberately controlled; these are NOT cloud percentiles.
"""
import argparse, base64, http.server, json, os, pathlib, queue, statistics, subprocess, sys, tempfile, threading, time

HERE = pathlib.Path(__file__).resolve().parent

def stt(root):
    code = '''
import time
from voice_flow import backend
class Fake:
    def transcribe(self, audio, **kwargs):
        time.sleep(.4 if kwargs.get("max_attempts") == 1 else .12)
        return "The complete final transcript."
backend.OpenAITranscriber = Fake
backend.main()
'''
    proc = subprocess.Popen([sys.executable, '-u', '-c', code], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    events = queue.Queue()
    def read():
        for line in proc.stdout:
            events.put((time.monotonic(), json.loads(line)))
    threading.Thread(target=read, daemon=True).start()
    assert events.get(timeout=10)[1]['event'] == 'ready'
    audio = base64.b64encode(b'\x01\x00' * 2000).decode()
    def send(cmd):
        proc.stdin.write(json.dumps(dict(audio_b64=audio, openai_api_key='fixture', provider='openai', **cmd))+'\n'); proc.stdin.flush()
    send(dict(cmd='partial_transcribe', run_id='r', request_id=1))
    time.sleep(.06)
    for i in range(2, 6):
        send(dict(cmd='partial_transcribe', run_id='r', request_id=i))
    release = time.monotonic()
    send(dict(cmd='transcribe', request_id='r'))
    partials = 0
    while True:
        at, event = events.get(timeout=10)
        if event['event'] == 'partial_result': partials += 1
        if event['event'] == 'result':
            assert event['request_id'] == 'r' and event['cleaned'] == 'The complete final transcript.'
            elapsed = (at-release)*1000
            break
    proc.stdin.close(); proc.wait(timeout=10)
    assert proc.returncode == 0, proc.stderr.read()
    return dict(release_to_final_ms=elapsed, previews_before_final=partials)

class PCM(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        scenario=body.get('input','').strip().splitlines()[0]
        if scenario=='http_error':
            self.send_response(503);self.end_headers();self.wfile.write(b'{"error":{"message":"fixture outage"}}');return
        size=2401 if scenario=='invalid' else 2400 if scenario in ('short','fragmented') else 96000
        self.send_response(200);self.send_header('Content-Type','application/octet-stream');self.send_header('Content-Length',str(size));self.end_headers()
        try:
            time.sleep(.10)
            if scenario in ('short','invalid'):
                self.wfile.write(bytes(size));self.wfile.flush()
            elif scenario=='fragmented':
                for count in [1, 799, 1001, 599]:
                    self.wfile.write(bytes(count));self.wfile.flush();time.sleep(.01)
            else:
                for _ in range(50):
                    self.wfile.write(bytes(1920));self.wfile.flush();time.sleep(.04)
        except (BrokenPipeError, ConnectionResetError):pass
    def log_message(self, *args): pass

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--root',type=pathlib.Path,default=HERE.parents[1]); ap.add_argument('--output',type=pathlib.Path,required=True); ap.add_argument('--runs',type=int,default=5); ap.add_argument('--skip-tts',action='store_true'); ap.add_argument('--regressions',action='store_true'); args=ap.parse_args()
    result={'kind':'controlled actual pipeline benchmark','stt':[stt(args.root) for _ in range(args.runs)]}
    if not args.skip_tts:
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),PCM); threading.Thread(target=server.serve_forever,daemon=True).start()
        with tempfile.TemporaryDirectory(prefix='vf-speech-proof-') as tmp:
            binary=pathlib.Path(tmp)/'probe'
            sources=sorted(str(p) for p in (args.root/'swift').glob('*.swift') if p.name!='main.swift')
            cmd=['swiftc','-D','VOICE_FLOW_QA',*sources,str(HERE/'main.swift'),'-O','-whole-module-optimization','-suppress-warnings','-o',str(binary)]
            for framework in ['Cocoa','AVFoundation','CoreGraphics','ApplicationServices','Accelerate','Security','ScreenCaptureKit']:
                cmd+=['-framework',framework]
            subprocess.run(cmd,check=True)
            env=dict(os.environ,VOICE_FLOW_CONFIG_ROOT=tmp,VOICE_FLOW_QA_TTS_URL=f'http://127.0.0.1:{server.server_port}/speech')
            result['tts']=[]
            for _ in range(args.runs):
                run=subprocess.run([str(binary)],env=env,text=True,capture_output=True,check=True)
                result['tts'].append(json.loads(run.stdout.strip().splitlines()[-1]))
            if args.regressions:
                result['tts_regressions']=[]
                for scenario in ['short','fragmented','invalid','http_error','pause','cancel','replace']:
                    run=subprocess.run([str(binary)],env=dict(env,VF_SPEECH_CASE=scenario),text=True,capture_output=True)
                    row=json.loads(run.stdout.strip().splitlines()[-1]);result['tts_regressions'].append(row)
                    assert run.returncode==0, row
        server.shutdown(); server.server_close()
    result['stt_median_ms']=statistics.median(x['release_to_final_ms'] for x in result['stt'])
    if result.get('tts'): result['tts_median_ms']=statistics.median(x['first_playing_ms'] for x in result['tts'])
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
