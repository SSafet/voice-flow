import Cocoa

#if VOICE_FLOW_QA
// This must be the first executable code: even logging creates the default
// configuration directory. GUI relaunch does not retain a harness environment.
do {
    try QALaunchIsolation.validate()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(78)
}
#endif

// A write to a disconnected HTTP/MCP client would otherwise raise SIGPIPE and
// kill the whole app (no crash report); ignore it so writes fail with EPIPE.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
