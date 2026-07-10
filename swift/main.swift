import Cocoa

// A write to a disconnected HTTP/MCP client would otherwise raise SIGPIPE and
// kill the whole app (no crash report); ignore it so writes fail with EPIPE.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
