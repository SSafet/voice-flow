"""Compile the production broker closure against the repository's pinned SDK build."""
import os
from pathlib import Path
import platform
import subprocess
import sys

binary = Path(os.environ["VOICE_FLOW_TEST_SPM_BIN"])
build = next(p for p in binary.parents if p.name == ".build")
args = ["swiftc", "-target", f"{platform.machine()}-apple-macos14", "-swift-version", "5",
        "-parse-as-library", "-I", str(binary)]
# Xcode's SwiftPM build puts generated C module maps in Intermediates; the
# command-line SwiftPM layout puts them alongside each target's objects.
for package in ["swift-atomics", "swift-nio", "swift-system"]:
    for path in (build / "checkouts" / package).rglob("module.modulemap"):
        args += ["-I", str(path.parent)]
for path in build.rglob("*.modulemap"):
    if ("/Debug/" in str(path) or "/debug/" in str(path)) and path.stem.startswith(("CNIO", "_Atomics", "CSystem")):
        args += ["-Xcc", "-fmodule-map-file=" + str(path)]
objects = ["Hummingbird", "HummingbirdCore", "HTTPTypes", "Logging", "Configuration", "ConcurrencyHelpers",
           "AsyncAlgorithms", "Atomics", "_AtomicsShims", "CoreMetrics", "Metrics", "Instrumentation", "Tracing",
           "ServiceContextModule", "ServiceLifecycle", "UnixSignals", "SystemPackage", "CSystem",
           "ContainersPreview", "InternalCollectionsUtilities", "DequeModule", "OrderedCollections"]
for name in objects:
    path = binary / f"{name}.o"
    if path.exists():
        args.append(str(path))
args += [str(path) for path in binary.glob("*.o") if path.stem.startswith(("NIO", "CNIO", "_NIO"))]
args += ["swift/Shell/T3NativeAuthority.swift", "swift/Shell/T3NativeAuthorityBroker.swift",
         "tests/native_authority_broker/main.swift", "-o", sys.argv[1]]
raise SystemExit(subprocess.call(args))
