## Releases read on 2026-09-19

```
groue/GRDB.swift v7.11.1 2026-06-18T12:15:08Z
hummingbird-project/hummingbird 2.26.0 2026-07-29T09:21:04Z
hummingbird-project/hummingbird-websocket 2.7.0 2026-05-22T12:56:28Z
jpsim/Yams 6.2.2 2026-05-26T16:15:14Z
BurntSushi/ripgrep 15.2.0 2026-07-15T16:26:10Z
migueldeicaza/SwiftTerm v1.19.0 2026-08-18T15:55:10Z
```

## SwiftTerm is not pinned

SwiftTerm 1.19.0's package manifest declares `resources: [.process("Apple/Metal/Shaders.metal")]`
on its one `SwiftTerm` target, so Swift Package Manager runs `metal` on it. On this Mac the
Metal Toolchain is a separate, uninstalled Xcode component, and the build ends in
`error: Build failed` (`swiftterm-metal.txt`). The manifest's own `SWIFTTERM_EXCLUDE_APPLE=1`
escape does not avoid it, because the resource is declared outside the platform-exclude branch;
the measurement above was taken with that variable set and with the manifest cache disabled.
The shader was added to SwiftTerm on 2026-03-15, after every release the designs consider.
Pinning it here would make `./install.sh` fail on the owner's own Mac. The package that needs
`LocalProcess` — the terminal service — settles this first: either the build Mac installs the
component with `xcodebuild -downloadComponent MetalToolchain`, or the pseudo-terminal comes
from somewhere else. `Package.swift` is edited by additive one-line commits, so adding it
later costs one line.
