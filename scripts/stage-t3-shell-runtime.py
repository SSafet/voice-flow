#!/usr/bin/env python3
"""Stage the COMPLETE upstream CLI archive unchanged for later app packaging.

The release owner supplies a reviewed archive checksum. This is not an updater,
builder, downloader, process launcher or separate web/server implementation.
Requires Python with tar extraction safety filters (including the repo's 3.11.14).
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def publish_new_directory(source, destination):
    # This is a macOS artifact. Darwin's established exclusive rename atomically
    # refuses even an empty destination created since the initial existence check.
    if sys.platform != "darwin":
        raise ValueError("The Mac shell artifact must be staged on macOS.")
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL, sys/stdio.h
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def stage(archive, expected_sha256, destination):
    archive = Path(archive).resolve(strict=True)
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination must be new; existing runtimes are never replaced.")
    if len(expected_sha256) != 64 or digest(archive) != expected_sha256.lower():
        raise ValueError("Archive does not match the reviewed checksum.")
    if not hasattr(tarfile, "data_filter"):
        raise ValueError("Python with tarfile.data_filter is required for safe archive extraction.")
    forbidden = [Path("/Applications"), Path.home() / ".config/voice-flow", Path.home() / ".t3/userdata"]
    resolved = destination.resolve()
    for root in forbidden:
        root = root.resolve()
        if resolved == root or root in resolved.parents or resolved in root.parents:
            raise ValueError("Refusing an installed-app or live-data destination.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".t3-stage-", dir=destination.parent) as temporary:
        root = Path(temporary)
        with tarfile.open(archive, "r:gz") as source:
            source.extractall(root, filter="data")
        entries = list(root.iterdir())
        if len(entries) != 1 or not entries[0].is_dir() or entries[0].is_symlink():
            raise ValueError("Expected the complete upstream archive with one root directory.")
        content = entries[0]
        executable = content / "t3"
        if not executable.is_file() or not executable.stat().st_mode & 0o111:
            raise ValueError("The macOS upstream executable is missing or not executable.")
        if not (content / "client/index.html").is_file():
            raise ValueError("The matching upstream web client is missing.")
        for relative in ["resource-monitor", "node_modules"]:
            directory = content / relative
            if not directory.is_dir() or not any(directory.iterdir()):
                raise ValueError("The complete upstream runtime externals/resource monitor are required.")
        # Add one provenance receipt. The upstream client/server/native files
        # remain byte-identical, including internal relative symlinks.
        receipt = {"archiveSha256": expected_sha256.lower(), "archiveName": archive.name,
                   "executableSha256": digest(executable),
                   "clientIndexSha256": digest(content / "client/index.html")}
        receipt_path = content / "voiceflow-archive-receipt.json"
        if receipt_path.exists():
            raise ValueError("Archive unexpectedly contains a shell staging receipt.")
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        publish_new_directory(content, destination)
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--destination", required=True, type=Path)
    options = parser.parse_args()
    print(json.dumps(stage(options.archive, options.sha256, options.destination), sort_keys=True))
