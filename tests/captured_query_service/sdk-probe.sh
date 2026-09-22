#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REV=a0ae212ebf6eab5f754c3129608bc5557637e605
: "${VF_CAPTURED_QUERY_FIXTURE:?Run test.sh with a temporary VF_CAPTURED_QUERY_FIXTURE path first}"
if [ -z "${VF_MCP_SDK_CHECKOUT:-}" ]; then
    VF_MCP_SDK_CHECKOUT="$(mktemp -d /tmp/vf-captured-sdk.XXXXXX)"
    git -C "$VF_MCP_SDK_CHECKOUT" init -q
    git -C "$VF_MCP_SDK_CHECKOUT" fetch -q --depth 1 https://github.com/modelcontextprotocol/swift-sdk.git "$REV"
    git -C "$VF_MCP_SDK_CHECKOUT" checkout -q --detach FETCH_HEAD
fi
case "$VF_MCP_SDK_CHECKOUT" in /tmp/vf-*|/private/tmp/vf-*) ;; *) echo 'SDK probe requires an isolated temporary checkout' >&2; exit 1 ;; esac
[ "$(git -C "$VF_MCP_SDK_CHECKOUT" rev-parse HEAD)" = "$REV" ]
PROBE="$VF_MCP_SDK_CHECKOUT/Tests/MCPTests/CapturedSDKAdapterProbe.swift"
[ ! -e "$PROBE" ]
trap 'rm -f "$PROBE"' EXIT
cp "$REPO_ROOT/tests/captured_query_service/SDKAdapterProbe.swift" "$PROBE"
swift test --package-path "$VF_MCP_SDK_CHECKOUT" --filter 'CapturedSDKAdapterProbe|VersioningTests|ToolTests|CancellationTests|HTTPServerTransportTests'
