#!/bin/bash
# AttachmentPackager.record. No database: the capture side is a fake provider,
# so this suite compiles its own named sources with swiftc.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

OUTPUT="$(mktemp -d /tmp/vf-attachment-records.XXXXXX)/run"
trap 'rm -rf "$(dirname "$OUTPUT")"' EXIT
swiftc -o "$OUTPUT" \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/Store/CapturedValues.swift \
    swift/Captured/Marks/MarkModelText.swift \
    swift/Captured/Attachments/CapturedItemProvider.swift \
    swift/Captured/Attachments/AttachmentPackager.swift \
    swift/Captured/Attachments/BundleModelText.swift \
    swift/Captured/Attachments/AttachmentRecords.swift \
    tests/attachment_records/main.swift \
    -suppress-warnings -framework Cocoa -framework CoreGraphics
"$OUTPUT"
