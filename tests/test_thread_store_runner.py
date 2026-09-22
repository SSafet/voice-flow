"""The store-suite runner must propagate build, compile and assertion failures."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parent / "thread_store_common.sh"


class StoreRunnerTests(unittest.TestCase):
    def invoke(self, *, build=0, compile=0, assertion=0):
        with tempfile.TemporaryDirectory(prefix="vf-store-runner-") as directory:
            root = Path(directory)
            repo = root / "repo"
            products = repo / ".build/out/Products/Debug"
            products.mkdir(parents=True)
            (products / "GRDB.o").touch()
            modulemap = repo / ".build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"
            modulemap.parent.mkdir(parents=True)
            modulemap.touch()
            (repo / "Package.swift").touch()
            tools = root / "tools"
            tools.mkdir()
            (tools / "swift").write_text('''#!/bin/bash
case " $* " in
  *" --show-bin-path "*) printf '%s\\n' "$VF_RUNNER_PRODUCTS" ;;
  *) exit "$VF_RUNNER_BUILD_STATUS" ;;
esac
''')
            (tools / "swiftc").write_text('''#!/bin/bash
if [ "$VF_RUNNER_COMPILE_STATUS" -ne 0 ]; then exit "$VF_RUNNER_COMPILE_STATUS"; fi
[ "$1" = -o ] || exit 91
binary="$2"
printf '#!/bin/bash\\nexit %s\\n' "$VF_RUNNER_ASSERT_STATUS" > "$binary"
chmod +x "$binary"
''')
            for tool in tools.iterdir():
                tool.chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", "-c", '''set -euo pipefail
source "$1"
# Calling from a conditional deliberately disables inherited errexit. The
# runner must still return each failing command's actual exit status.
if build_and_run_store_suite runner_probe "$2"; then exit 0; else exit $?; fi
''', "runner-test", str(RUNNER), str(repo)],
                env={**os.environ, "PATH": f"{tools}:/usr/bin:/bin", "TMPDIR": str(root),
                     "VF_RUNNER_PRODUCTS": str(products), "VF_RUNNER_BUILD_STATUS": str(build),
                     "VF_RUNNER_COMPILE_STATUS": str(compile), "VF_RUNNER_ASSERT_STATUS": str(assertion)},
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(list(root.glob("vf-runner_probe-*")), [], "scratch files must be cleaned on failure")
            return result

    def test_nonzero_assertion_is_not_converted_to_success(self):
        self.assertEqual(self.invoke(assertion=37).returncode, 37)

    def test_build_failure_is_preserved(self):
        self.assertEqual(self.invoke(build=19).returncode, 19)

    def test_compile_failure_is_preserved(self):
        self.assertEqual(self.invoke(compile=23).returncode, 23)

    def test_success_is_preserved(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
