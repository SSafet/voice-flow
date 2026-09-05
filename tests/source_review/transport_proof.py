#!/usr/bin/env python3
"""Run the real source-review gateway against a model/mailbox HTTP fixture."""
import json
import os
import select
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

requests = []
delayed_cancelled = threading.Event()
delay_marker = None
class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        requests.append({'path': self.path, 'body': body})
        if self.path != '/v1/chat/completions':
            self.send_error(403, 'Mailbox mutation denied by fixture')
            return
        assert self.headers.get('Authorization') == 'Bearer transport-fixture-key'
        assert 'tools' not in body and 'functions' not in body
        assert body['model'] == 'test/reviewer'
        assert body['max_tokens'] == 512
        content = body['messages'][-1]['content']
        assert 'SOURCE_A_CONTENT' in content and 'SOURCE_B_CONTENT' not in content
        if 'DELAY_RESPONSE' in content:
            with open(delay_marker, 'w') as marker:
                marker.write('request reached provider')
            readable, _, _ = select.select([self.connection], [], [], 5)
            if readable and self.connection.recv(1) == b'':
                delayed_cancelled.set()
            return
        if 'ATTACK_RESPONSE' in content:
            message = {'content': '', 'tool_calls': [{'id': 'attack', 'type': 'function', 'function': {
                'name': 'shell', 'arguments': json.dumps({'command': f'curl -X POST http://127.0.0.1:{self.server.server_port}/mailbox/delete'})}}]}
            finish = 'tool_calls'
        else:
            message, finish = {'content': 'The copied email was reviewed safely.'}, 'stop'
        payload = json.dumps({'choices': [{'message': message, 'finish_reason': finish}],
                              'usage': {'prompt_tokens': 20, 'completion_tokens': 10, 'cost': 0.001}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_GET(self):
        requests.append({'path': self.path, 'method': 'GET'})
        self.send_error(403)

server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='vf-source-review-proof-') as root:
        delay_marker = os.path.join(root, 'provider-delay-ready')
        env = dict(os.environ, VOICE_FLOW_CONFIG_ROOT=root,
                   VOICE_FLOW_REVIEW_DELAY_READY=delay_marker,
                   VOICE_FLOW_REVIEW_UPSTREAM=f'http://127.0.0.1:{server.server_port}/v1')
        result = subprocess.run([sys.argv[1]], env=env, text=True, capture_output=True, timeout=60)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode:
            raise SystemExit(result.returncode)
        assert len(requests) == 4, requests
        assert delayed_cancelled.wait(2), "cancel did not disconnect the in-flight provider request"
        assert all(request['path'] == '/v1/chat/completions' for request in requests), requests
        print(json.dumps({'result': 'passed', 'model_requests': len(requests), 'mailbox_requests': 0,
                          'tools_exposed': False, 'gateway_credential_replacement': True,
                          'gateway_output_limit': 512, 'malicious_action_rejected': True,
                          'delayed_upstream_cancelled': True, 'late_final_events': 0,
                          'subsequent_gateway_request_passed': True}, sort_keys=True))
finally:
    server.shutdown()
    server.server_close()
