#!/usr/bin/env python3
"""Exchange real Swift SQLite and Android SQLite records through a fresh fixture.
Run after cloud_device_integration.py, without concurrent fault injection.
The Swift helper is compiled from the current product sources by this script.
"""
import argparse, datetime, hashlib, json, os, pathlib, re, shlex, subprocess, tempfile, uuid
p = argparse.ArgumentParser()
p.add_argument('--fixture', required=True)
p.add_argument('--serial', default='emulator-5554')
p.add_argument('--adb', default=os.path.expanduser('~/Library/Android/sdk/platform-tools/adb'))
p.add_argument('--receipt', default=str(pathlib.Path(__file__).with_name('cloud-cross-device-receipt.json')))
a = p.parse_args(); root = pathlib.Path(__file__).resolve().parents[2]
f = json.loads(pathlib.Path(a.fixture).read_text()); assert re.fullmatch(r'http://127\.0\.0\.1:\d+', f['origin']); assert a.serial.startswith('emulator-')
app = 'com.voiceflow.mobile.syncqa'
def adb(*args): return subprocess.check_output([a.adb, '-s', a.serial, *args], text=True, timeout=90)
def qa(action, **values):
    command = ['am', 'instrument', '-w', '-e', 'action', 'cloud-' + action]
    for key,value in values.items(): command += ['-e', key, str(value)]
    output = adb('shell', shlex.join(command + [app + '/com.voiceflow.mobile.SyncQADriver']))
    match = re.search(r'CLOUD_JSON:(\{[^\n]+\})', output); assert 'FAIL:' not in output and match, output
    return json.loads(match[1])
def pull(rid):
    for _ in range(35):
        state = qa('sync', id=rid)
        if not state['more']: return state
    raise AssertionError('Cursor did not catch up')
port = f['origin'].rsplit(':',1)[1]; adb('reverse', 'tcp:' + port, 'tcp:' + port)
state = qa('state')
if state.get('email') != f['emails'][0] or not state.get('configured'):
    state = qa('login', origin=f['origin'], email=f['emails'][0])
assert state['email'] == f['emails'][0]
with tempfile.TemporaryDirectory(prefix='vf-android-cross-') as temporary:
    temporary = pathlib.Path(temporary); helper = temporary / 'swift-client'; database = temporary / 'swift.sqlite'
    sources = [root / name for name in ['swift/CloudSyncModels.swift','swift/CloudSyncStore.swift','swift/CloudSyncHTTP.swift','android/tests/SwiftCloudFixtureClient.swift']]
    subprocess.run(['swiftc','-parse-as-library', *map(str,sources), '-framework','Security','-lsqlite3','-o',str(helper)],check=True,timeout=90)
    prefix = uuid.uuid4().hex[:8]; swift_id = prefix + '-swift-to-android'; android_id = prefix + '-android-to-swift'
    def swift(*args): return json.loads(subprocess.check_output([str(helper), a.fixture, str(database), *args],text=True,timeout=90))
    written = swift('put', swift_id, 'Synthetic message from final Swift SQLite')
    android = pull(swift_id)['row']
    assert written['pending'] == 0 and android['pending'] == [] and android['remote']['payload']['text'] == written['text']
    print('PASS Swift SQLite → Atika → Android SQLite',flush=True)
    qa('edit',id=android_id,text='Synthetic message from final Android SQLite')
    android = pull(android_id)['row']; read = swift('read',android_id)
    assert android['pending'] == [] and read['pending'] == 0 and read['text'] == android['remote']['payload']['text']
    print('PASS Android SQLite → Atika → Swift SQLite',flush=True)
    receipt = {'passed':True,'date':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checks':['Swift SQLite outbox and exact receipt reaches Android SQLite','Android SQLite outbox and exact receipt reaches Swift SQLite'],
        'swiftToAndroid':written,'androidToSwift':read,'providerCalls':0,'realUserData':False,
        'swiftSourceSHA256':hashlib.sha256(b''.join(str(path.relative_to(root)).encode()+b'\0'+path.read_bytes()+b'\0' for path in sources)).hexdigest()}
    android_root = root / 'android'
    receipt['androidSourceSHA256'] = hashlib.sha256(b''.join(str(path.relative_to(android_root)).encode()+b'\0'+path.read_bytes()+b'\0' for path in sorted((android_root/'app'/'src').rglob('*')) if path.is_file())).hexdigest()
    pathlib.Path(a.receipt).write_text(json.dumps(receipt,indent=2)+'\n')
print('Receipt: '+a.receipt)
