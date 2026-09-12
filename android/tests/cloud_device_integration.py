#!/usr/bin/env python3
"""Real Android SQLite/Keystore + actual Atika auth/sync routers; synthetic only.
Start tests/cloud_sync/server-fixture.mts and pass its fixture JSON. This driver
only installs/clears the explicit .syncqa application on the selected emulator.
"""
import argparse, datetime, hashlib, json, os, pathlib, re, shlex, subprocess, urllib.request, uuid

parser = argparse.ArgumentParser()
parser.add_argument('--fixture', required=True)
parser.add_argument('--serial', default='emulator-5554')
parser.add_argument('--adb', default=os.path.expanduser('~/Library/Android/sdk/platform-tools/adb'))
parser.add_argument('--resume-import', action='store_true')
parser.add_argument('--receipt', default=str(pathlib.Path(__file__).with_name('cloud-device-receipt.json')))
args = parser.parse_args()
fixture = json.loads(pathlib.Path(args.fixture).read_text()); origin = fixture['origin']
assert re.fullmatch(r'http://127\.0\.0\.1:\d+', origin)
assert args.serial.startswith('emulator-')
app = 'com.voiceflow.mobile.syncqa'; checks = []
def rid(value): return run_prefix + '-' + value
run_prefix = uuid.uuid4().hex[:8]
def adb(*words):
    return subprocess.check_output([args.adb, '-s', args.serial, *words], text=True, timeout=90)
def qa(action, **values):
    command = ['am', 'instrument', '-w', '-e', 'action', 'cloud-' + action]
    for key, value in values.items(): command += ['-e', key, str(value)]
    command += [app + '/com.voiceflow.mobile.SyncQADriver']
    output = adb('shell', shlex.join(command))
    match = re.search(r'CLOUD_JSON:(\{[^\n]+\})', output)
    assert 'FAIL:' not in output and match, output
    return json.loads(match[1])
def http(path, data=None, token=None):
    request = urllib.request.Request(origin + path, data=json.dumps(data).encode() if data is not None else None,
        headers={'Content-Type': 'application/json', 'X-Forwarded-For': '198.51.100.42', **({'Authorization': 'Bearer ' + token} if token else {})})
    with urllib.request.urlopen(request, timeout=20) as response: return json.load(response)
def login(email):
    challenge = http('/api/v1/auth/native/login/start', {'email': email})['challenge']
    code = http('/fixture/code?email=' + email)['code']
    return http('/api/v1/auth/native/login/complete', {**{key: challenge[key] for key in ('state', 'email')}, 'code': code, 'device': {'kind': 'desktop', 'label': 'Synthetic conflict peer'}})
def remote_put(token, rid, text, base='0'):
    return http('/api/v1/sync/mutations', {'protocolVersion': 1, 'operations': [{'operationId': str(uuid.uuid4()), 'collection': 'dictations', 'recordId': rid, 'baseVersion': base, 'schemaVersion': 1, 'op': 'put', 'payload': {'text': text, 'destination': 'pasted'}}]}, token)['results'][0]
def drain(rid=None):
    for _ in range(35):
        state = qa('sync', **({'id': rid} if rid else {}))
        if not state['more']: return state
    raise AssertionError('Bounded sync jobs did not drain: ' + str(state))
def check(name, assertion):
    assert assertion, name
    checks.append(name); print('PASS ' + name, flush=True)

port = origin.rsplit(':', 1)[1]
adb('reverse', 'tcp:' + port, 'tcp:' + port)
if not args.resume_import:
    adb('shell', 'pm', 'clear', app)
    qa('seed-legacy', count=1200)
    state = qa('login', origin=origin, email=fixture['emails'][0])
    check('1200 legacy rows imported beyond UI caps', state['records'] == 1203 and state['pending'] == 1203 and state['visibleCount'] == 500)
else:
    state = qa('state')
    check('1200 legacy rows retained beyond UI caps', state['records'] >= 1203 and state['visibleCount'] == 500)
