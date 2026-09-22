#!/usr/bin/env python3
"""Stage the COMPLETE upstream CLI archive unchanged for later app packaging.

The release owner supplies a reviewed archive checksum. This is not an updater,
builder, downloader or server launcher. It probes the reviewed executable’s
read-only capability command in an isolated, network-denied process.
Requires Python with tar extraction safety filters (including the repo's 3.11.14).
"""
import argparse
import ctypes
import hashlib
import json
import os
import resource
import subprocess
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


def native_capability(executable, runtime_root, *, timeout=5):
    """Only the extracted executable can attest support; current source cannot.

    An old CLI might treat the unknown command as a server invocation. Its home
    is disposable, networking/forking are denied, output is bounded and the
    captured child is killed/reaped on deadline. No ambient account env survives.
    """
    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        return None
    with tempfile.TemporaryDirectory(prefix=".t3-capability-") as temporary:
        probe = Path(temporary).resolve()
        readable = [str(runtime_root.resolve()), str(probe), "/System", "/usr/lib", "/Library/Apple", "/bin", "/usr/bin"]
        profile = "(version 1)(deny default)(allow process-exec)(allow sysctl-read)"
        profile += "(allow file-read* " + " ".join("(subpath " + json.dumps(path) + ")" for path in readable) + ")"
        # Node resolves packaged native modules with realpath, which stats every
        # parent of the permitted runtime. Grant only ancestor metadata, not
        # directory listings or sibling file contents outside the private roots.
        ancestors = {str(parent) for path in [runtime_root.resolve(), probe] for parent in path.parents}
        profile += "(allow file-read-metadata " + " ".join("(literal " + json.dumps(path) + ")" for path in sorted(ancestors)) + ")"
        profile += "(allow file-read* (literal \"/\") (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"/dev/random\"))"
        profile += "(allow file-write* (subpath " + json.dumps(str(probe)) + ")(literal \"/dev/null\"))"
        environment = {"HOME": str(probe), "TMPDIR": str(probe), "PATH": "/usr/bin:/bin", "LANG": "C",
                       "XDG_CONFIG_HOME": str(probe / "config"), "XDG_DATA_HOME": str(probe / "data"),
                       "XDG_CACHE_HOME": str(probe / "cache"), "T3CODE_HOME": str(probe / "t3")}
        def bound_output():
            resource.setrlimit(resource.RLIMIT_FSIZE, (4096, 4096))
        with (probe / "stdout").open("w+b") as output:
            try:
                child = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, str(executable.resolve()), "atika-capabilities"],
                                         stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.DEVNULL,
                                         cwd=probe, env=environment, preexec_fn=bound_output)
                try:
                    code = child.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
                    return None
                output.seek(0)
                data = output.read(4097)
                if code != 0 or len(data) > 4096:
                    return None
            except OSError:
                return None
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("Duplicate capability key")
                result[key] = value
            return result
        try:
            value = json.loads(data, object_pairs_hook=unique_object)
        except (ValueError, UnicodeError):
            return None
        if (isinstance(value, dict) and set(value) == {"version", "nativeAuthorityRevocation"}
                and type(value["version"]) is int and value["version"] == 1
                and value["nativeAuthorityRevocation"] == "sigusr2-v1"):
            return value["nativeAuthorityRevocation"]
        return None


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


def stage(archive, expected_sha256, destination, *, require_native=False):
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
        capability = native_capability(executable, content)
        if capability is not None:
            receipt["nativeAuthorityRevocation"] = capability
        elif require_native:
            raise ValueError("Reviewed executable did not attest native runtime revocation support; no native artifact was published.")
        if digest(executable) != receipt["executableSha256"] or digest(content / "client/index.html") != receipt["clientIndexSha256"]:
            raise ValueError("Reviewed runtime bytes changed during capability discovery.")
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
    parser.add_argument("--require-native", action="store_true", help="Refuse publication unless the reviewed executable attests native revocation support.")
    options = parser.parse_args()
    print(json.dumps(stage(options.archive, options.sha256, options.destination, require_native=options.require_native), sort_keys=True))
