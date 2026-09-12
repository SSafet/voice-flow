#!/usr/bin/env python3
"""Rebuild the pinned, architecture-independent OpenCode tool-only asset.
No npm lifecycle scripts execute. Archive bytes must match the reviewed pin.
"""
import base64
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1] / 'runtime' / 'opencode'
manifest = json.loads((ROOT / 'tool-sdk.json').read_text())
with tempfile.TemporaryDirectory(prefix='voice-flow-tool-sdk-') as temporary:
    stage = Path(temporary) / 'ToolSDK'
    for package in manifest['packages']:
        url = package['resolved']
        assert url.startswith('https://registry.npmjs.org/')
        with urllib.request.urlopen(url, timeout=30) as response:
            payload = response.read(20 * 1024 * 1024)
        algorithm, expected = package['integrity'].split('-', 1)
        assert algorithm == 'sha512'
        assert base64.b64encode(hashlib.sha512(payload).digest()).decode() == expected
        destination = stage / 'node_modules' / package['name']
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
            for member in archive.getmembers():
                parts = PurePosixPath(member.name).parts
                assert parts and parts[0] == 'package' and '..' not in parts
                assert member.isdir() or member.isfile()
                output = destination.joinpath(*parts[1:])
                if member.isdir():
                    output.mkdir(parents=True, exist_ok=True)
                else:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source:
                        output.write_bytes(source.read())
        assert json.loads((destination / 'package.json').read_text())['version'] == package['version']
    shutil.copyfile(ROOT / 'OPENCODE-LICENSE', stage / 'OPENCODE-LICENSE')
    (stage / 'manifest.json').write_text(json.dumps({k: v for k, v in manifest.items() if k != 'archiveSHA256'}, indent=2) + '\n')
    result = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', fileobj=result, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            for path in [stage, *sorted(stage.rglob('*'))]:
                name = 'ToolSDK' + ('/' + str(path.relative_to(stage)) if path != stage else '')
                member = archive.gettarinfo(str(path), arcname=name)
                member.uid = member.gid = member.mtime = 0
                member.uname = member.gname = ''
                member.mode = 0o755 if member.isdir() else 0o644
                if member.isfile():
                    with path.open('rb') as source:
                        archive.addfile(member, source)
                else:
                    archive.addfile(member)
    data = result.getvalue()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == manifest['archiveSHA256'], f'rebuild differs from pin: {digest}'
    (ROOT / 'tool-sdk.tar.gz').write_bytes(data)
    print(f'Pinned tool SDK reproduced: {len(data)} bytes, SHA-256 {digest}')