state = qa('state', id='legacy-1199')
check('large SQLite state reopens across process death', state['row']['payload']['text'].startswith('Synthetic retained dictation 1199'))
state = drain()
check('all imported rows delivered through bounded pagination', state['pending'] == 0 and state['records'] >= 1203)
peer = login(fixture['emails'][0]); token = peer['accessToken']
state = qa('capture', id=rid('offline-a'), text='Captured through production Store')
check('capture transaction persists before delivery', len(state['row']['pending']) == 1)
operation = state['row']['pending'][0]['operationId']
http('/fixture/drop-next', {})
state = qa('sync', id=rid('offline-a'))
check('committed response loss retains exact operation', state['row']['pending'][0]['operationId'] == operation)
state = drain(rid('offline-a'))
check('idempotent retry clears only acknowledged operation', not state['row']['pending'] and state['row']['remote']['version'] == '1')
qa('edit', id=rid('offline-a'), text='Phone offline edit')
result = remote_put(token, rid('offline-a'), 'Peer edit', '1')
check('peer commits from same base', result['status'] == 'applied')
state = qa('sync', id=rid('offline-a'))
check('concurrent edits preserve device value and conflict', state['conflicts'] == 1 and state['row']['payload']['text'] == 'Phone offline edit')
qa('edit', id=rid('unrelated'), text='Independent row')
state = drain(rid('unrelated'))
check('one conflict does not block another record', state['row']['remote']['version'] == '1' and state['conflicts'] == 1)
qa('resolve', id=rid('offline-a'), choice='THIS_DEVICE')
state = drain(rid('offline-a'))
check('explicit fresh-base resolution clears chosen conflict', state['conflicts'] == 0 and state['row']['remote']['payload']['text'] == 'Phone offline edit')
qa('delete', id=rid('offline-a')); state = drain(rid('offline-a'))
check('tombstone retains last live payload', state['row']['payload'] is None and state['row']['lastLivePayload']['text'] == 'Phone offline edit')
qa('restore', id=rid('offline-a')); state = drain(rid('offline-a'))
check('explicit restore works across process restart', state['row']['remote']['payload']['text'] == 'Phone offline edit')
qa('select', include='preferences')
state = qa('edit', id=rid('excluded'), text='Kept on this phone')
state = qa('sync', id=rid('excluded'))
check('excluded uploads retain immutable queue', len(state['row']['pending']) == 1 and not state['more'])
qa('select', include='dictations,threads,messages,preferences'); state = drain(rid('excluded'))
check('re-enabled uploads deliver retained edits', len(state['row']['pending']) == 0)
qa('edit', id=rid('offline-a'), text='Queued before redirect')
http('/fixture/redirect-next', {})
state = qa('sync', id=rid('offline-a'))
check('HTTP redirects are not followed and edits remain queued', len(state['row']['pending']) == 1 and http('/fixture/status')['leakedRequests'] == 0)
state = qa('logout', id=rid('offline-a'))
check('sign-out removes credentials while retaining data', not state['configured'] and state['records'] > 1200 and len(state['row']['pending']) == 1)
state = qa('login', origin=origin, email=fixture['emails'][1])
check('account B cannot see or republish account A', state['records'] == 0 and state['pending'] == 0 and state['visibleCount'] == 0)
qa('edit', id=rid('owner-b-only'), text='Account B private record'); drain()
qa('logout')
state = qa('login', origin=origin, email=fixture['emails'][0], id=rid('offline-a'))
check('account A queue and settings survive account switching', len(state['row']['pending']) == 1 and 'dictations' in state['selected'])
state = drain(rid('offline-a'))
http('/fixture/revoke', {'deviceId': state['deviceId']})
state = qa('sync', id=rid('offline-a'))
check('device revocation requests sign-in without losing records', not state['configured'] and state['records'] > 1200)
state = qa('login', origin=origin, email=fixture['emails'][0]); drain()
receipt = {'passed': True, 'date': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'checks': checks,
    'platform': 'Android API 34 arm64 emulator', 'application': app, 'database': 'real Android SQLite', 'credentials': 'real Android Keystore encryption',
    'server': 'real Atika native-auth and sync routers on isolated synthetic PostgreSQL fixture', 'realUserData': False, 'providerCalls': 0}
source = pathlib.Path(__file__).resolve().parents[1]
hash_input = b''.join(str(path.relative_to(source)).encode() + b'\0' + path.read_bytes() + b'\0' for path in sorted((source / 'app' / 'src').rglob('*')) if path.is_file())
receipt['androidSourceSHA256'] = hashlib.sha256(hash_input).hexdigest()
pathlib.Path(args.receipt).write_text(json.dumps(receipt, indent=2) + '\n')
print('Receipt: ' + args.receipt)
