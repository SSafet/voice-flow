import hashlib
import importlib.util
import io
import json
import os
import subprocess
import time
from unittest.mock import patch
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("stage", Path(__file__).resolve().parents[2] / "scripts/stage-t3-shell-runtime.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageTests(unittest.TestCase):
    def archive(self, path, entries):
        with tarfile.open(path, "w:gz") as archive:
            for name, data in entries.items():
                member = tarfile.TarInfo(name)
                member.mode = 0o755 if name == "t3-mac/t3" else 0o644
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def complete_entries(self, executable):
        return {"t3-mac/t3": executable, "t3-mac/client/index.html": b"matching-client",
                "t3-mac/resource-monitor/monitor": b"monitor", "t3-mac/node_modules/native/addon.node": b"native"}

    def test_only_executable_discovery_can_mark_native_archive(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            marker = b'{"version":1,"nativeAuthorityRevocation":"sigusr2-v1"}'
            executable = b"#!/bin/sh\n[ \"$1\" = atika-capabilities ] || exit 2\nprintf '%s\\n' '" + marker + b"'\n"
            archive = root / "new.tar.gz"
            checksum = self.archive(archive, self.complete_entries(executable))
            with patch.object(module, "native_capability", side_effect=AssertionError("Unreviewed bytes executed")):
                with self.assertRaisesRegex(ValueError, "reviewed checksum"):
                    module.stage(archive, "0" * 64, root / "unreviewed", require_native=True)
            receipt = module.stage(archive, checksum, root / "new", require_native=True)
            self.assertEqual(receipt["nativeAuthorityRevocation"], "sigusr2-v1")
            self.assertEqual(json.loads((root / "new/voiceflow-archive-receipt.json").read_text()), receipt)
            self.assertEqual((root / "new/t3").read_bytes(), executable)
            old = root / "old.tar.gz"
            old_hash = self.archive(old, self.complete_entries(b"#!/bin/sh\nexit 2\n"))
            self.assertNotIn("nativeAuthorityRevocation", module.stage(old, old_hash, root / "preview"))
            with self.assertRaisesRegex(ValueError, "did not attest"):
                module.stage(old, old_hash, root / "native", require_native=True)
            self.assertFalse((root / "native").exists())

    def test_malformed_extra_duplicate_or_oversized_discovery_stays_unmarked(self):
        cases = [b'not-json', b'{"version":true,"nativeAuthorityRevocation":"sigusr2-v1"}',
                 b'{"version":1,"version":1,"nativeAuthorityRevocation":"sigusr2-v1"}',
                 b'{"version":1,"nativeAuthorityRevocation":"sigusr2-v1","extra":true}',
                 b'{"version":2,"nativeAuthorityRevocation":"sigusr2-v1"}', b'x'*5000]
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            executable = root / "t3"
            for output in cases:
                executable.write_bytes(b"#!/bin/sh\nprintf '%s\\n' '" + output + b"'\n")
                executable.chmod(0o755)
                self.assertIsNone(module.native_capability(executable, root))

    def test_probe_deadline_reaps_unknown_command_fallback(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); executable = root / "t3"
            executable.write_text("#!/bin/sh\nwhile :; do :; done\n")
            executable.chmod(0o755)
            start = time.monotonic()
            self.assertIsNone(module.native_capability(executable, root, timeout=0.1))
            self.assertLess(time.monotonic()-start, 3)

    def test_probe_has_no_ambient_credentials_network_or_external_file_access(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); runtime = root / "runtime"; runtime.mkdir()
            sentinel = root / "outside-source"; sentinel.write_bytes(b"preserved")
            output = root / "outside-write"
            source = root / "probe.c"
            # Only emit the marker after real OS calls prove each restriction.
            source.write_text(r'''#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
int main(void) {
 if (getenv("OPENROUTER_API_KEY") || getenv("NODE_OPTIONS") || getenv("DYLD_INSERT_LIBRARIES")) return 1;
 if (!getenv("HOME") || !getenv("T3CODE_HOME")) return 2;
 if (open(SOURCE_PATH, O_RDONLY) >= 0) return 3;
 if (open(OUTPUT_PATH, O_WRONLY|O_CREAT,0600) >= 0) return 4;
 int fd = socket(AF_INET, SOCK_STREAM, 0);
 struct sockaddr_in addr = {.sin_family=AF_INET, .sin_port=0}; addr.sin_addr.s_addr=inet_addr("127.0.0.1");
 if (fd >= 0 && bind(fd,(struct sockaddr *)&addr,sizeof(addr)) == 0) return 5;
 if (fd >= 0) close(fd);
 pid_t child = fork();
 if (child == 0) _exit(6);
 if (child > 0) return 6;
 puts("{\"version\":1,\"nativeAuthorityRevocation\":\"sigusr2-v1\"}");
 return 0;
}
''')
            executable = runtime / "t3"
            subprocess.run(["/usr/bin/cc", str(source), "-DSOURCE_PATH="+json.dumps(str(sentinel)),
                            "-DOUTPUT_PATH="+json.dumps(str(output)), "-o", str(executable)], check=True, capture_output=True)
            with patch.dict(os.environ, {"OPENROUTER_API_KEY":"synthetic-must-not-leak", "NODE_OPTIONS":"--invalid",
                                         "DYLD_INSERT_LIBRARIES":"/synthetic-must-not-leak"}):
                self.assertEqual(module.native_capability(executable, runtime), "sigusr2-v1")
            self.assertEqual(sentinel.read_bytes(), b"preserved")
            self.assertFalse(output.exists())

    def test_complete_archive_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            entries = {"t3-mac/t3": b"synthetic-executable", "t3-mac/client/index.html": b"matching-client",
                       "t3-mac/resource-monitor/monitor": b"monitor", "t3-mac/node_modules/native/addon.node": b"native"}
            archive = root / "upstream.tar.gz"
            checksum = self.archive(archive, entries)
            staged = root / "staged"
            module.stage(archive, checksum, staged)
            for name, data in entries.items():
                self.assertEqual((staged / name.split("/", 1)[1]).read_bytes(), data)
            with self.assertRaises(ValueError):
                module.stage(archive, checksum, staged)

    def test_checksum_missing_client_and_traversal_fail_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            archive = root / "upstream.tar.gz"
            for entries in [{"t3-mac/t3": b"incomplete"}, {"../escaped": b"bad"}]:
                checksum = self.archive(archive, entries)
                with self.assertRaises((ValueError, tarfile.FilterError)):
                    module.stage(archive, checksum, root / "staged")
                self.assertFalse((root / "staged").exists())
                self.assertFalse((root / "escaped").exists())
            with self.assertRaises(ValueError):
                module.stage(archive, "0" * 64, root / "staged")

    def test_publication_refuses_a_concurrently_created_empty_directory(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source, destination = root / "source", root / "destination"
            source.mkdir()
            destination.mkdir()
            (source / "sentinel").write_bytes(b"new runtime")
            with self.assertRaises(FileExistsError):
                module.publish_new_directory(source, destination)
            self.assertTrue(destination.is_dir())
            self.assertEqual(list(destination.iterdir()), [])
            self.assertEqual((source / "sentinel").read_bytes(), b"new runtime")

    def test_archive_links_cannot_target_existing_external_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            sentinel = root / "existing"
            sentinel.write_bytes(b"preserved")
            archive = root / "links.tar.gz"
            for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE]:
                with tarfile.open(archive, "w:gz") as output:
                    entry = tarfile.TarInfo("t3-mac/link")
                    entry.type = kind
                    entry.linkname = str(sentinel)
                    output.addfile(entry)
                checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
                with self.assertRaises(tarfile.FilterError):
                    module.stage(archive, checksum, root / "staged")
                self.assertEqual(sentinel.read_bytes(), b"preserved")
                self.assertFalse((root / "staged").exists())


if __name__ == "__main__":
    unittest.main()
