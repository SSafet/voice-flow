#!/bin/bash
# The subtraction check for work package S6: the data sources feature and
# everything that existed only for it is gone from the VoiceFlow sources, its
# tests are gone from the tree, and the harness and the registry no longer run
# them. This is a deletion package, so most of "done" is absence.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PASS=0
ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
die() { echo "not ok - $1" >&2; exit 1; }

# The check itself must be able to find a symbol that is present, or every
# absence assertion below would pass against a broken grep.
grep -rIq --include='*.swift' -e 'AgentPromptComposer' swift ||
    die "the symbol check cannot see a symbol that is present"
[ -f swift/App.swift ] || die "the file check cannot see a file that is present"
ok "the absence checks can see present symbols and files"

# The eight Swift files of the feature are gone.
for file in DataSources.swift SourceCollector.swift SourceReviewRuntime.swift \
    SourceSelectionView.swift SourcesView.swift App+Sources.swift \
    AgentSourceConfiguration.swift AgentSourceContext.swift; do
    [ ! -e "swift/$file" ] || die "swift/$file still exists"
done
ok "the eight data-sources source files are gone"

# Their two test suites are gone, including the UI suite nested under the first.
[ ! -e tests/data_sources ] || die "tests/data_sources still exists"
[ ! -e tests/source_review ] || die "tests/source_review still exists"
ok "the data-sources and source-review test suites are gone"

# No file of the product, its suites or its scripts still names a data-sources
# type, field, column or entry point. The list is every public name 07 section
# 5 deletes; a file that merely keeps one of them alive would keep the feature
# reachable, and a suite that still names one no longer compiles.
SYMBOLS=(
    SourceKind SourceDefinition DataSourceStore DataSourceError
    SourceCollectionResult CollectedSourceDocument SourceSnapshot SourceStatus
    SourceItem SourceContextDocument SourceContextEntry SourceContextSnapshot
    AgentSourceAccessMode AgentSourceChoice AgentSourceSelection
    AgentSourceContext AgentSourceConfiguration SourceReviewRuntime
    SourceSelectionView SourcesView SourceConsumerLink SourceSelectionOption
    setSourcesView showSources showSourceConsumer
    selectedSourceIDs sourceAccessMode selectedSourceAccessMode
    source_ids_json source_access_mode selected_source_ids sourceInstructions
    sourcesView dataSourceStore sourceCollector configureSourceWorkspace
    agentDataSourceOptions openAgentDataSources
)
SCAN=(swift tests scripts)
# This suite's own files name every symbol on purpose; they are the check.
SKIP=(--exclude-dir=data_sources_removed --exclude-dir=data_sources_retirement)
for symbol in "${SYMBOLS[@]}"; do
    if grep -rIq "${SKIP[@]}" -e "$symbol" "${SCAN[@]}"; then
        hits="$(grep -rIl "${SKIP[@]}" -e "$symbol" "${SCAN[@]}" | tr '\n' ' ')"
        die "the tree still names $symbol ($hits)"
    fi
done
ok "no source, suite or script names a data-sources symbol"

# The prompt composer keeps its other layers and has neither source layer.
grep -q 'enum AgentPromptComposer' swift/AgentPromptComposer.swift ||
    die "the prompt composer is still there"
grep -q 'var sourceInstructions' swift/AgentPromptComposer.swift &&
    die "the prompt composer still carries the source-instructions layer"
ok "the prompt composer survives without its source layers"

# The harness and the registry no longer run the deleted suites or compile the
# deleted files (including the auto-injected AgentSourceConfiguration.swift).
grep -q 'swift/DataSources.swift' scripts/test-agent-harness.sh &&
    die "the harness still compiles swift/DataSources.swift"
grep -q 'swift/SourceCollector.swift' scripts/test-agent-harness.sh &&
    die "the harness still compiles swift/SourceCollector.swift"
grep -q 'swift/SourcesView.swift' scripts/test-agent-harness.sh &&
    die "the harness still compiles swift/SourcesView.swift"
grep -q 'swift/AgentSourceConfiguration.swift' scripts/test-agent-harness.sh &&
    die "the harness still injects swift/AgentSourceConfiguration.swift"
grep -q 'tests/data_sources/' scripts/test-agent-harness.sh &&
    die "the harness still runs tests/data_sources"
grep -q 'tests/source_review' scripts/test-agent-harness.sh &&
    die "the harness still runs tests/source_review"
if grep -Eq '(^|[^_[:alnum:]])data_sources([^_[:alnum:]]|$)' scripts/test-agent-harness.sh; then
    die "the harness still names the data_sources suite"
fi
ok "the harness no longer compiles or runs anything the feature owned"

for suite in '"data_sources"' '"data_sources_ui"' '"source_review"' '"source_review_transport"'; do
    grep -Fq "$suite" tests/test_registry.json &&
        die "tests/test_registry.json still registers $suite"
done
for path in 'tests/data_sources/main.swift' 'tests/data_sources/ui/main.swift' \
    'tests/source_review/main.swift'; do
    grep -Fq "$path" tests/test_registry.json &&
        die "tests/test_registry.json still lists $path"
done
python3 -c 'import json,sys; json.load(open("tests/test_registry.json"))' ||
    die "tests/test_registry.json is no longer valid JSON"
ok "the registry no longer registers the deleted suites"

# This suite is not optional: the unit gate runs it, so a later change that
# brings the feature back is caught by the gate and not only by this file.
grep -Fq 'tests/data_sources_removed/test.sh' scripts/test-agent-harness.sh ||
    die "the harness does not run tests/data_sources_removed/test.sh"
python3 - <<'PY' || die "tests/test_registry.json does not register data_sources_removed"
import json
registry = json.load(open("tests/test_registry.json"))
suites = registry["runners"]["unit"]["required_suites"]
assert "data_sources_removed" in suites, "required_suites is missing data_sources_removed"
entries = [t for t in registry["tests"] if t["id"] == "tests/data_sources_removed/test.sh"]
assert entries, "no tests entry for tests/data_sources_removed/test.sh"
assert entries[0]["runner"] == "unit", "the entry is not on the unit runner"
assert "data_sources_removed" in entries[0]["suites"], "the entry names no data_sources_removed suite"
PY
ok "the unit gate runs this check"

# Subtraction has a floor: the watcher's own source folder is not this
# feature's (07 section 5 keeps it) and must survive the deletion.
[ -f watcher/sources/desktop/SOURCE.md ] ||
    die "watcher/sources/desktop/SOURCE.md was deleted; it is the watcher's, not the feature's"
ok "the watcher's own source folder survives"

echo "all $PASS checks passed"
