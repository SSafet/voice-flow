#!/usr/bin/env python3
import os,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[2]
deps=pathlib.Path(os.environ.get('VOICE_FLOW_DEPENDENCY_ROOT',root))
binary=pathlib.Path(os.environ.get('VOICE_FLOW_TEST_SPM_BIN',deps/'.build/out/Products/Debug'))
build=deps/'.build'
args=['swiftc','-typecheck','-swift-version','5','-target','arm64-apple-macosx14.0','-I',str(binary)]
for package in ['swift-atomics','swift-nio','swift-system']:
 for p in (build/'checkouts'/package).rglob('module.modulemap'): args += ['-I',str(p.parent)]
for p in build.rglob('*.modulemap'):
 if ('/Debug/' in str(p) or '/debug/' in str(p)) and p.stem.startswith(('CNIO','_Atomics','CSystem')): args+=['-Xcc','-fmodule-map-file='+str(p)]
args+=['-Xcc','-fmodule-map-file='+str(build/'checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
if '--qa' in sys.argv: args+=['-D','VOICE_FLOW_QA']
args += [str(p) for p in sorted((root/'swift').rglob('*.swift'))]
sys.exit(subprocess.run(args,cwd=root).returncode)
