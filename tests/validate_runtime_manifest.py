#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tarfile

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=pathlib.Path)
args = parser.parse_args()
manifest = json.loads((root / "runtime/opencode/versions.json").read_text())
sdk_root = root / "runtime/opencode"
sdk = json.loads((sdk_root / "tool-sdk.json").read_text())
sdk_archive = sdk_root / "tool-sdk.tar.gz"
assert hashlib.sha256(sdk_archive.read_bytes()).hexdigest() == sdk["archiveSHA256"]
assert sdk["pluginVersion"] == manifest["version"]
with tarfile.open(sdk_archive) as archive:
    for member in archive.getmembers():
        parts = pathlib.PurePosixPath(member.name).parts
        assert parts[0] == "ToolSDK" and ".." not in parts
        assert member.isfile() or member.isdir()
        assert not member.name.endswith(".node"), "tool SDK must be architecture independent"
    for package, version in [("@opencode-ai/plugin", sdk["pluginVersion"]), ("zod", sdk["zodVersion"])]:
        data = json.load(archive.extractfile(f"ToolSDK/node_modules/{package}/package.json"))
        assert data["version"] == version
version = manifest["version"]
assert re.fullmatch(r"\d+\.\d+\.\d+", version)
assert set(manifest["assets"]) == {"arm64", "x86_64"}
for architecture, asset in manifest["assets"].items():
    assert f"/v{version}/" in asset["url"]
    assert asset["url"].startswith("https://github.com/anomalyco/opencode/releases/download/")
    for key in ("archiveSHA256", "binarySHA256"):
        assert re.fullmatch(r"[0-9a-f]{64}", asset[key])
    fallback = pathlib.Path(manifest["developerFallbacks"][architecture]["path"])
    if fallback.is_file() and fallback.stat().st_mode & 0o111:
        digest = hashlib.sha256(fallback.read_bytes()).hexdigest()
        assert digest == asset["binarySHA256"]
        actual = subprocess.check_output([str(fallback), "--version"], text=True).strip()
        assert actual == version
if args.app:
    runtime = args.app / "Contents/Resources/Runtime/OpenCode"
    assert (runtime / "tool-sdk.json").read_bytes() == (sdk_root / "tool-sdk.json").read_bytes()
    assert hashlib.sha256((runtime / "tool-sdk.tar.gz").read_bytes()).hexdigest() == sdk["archiveSHA256"]
    installed = json.loads((runtime / "installed.json").read_text())
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    if architecture != "x86_64":
        architecture = "arm64"
    assert installed == {
        "version": version,
        "architecture": architecture,
        "sourceBinarySHA256": manifest["assets"][architecture]["binarySHA256"],
        "installedBinarySHA256": hashlib.sha256((runtime / "opencode").read_bytes()).hexdigest(),
    }
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
print(f"OpenCode manifest: v{version}, 2 macOS architectures, digests valid")
