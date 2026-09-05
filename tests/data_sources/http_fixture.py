#!/usr/bin/env python3
"""A real loopback HTTP origin for Sources contract tests; writes its port to argv[1]."""
import http.server
import pathlib
import sys
import time

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/error':
            self.send_error(503, 'Fixture unavailable')
            return
        if self.path == '/slow':
            time.sleep(0.8)
        payload = b'<html><head><script>hidden()</script></head><body><h1>Live fixture</h1><p>Collected over HTTP.</p></body></html>'
        if self.path == '/large':
            payload = b'x' * 2_000_001
        if self.path == '/changed':
            payload = b'<p>Changed website evidence</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
