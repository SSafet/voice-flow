"""Build only the isolated native-tools HTTP fixture, never the app."""
import os
from pathlib import Path
import platform
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
os.chdir(root)
if len(sys.argv) != 2:
    raise SystemExit('usage: build.py /absolute/output/fixture')
output = Path(sys.argv[1])
if not output.is_absolute():
    raise SystemExit('fixture output must be absolute')
output.parent.mkdir(parents=True, exist_ok=True)
if 'VOICE_FLOW_TEST_SPM_BIN' not in os.environ:
    for target in ['Hummingbird', 'MCP', 'GRDB']:
        subprocess.run(['swift', 'build', '-c', 'debug', '--target', target, '-j', '2'], check=True, stdout=sys.stderr)
    binary = Path(subprocess.check_output(['swift', 'build', '-c', 'debug', '--show-bin-path'], text=True).strip())
else:
    binary = Path(os.environ['VOICE_FLOW_TEST_SPM_BIN']).resolve()
build = next(p for p in binary.parents if p.name == '.build')
args = ['swiftc', '-target', f'{platform.machine()}-apple-macos14', '-swift-version', '5', '-parse-as-library', '-I', str(binary)]
for package in ['swift-atomics', 'swift-nio', 'swift-system']:
    for path in (build / 'checkouts' / package).rglob('module.modulemap'):
        args += ['-I', str(path.parent)]
for path in build.rglob('*.modulemap'):
    if ('/Debug/' in str(path) or '/debug/' in str(path)) and path.stem.startswith(('CNIO', '_Atomics', 'CSystem')):
        args += ['-Xcc', '-fmodule-map-file=' + str(path)]
args += ['-Xcc', '-fmodule-map-file=' + str(build / 'checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
objects = ['MCP','EventSource','GRDB','Hummingbird','HummingbirdCore','HTTPTypes','Logging','Configuration','ConcurrencyHelpers',
           'AsyncAlgorithms','Atomics','_AtomicsShims','CoreMetrics','Metrics','Instrumentation','Tracing','ServiceContextModule',
           'ServiceLifecycle','UnixSignals','SystemPackage','CSystem','ContainersPreview','InternalCollectionsUtilities','DequeModule','OrderedCollections']
for name in objects:
    path = binary / f'{name}.o'
    if path.exists(): args.append(str(path))
args += [str(path) for path in binary.glob('*.o') if path.stem.startswith(('NIO','CNIO','_NIO'))]
args += ['swift/QALaunchIsolation.swift','swift/VoiceFlowPaths.swift','swift/DisplayContext.swift','swift/CaptureRouting.swift',
         'swift/CloudSyncModels.swift','swift/WatcherPolicy.swift','swift/WatcherBus.swift','swift/AgentSecretPolicy.swift',
         'swift/ImageUtils.swift','swift/Generated/PlatformContracts.swift']
args += [str(path.relative_to(root)) for path in sorted((root/'swift/Captured').rglob('*.swift'))]
args += ['swift/Inbox.swift','swift/MCP.swift','swift/MCPHTTPHost.swift','swift/MCPToolCancellation.swift',
         'swift/MCPCapturedCatalog.swift','swift/MCPCapturedReader.swift','swift/MCPOverlayScope.swift',
         'swift/NativeTools/T3NativeToolService.swift','swift/NativeTools/T3NativeToolCatalog.swift',
         'swift/NativeTools/T3NativeToolMCP.swift','swift/NativeTools/T3NativeToolPrimitives.swift',
         'swift/Shell/T3NativeAuthority.swift','swift/Shell/T3NativeAuthorityBroker.swift',
         'tests/t3_native_tools_fixture/main.swift','-framework','Cocoa','-framework','CoreGraphics','-o',str(output)]
subprocess.run(args, check=True)
print(output)
