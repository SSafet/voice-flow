# T3 Mac shell artifact boundary

The selected environment fork is `atika-environment`. The Mac shell attaches to
its approved local HTTP(S) origin and validates its expected `environmentId`
before disclosing a bootstrap credential. A local primary environment serves
the web client; remote environments remain connections inside that client. The
native bridge-enabled document cannot be a remotely updated web page.

Package the complete upstream CLI archive from the same reviewed release build.
The existing upstream `scripts/build-cli-archive.ts` assembles:

```
t3
client/               # matching web build, including index.html
resource-monitor/
node_modules/         # upstream runtime externals/native modules
```

The upstream server build (`node apps/server/scripts/cli.ts build`) copies
`apps/web/dist` into `apps/server/dist/client`. Its executable build uses the
upstream Node SEA packaging, and the archive builder stages native externals.
Use those commands and archive builder from the selected fork. Copying only
`dist/bin.mjs`, a web folder, or the executable loses required runtime contents.

After the release owner supplies the archive's reviewed SHA256, the small
VoiceFlow staging adapter can validate and copy it for a future app bundle:

```sh
.venv/bin/python scripts/stage-t3-shell-runtime.py \
  --archive /path/to/reviewed/t3-release-darwin-arm64.tar.gz \
  --sha256 REVIEWED_ARCHIVE_SHA256 --destination /tmp/new-t3-runtime-stage
```

It verifies the complete archive hash, rejects unsafe extraction/incomplete
content, refuses installed/live-data paths, preserves all upstream bytes, and
publishes to a new path with Darwin's exclusive atomic rename. It adds one
provenance receipt. It does not download, update, sign, install or launch code.
The app's release owner still verifies provenance, architecture, nested signing,
the matching client, and the final app signature. Synthetic staging tests are
not a signed real-runtime packaging proof.

No child environment launcher is added in this boundary. Existing-environment
attachment is implemented first. If app-owned launch is later needed, reuse
the selected upstream CLI's `--bootstrap-fd` envelope and lifecycle rather than
inventing a server or putting the bootstrap secret in argv/environment. The
native window never stops an environment it merely attached to.
