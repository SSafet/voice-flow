#!/usr/bin/env python3
"""Signed AppKit recovery drill; all destructive writes are inside a new /tmp root."""
from __future__ import annotations
import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

from e2e_agent_harness import expect, http_json, png_channel_range, sha256, wait_for

REPO = Path(__file__).resolve().parents[1]


def temporary_path(path: Path) -> bool:
    return path.resolve().is_relative_to(Path('/tmp').resolve())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path)
    parser.add_argument('--port', type=int, default=18793)
    parser.add_argument('--app', type=Path, help='Reuse an already signed isolated QA bundle under /tmp.')
    args = parser.parse_args()
    expect(args.port == 18793, 'Damage drill requires QA port 18793.')
    root = args.root or Path(tempfile.mkdtemp(prefix='voiceflow-v1-damage-', dir='/tmp'))
    expect(temporary_path(root), 'Damage drill refuses a configuration root outside /tmp.')
    root.mkdir(parents=True, exist_ok=True)
    expect(not any(root.iterdir()), 'Damage drill requires an empty new root.')
    root = root.absolute()
    artifacts = root / 'evidence'
    artifacts.mkdir()
    for port in (18793, 18794):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(('127.0.0.1', port))
    app = args.app or root / 'Voice Flow QA.app'
    expect(temporary_path(app), 'QA bundle must be under /tmp, never /Applications.')
    if args.app is None:
        environment = os.environ.copy()
        environment['VOICE_FLOW_QA_APP_DEST'] = str(app)
        with (artifacts / 'signed-build.log').open('wb') as log:
            subprocess.run([str(REPO / 'scripts/install-agent-harness-qa.sh')], cwd=REPO,
                           env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    identifier = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier',
                                         str(app / 'Contents/Info.plist')], text=True).strip()
    expect(identifier == 'com.voiceflow.app.qa', 'The damage drill accepts only the QA bundle identifier.')
    (root / 'settings.json').write_text(json.dumps({
        'queue_enabled': False, 'workflow_watcher_enabled': False,
        'agent_base_url': 'http://127.0.0.1:9/v1', 'agent_model': 'deepseek/deepseek-v4.1-flash',
    }))
    environment = os.environ.copy()
    environment.update({
        'VOICE_FLOW_CONFIG_ROOT': str(root), 'VOICE_FLOW_QA_PORT': '18793',
        'VOICE_FLOW_QA_SYNC_PORT': '18794', 'VOICE_FLOW_QA_SYNTHETIC_INPUT_ONLY': '1',
        'VOICE_FLOW_QA_AUDIO_FIXTURE': '1', 'VOICE_FLOW_QA_HEADLESS_APPROVAL': '1',
        'VOICE_FLOW_QA_AGENT_API_KEY': 'isolated-no-provider-key',
        'VOICE_FLOW_QA_OPENAI_API_KEY': 'isolated-no-provider-key',
    })
    base = 'http://127.0.0.1:18793'
    process = None
    token = ''
    app_log = (artifacts / 'signed-app.log').open('ab')
    report = {'root': str(root), 'app': str(app), 'bundleReused': args.app is not None, 'invocationCommit': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
        'binarySHA256': sha256(app / 'Contents/MacOS/voice-flow')}

    def request(method, path, payload=None, expected=200):
        status, value = http_json(method, base + path, payload, token=token)
        expect(status == expected, f'{method} {path}: expected {expected}, got {status}: {value}')
        return value

    def state(wanted):
        value = request('GET', '/__qa/thread-store')
        return value if value.get('state') == wanted and value.get('pid') == process.pid else None

    def launch(wanted):
        nonlocal process, token
        previous = token
        process = subprocess.Popen([str(app / 'Contents/MacOS/voice-flow')], cwd=REPO,
                                   env=environment, stdout=app_log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        token_file = root / 'qa-control-token'
        wait_for('fresh QA token', lambda: token_file.exists() and len(token_file.read_text()) == 64
                 and token_file.read_text() != previous)
        token = token_file.read_text()
        expect(token_file.stat().st_mode & 0o777 == 0o600, 'QA token must have mode 0600.')
        return wait_for(f'signed app {wanted}', lambda: state(wanted), timeout=90)

    def stop():
        nonlocal process
        if process is not None and process.poll() is None:
            request('POST', '/__qa/app/terminate', {}, expected=202)
            process.wait(timeout=20)
            expect(process.returncode == 0, 'Signed app did not shut down cleanly.')
        process = None

    try:
        initial = launch('ready')
        expect(http_json('GET', base + '/__qa/thread-store')[0] == 401,
               'Thread-store QA dump must reject unauthenticated requests.')
        def fixture(name):
            return copy.deepcopy(json.loads((REPO / 'contract-fixtures/thread-protocol' / f'{name}.json').read_text())['examples'][0])
        project, thread, item = fixture('Project'), fixture('Thread'), fixture('Item')
        project.update(path=str(root), name='Recovery acceptance', gitRemote=None)
        thread.update(projectId=project['id'], title='Keep my history', runtime='opencode',
                      model='deepseek/deepseek-v4.1-flash')
        thread['workspaceRoot']['path'] = str(root)
        items = []
        for number in range(12):
            entry = copy.deepcopy(item)
            entry.update(id=f'recovery-item-{number}', threadId=thread['id'], attachments=[],
                         text=f'Preserved recovery message {number}: café, Sofia, 日本語.')
            items.append(entry)
        request('POST', '/__qa/thread-store/seed', {'project': project, 'thread': thread, 'items': items})
        backup = request('POST', '/__qa/thread-store/backup', {})
        before = request('GET', '/__qa/thread-store')
        expect(before['counts']['threads'] == 1 and before['counts']['items'] == 12, 'Seeded records are missing.')
        (artifacts / 'before.json').write_text(json.dumps(before, indent=2))
        stop()
        database = root / 'threads.sqlite'
        # The terminated app may leave a valid WAL. Consolidate it offline so
        # replay cannot legitimately heal the deliberately damaged main page.
        import sqlite3
        with sqlite3.connect(database) as checkpoint:
            checkpoint.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()
            checkpoint.execute('PRAGMA journal_mode = DELETE').fetchall()
        checkpoint.close()
        report['beforeFileSHA256'] = sha256(database)
        with database.open('r+b') as stream:
            stream.seek(4096)
            stream.write(b'\x7f' * 4096)
            stream.flush()
            os.fsync(stream.fileno())
        damaged_hash = sha256(database)
        report['damagedFileSHA256'] = damaged_hash
        expect(damaged_hash != report['beforeFileSHA256'], 'Damage injection did not change the file.')
        # A blocked launch/termination must not flush an uninitialized legacy UI.
        legacy = root / 'pushes.json'
        legacy.write_text('[{"recovery_guard":"keep this existing history"}]')
        legacy_hash = sha256(legacy)
        blocked = launch('blocked')
        expect(blocked['pendingRecovery'] and not blocked['sharedPoolAvailable']
               and not blocked['normalStartupComplete'], 'Recovery did not gate canonical access and startup.')
        expect(http_json('GET', base + '/__qa/thread-store')[0] == 401, 'Blocked recovery must remain authenticated.')
        request('POST', '/__qa/workspace', {}, expected=503)
        request('POST', '/__qa/thread-store/seed', {}, expected=503)
        shot = Path(request('POST', '/__qa/thread-store/snapshot', {})['path'])
        expect(png_channel_range(shot) > 20, 'Recovery window snapshot is blank.')
        shutil.copyfile(shot, artifacts / 'recovery-window.png')
        (artifacts / 'blocked.json').write_text(json.dumps(blocked, indent=2))
        preserved = [entry for entry in blocked['damagedFiles'] if entry['sha256'] == damaged_hash]
        expect(len(preserved) == 1, 'The exact damaged main file was not preserved.')
        stop()
        expect(sha256(legacy) == legacy_hash, 'Blocked shutdown overwrote legacy history.')
        restarted = launch('blocked')
        expect(restarted['pendingRecovery'] and not database.exists(), 'Restart silently created empty history.')
        expect(sha256(Path(preserved[0]['path'])) == damaged_hash, 'Restart changed preserved damage bytes.')
        request('POST', '/__qa/thread-store/recover', {'action': 'restore'})
        restored = wait_for('verified restoration and normal startup', lambda: state('ready'), timeout=90)
        for key in ('installationID', 'counts', 'recordSHA256'):
            expect(restored[key] == before[key], f'Restored {key} differs from the pre-damage history.')
        expect(not restored['pendingRecovery'] and restored['sharedPoolAvailable'], 'Successful restore did not clear the gate.')
        expect(sha256(Path(preserved[0]['path'])) == damaged_hash, 'Restoration altered the preserved damaged file.')
        (artifacts / 'after.json').write_text(json.dumps(restored, indent=2))
        stop()
        again = launch('ready')
        expect(again['recordSHA256'] == before['recordSHA256'], 'History changed on restart after restoration.')
        stop()
        report.update(result='passed', backup=backup['path'], preserved=preserved[0]['path'],
                      checks=['authenticated QA-only control', '1 project / 1 thread / 12 items',
                              'native recovery window rendered', 'blocked canonical reads and normal controls',
                              'blocked restart and legacy history preservation', 'visible restore button path',
                              'restored record hashes and installation identity', 'damaged bytes kept',
                              'successful post-restore restart'])
        (artifacts / 'result.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        if process is not None and process.poll() is None:
            # Even after a failed assertion, let the app tear down its backend
            # and persist through the normal authenticated termination path.
            try:
                http_json('POST', base + '/__qa/app/terminate', {}, token=token)
                process.wait(timeout=20)
            except Exception:
                import signal
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=10)
        app_log.close()


if __name__ == '__main__':
    main()
