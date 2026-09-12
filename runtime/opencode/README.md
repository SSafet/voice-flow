# Bundled OpenCode runtime and tools

`versions.json` pins the native binaries. `tool-sdk.json` pins the npm package
integrities and the SHA-256 of `tool-sdk.tar.gz`. The archive contains the
unmodified `@opencode-ai/plugin` 1.17.11 package and Zod 4.1.8, including their
tool entry points and licenses. Only the plugin's root/tool exports are used;
its optional Effect/TUI APIs are outside this tool-only distribution.

The first real cold-start test on 12 September 2026 failed before a provider
call: OpenCode tried to install the SDK inside its sandbox, registry downloads
failed, and the custom tool import failed after 169 seconds. The app now
verifies and extracts its bundled SDK once and links the actual package into
each generated config/assistant tree before starting or using the runtime.
Unrelated npm packages and manifest entries are preserved. The local link and
lock metadata let the pinned runtime recognize that the dependency is ready.
Voice Flow also disables OpenCode's separate models.dev fetch because the app
already supplies the selected model's OpenRouter catalog metadata.

Reproduce the archive from the integrity-checked upstream tarballs:

```sh
python3 scripts/vendor-opencode-tool-sdk.py
python3 tests/validate_runtime_manifest.py
```

The reproducible build runs no npm lifecycle scripts and refuses output that
differs from the reviewed archive hash. The archive has no native binaries and
works with both supported Mac architectures. Installation carries the archive
inside the signed app; missing or altered SDK assets fail explicitly.

`opencode_runtime` tests preservation, idempotent setup, corrupt-archive
rejection, cache repair, and refusal to follow an unrelated dependency-directory
symlink. The real `opencode_live_turn` probe starts from empty state with all
external runtime network access disabled, then checks text, private tools,
skills, images, approval rejection/acceptance and child-process cancellation.

The pinned upstream implementation is the compatibility authority:
[dependency reconciliation](https://github.com/anomalyco/opencode/blob/v1.17.11/packages/core/src/npm.ts),
[custom tool loading](https://github.com/anomalyco/opencode/blob/v1.17.11/packages/opencode/src/tool/registry.ts),
and [tool SDK entry point](https://github.com/anomalyco/opencode/blob/v1.17.11/packages/plugin/src/tool.ts).
