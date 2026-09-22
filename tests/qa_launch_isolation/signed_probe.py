#!/usr/bin/env python3
"""Prove a guarded signed QA executable refuses envless launch before data writes.

Only evidence under /tmp is written. The real daily tree is read, never changed.
A concurrently running daily app may invalidate the zero-change observation;
that is a failed/ambiguous receipt, never silently filtered out.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def snapshot(root):
    rows = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in ['.'] + dirs + files:
            path = Path(directory) if name == '.' else Path(directory) / name
            try:
                info = path.lstat()
                row = [info.st_mode, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
                if stat.S_ISLNK(info.st_mode):
                    row.append(os.readlink(path))
                # Hash every direct root file in addition to recursive metadata.
                if path.parent == root and stat.S_ISREG(info.st_mode):
                    row.append(sha256(path))
                rows[str(path.relative_to(root))] = row
            except FileNotFoundError:
                rows[str(path.relative_to(root))] = ['changed-during-snapshot']
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    assert args.app.resolve().is_relative_to(Path('/tmp').resolve()), 'temporary QA bundle required'
    assert args.evidence.resolve().is_relative_to(Path('/tmp').resolve()), 'temporary evidence required'
    assert not args.evidence.exists(), 'fresh evidence directory required'
    binary = args.app / 'Contents/MacOS/voice-flow'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
    identifier = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier',
                                         str(args.app / 'Contents/Info.plist')], text=True).strip()
    assert identifier == 'com.voiceflow.app.qa'
    marker = b'Voice Flow QA requires an explicit absolute VOICE_FLOW_CONFIG_ROOT.'
    assert marker in binary.read_bytes(), 'refusing to launch an old binary without the earliest-entry guard'
    args.evidence.mkdir(mode=0o700, parents=True)
    root = Path.home() / '.config/voice-flow'
    environment = {key: value for key, value in os.environ.items() if not key.startswith('VOICE_FLOW_')}
    report = {'app': str(args.app), 'binarySHA256': sha256(binary), 'dailyRoot': str(root),
              'startedUTC': dt.datetime.now(dt.timezone.utc).isoformat(), 'cases': []}
    before = snapshot(root)
    (args.evidence / 'before.json').write_text(json.dumps(before, sort_keys=True))
    for name, override in [('envless', {}), ('explicit-daily-root', {'VOICE_FLOW_CONFIG_ROOT': str(root)})]:
        started = dt.datetime.now(dt.timezone.utc).isoformat()
        result = subprocess.run([str(binary)], env=environment | override, capture_output=True, timeout=10)
        record = {'name': name, 'startedUTC': started, 'endedUTC': dt.datetime.now(dt.timezone.utc).isoformat(),
                  'exitCode': result.returncode, 'stdout': result.stdout.decode(errors='replace'),
                  'stderr': result.stderr.decode(errors='replace')}
        report['cases'].append(record)
    after = snapshot(root)
    (args.evidence / 'after.json').write_text(json.dumps(after, sort_keys=True))
    report['changedPaths'] = [path for path in sorted(before.keys() | after.keys()) if before.get(path) != after.get(path)]
    report['observedEntries'] = len(before)
    report['endedUTC'] = dt.datetime.now(dt.timezone.utc).isoformat()
    report['passed'] = not report['changedPaths'] and all(case['exitCode'] == 78 and not case['stdout']
                          and 'No app services were started.' in case['stderr'] for case in report['cases'])
    report['scope'] = 'Recursive inode/mode/size/mtime/ctime and symlink metadata; SHA-256 for every direct root file. No before-content claim for the earlier incident.'
    (args.evidence / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'cases'}, indent=2))
    assert report['passed'], 'guard failed or daily activity invalidated the zero-change observation; inspect evidence'


if __name__ == '__main__':
    main()
