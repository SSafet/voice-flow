import hashlib
import importlib.util
import io
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
