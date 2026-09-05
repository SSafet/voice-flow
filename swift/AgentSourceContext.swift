import Foundation

enum AgentSourceContext {
    /// Resolve once at turn start. A missing selection fails closed; a failed
    /// refresh may still supply the clearly labelled last successful copy.
    static func freeze(sourceIDs: [String], store: DataSourceStore = DataSourceStore()) throws -> String {
        let selected = AgentSourceSelection.normalized(sourceIDs)
        guard !selected.isEmpty else { return "" }
        let snapshot = store.freezeContext(sourceIDs: selected)
        let available = Set(snapshot.sources.filter { $0.snapshotID != nil }.map(\.sourceID))
        let missing = selected.filter { !available.contains($0) }
        guard missing.isEmpty else {
            let detail = snapshot.issues.isEmpty
                ? "A selected source has no saved copy." : snapshot.issues.joined(separator: " ")
            throw AgentRuntimeFailure(code: "source_context_unavailable",
                message: "\(detail) Open Data to collect it or update the selected sources.", retryable: false)
        }
        return snapshot.promptText
    }
}
