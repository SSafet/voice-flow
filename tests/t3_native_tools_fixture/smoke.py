"""Console-only guard/HTTP smoke. Bootstrap stays in this process's private pipe."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import urllib.request

binary = Path(sys.argv[1]).resolve()
environment = os.environ.copy()
environment.pop('VOICE_FLOW_CONFIG_ROOT', None)
refused = subprocess.run([str(binary)], env=environment, capture_output=True, timeout=5)
assert refused.returncode == 78 and refused.stdout == b'', 'envless fixture must refuse before bootstrap'
assert b'isolated configuration root' in refused.stderr
assert b'credential' not in refused.stderr
with tempfile.TemporaryDirectory(prefix='vf-native-tools-cross-smoke-') as work:
    environment['VOICE_FLOW_CONFIG_ROOT'] = str(Path(work) / 'config')
    child = subprocess.Popen([str(binary)], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def read_line():
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            assert selector.select(8), 'fixture pipe timeout'
        line = child.stdout.readline()
        assert line, 'fixture exited before response'
        return json.loads(line)
    def control(op):
        child.stdin.write((json.dumps({'op':op})+'\n').encode()); child.stdin.flush()
        value = read_line()
        assert value['op'] == op, 'fixture control correlation'
        return value
    try:
        bootstrap = read_line()
        assert bootstrap['version'] == 1
        authority = bootstrap['nativeAuthority']
        assert authority['origin'].startswith('http://127.0.0.1:') and len(authority['credential']) == 43
        def request(method, params, ident):
            body = json.dumps({'jsonrpc':'2.0','id':ident,'method':method,'params':params}).encode()
            req = urllib.request.Request(authority['origin']+'/v1/tools/mcp', body, headers={
                'Content-Type':'application/json','Accept':'application/json, text/event-stream',
                'MCP-Protocol-Version':'2025-11-25','Authorization':'Bearer '+authority['credential']})
            with urllib.request.urlopen(req, timeout=8) as reply:
                return json.load(reply)
        initialized = request('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'isolated-smoke','version':'1'}},1)
        assert initialized['result']['serverInfo']['name'] == 'voiceflow-owned-native'
        listed = request('tools/list',{},2)['result']
        assert len(listed['tools']) == 1 and listed['tools'][0]['name'] == 'voiceflow_computer'
        manifest = listed['_meta']['ai.atika/nativeManifest']
        assert manifest['binding']['identityGeneration'] == bootstrap['binding']['identityGeneration']
        assert manifest['binding']['environment']['launchGeneration'] == bootstrap['launchGeneration']
        assert control('hold')['ok'] and control('stats')['effects'] == 0
        assert control('release')['ok']
        assert control('stop')['ok']
        child.wait(timeout=8)
        assert child.returncode == 0 and child.stdout.read() == b'', 'clean stop without bootstrap repetition'
        assert authority['credential'].encode() not in child.stderr.read(), 'credential leaked to stderr'
    finally:
        if child.poll() is None:
            try: child.stdin.close(); child.wait(timeout=8)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
print('PASS envless refusal, real Swift broker/SDK initialize+manifest, private control and clean stop')
