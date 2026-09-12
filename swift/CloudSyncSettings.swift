import SwiftUI

struct CloudSyncSettingsView: View {
    @ObservedObject private var model = CloudSyncController.shared
    @State private var search = ""
    @State private var content = CloudCollection.dictations
    @State private var showDeleted = false
    private var visible: [CloudLocalRecord] {
        model.records.filter {
            $0.collection == content && (showDeleted || $0.payload != nil) &&
            (search.isEmpty || ($0.payload?.text ?? $0.payload?.title ?? $0.recordId).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        Form {
            Section {
                Picker("Transport", selection: Binding(get: { model.selection.transport }, set: model.setTransport)) {
                    Text("Local network").tag("local")
                    Text("Atika cloud").tag("cloud")
                }
                .pickerStyle(.segmented)
                Text(model.status).font(.callout).textSelection(.enabled).accessibilityIdentifier("cloud-sync-status")
                if model.busy { ProgressView().controlSize(.small) }
            } header: {
                Text("Sync")
            } footer: {
                Text("Cloud keeps Inbox text, completed conversation messages, vocabulary, model choice and cleanup preference. Attachments remain on their device. Selecting cloud pauses local network sync.")
            }
            if model.selection.transport == "cloud" {
                Section("Share from this Mac") {
                    Toggle("Inbox text", isOn: exportBinding(\.dictations))
                    Toggle("Completed conversations", isOn: exportBinding(\.conversations))
                    Toggle("Vocabulary, model and cleanup preference", isOn: exportBinding(\.preferences))
                    Text("Choices are saved for this account. Turning a type off keeps its queued edits here and stops sending them; existing cloud copies remain.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy)
                if model.selection.signedIn {
                    Section("Account") {
                        LabeledContent("Signed in", value: model.selection.email)
                        LabeledContent("Atika server", value: model.selection.origin)
                        HStack {
                            Button("Sync now") { model.sync() }.disabled(model.busy)
                            Spacer()
                            Button("Sign out") { model.signOut() }.disabled(model.busy)
                        }
                        Text("Signing out keeps this account’s local history and pending changes. History already on this Mac remains readable when another account is selected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Sign in to Atika") {
                        TextField("Atika server", text: $model.originDraft).disabled(model.challenge != nil || model.busy)
                        TextField("Email", text: $model.emailDraft).textContentType(.emailAddress).disabled(model.challenge != nil || model.busy)
                        if model.challenge != nil {
                            Text("Enter the code sent to \(model.challenge!.email).")
                            TextField("Email code", text: $model.codeDraft).textContentType(.oneTimeCode)
                                .onSubmit { model.completeLogin() }
                            Button("Sign in and sync") { model.completeLogin() }.disabled(model.busy || model.codeDraft.isEmpty)
                            Button("Send a new code") { model.beginLogin() }.disabled(model.busy)
                            Button("Use a different email or server") { model.cancelLogin() }.disabled(model.busy)
                        } else {
                            Button("Send sign-in code") { model.beginLogin() }.disabled(model.busy || model.emailDraft.isEmpty)
                        }
                    }
                }
                if model.requiresBaselineReview {
                    Section("Cloud history changed") {
                        Text("The server restored an earlier history. Reloading keeps every local edit and conflict, reads the restored cloud history, then checks your pending edits against it.")
                        Button("Reload baseline and check my saved edits") { model.reloadBaseline() }.disabled(model.busy)
                    }
                }
                if model.reviewCount > 0 {
                    Section("Kept on this Mac") {
                        Text("\(model.reviewCount) records exceed this version’s cloud limits or need an update. Their original contents are saved locally; other records can still sync.")
                        Button("Open retained copies") { model.openReviewCopies() }
                    }
                }
                if !model.conflicts.isEmpty {
                    Section("Conflicts") {
                        ForEach(model.conflicts, id: \.conflictId) { conflict in
                            DisclosureGroup("\(conflict.collection.rawValue.capitalized) · \(String((conflict.proposed.payload?.text ?? conflict.proposed.payload?.title ?? "Deletion").prefix(60)))") {
                                Text("Retained proposal").font(.caption).foregroundStyle(.secondary)
                                Text(conflict.proposed.payload?.text ?? conflict.proposed.payload?.title ?? "Delete this record")
                                    .textSelection(.enabled)
                                if let local = model.records.first(where: { $0.collection == conflict.collection && $0.recordId == conflict.recordId }) {
                                    Text("This Mac").font(.caption).foregroundStyle(.secondary)
                                    Text(local.payload?.text ?? local.payload?.title ?? "Deleted").textSelection(.enabled)
                                }
                                HStack {
                                    Button("Use this Mac") { model.resolve(conflict, choice: .local) }
                                    Button("Use cloud") { model.resolve(conflict, choice: .cloud) }
                                    Button("Use proposal") { model.resolve(conflict, choice: .proposal) }
                                }.disabled(model.busy || !model.selection.signedIn)
                                Text("Each choice checks the latest cloud version. A new concurrent edit remains a conflict.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !model.records.isEmpty {
                    Section("Saved cloud data") {
                        Picker("Show", selection: $content) {
                            Text("Inbox").tag(CloudCollection.dictations)
                            Text("Threads").tag(CloudCollection.threads)
                            Text("Preferences").tag(CloudCollection.preferences)
                        }.pickerStyle(.segmented)
                        TextField("Search saved data", text: $search)
                        Toggle("Show deleted records", isOn: $showDeleted)
                        Text("\(visible.count) records\(visible.count > 100 ? " · showing the first 100; search to narrow" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(visible.prefix(100)), id: \.recordId) { row in
                            if row.collection == .threads { CloudThreadRow(row: row, model: model) }
                            else {
                                DisclosureGroup(row.payload?.text.map { String($0.prefix(75)) } ?? row.payload?.title ?? row.recordId) {
                                    Text(row.payload?.text ?? preferenceText(row.payload?.value) ?? "Deleted")
                                        .textSelection(.enabled)
                                    if row.payload != nil {
                                        Button("Delete on synced devices", role: .destructive) { model.deleteRecord(row) }
                                            .disabled(model.busy)
                                    } else if row.lastLivePayload != nil {
                                        Button("Restore this record") { model.restoreRecord(row) }.disabled(model.busy)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
    }
    private func preferenceText(_ value: CloudPreference?) -> String? {
        switch value { case .text(let text): return text; case .words(let words): return words.joined(separator: ", ")
        case .enabled(let flag): return flag ? "Enabled" : "Disabled"; case nil: return nil }
    }
    private func exportBinding(_ key: WritableKeyPath<CloudExportSelection, Bool>) -> Binding<Bool> {
        Binding(get: { model.selection.included[keyPath: key] }, set: { value in
            var selection = model.selection.included; selection[keyPath: key] = value; model.setExports(selection)
        })
    }
}

private struct CloudThreadRow: View {
    let row: CloudLocalRecord
    @ObservedObject var model: CloudSyncController
    private var messages: [CloudLocalRecord] {
        model.records.filter { $0.collection == .messages && $0.payload?.threadId == row.recordId }
    }
    private var leaves: [CloudLocalRecord] {
        let parents = Set(messages.compactMap { $0.payload?.parentMessageId })
        return messages.filter { !parents.contains($0.recordId) }.sorted { ($0.payload?.createdAt ?? "") < ($1.payload?.createdAt ?? "") }
    }
    private func chain(_ leaf: CloudLocalRecord) -> [CloudLocalRecord] {
        let map = Dictionary(uniqueKeysWithValues: messages.map { ($0.recordId, $0) })
        var result: [CloudLocalRecord] = []; var next: CloudLocalRecord? = leaf; var visited: Set<String> = []
        while let item = next, !visited.contains(item.recordId) {
            visited.insert(item.recordId); result.append(item)
            next = item.payload?.parentMessageId.flatMap { map[$0] }
        }
        return result.reversed()
    }
    var body: some View {
        DisclosureGroup(row.payload?.title ?? "Deleted thread") {
            Text("\(messages.count) completed messages · \(leaves.count) \(leaves.count == 1 ? "branch" : "branches")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(leaves.enumerated()), id: \.element.recordId) { index, leaf in
                DisclosureGroup("Branch \(index + 1) · \(String((leaf.payload?.text ?? "").prefix(45)))") {
                    ForEach(chain(leaf), id: \.recordId) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.payload?.role?.capitalized ?? "Message").font(.caption).foregroundStyle(.secondary)
                            Text(message.payload?.text ?? "").textSelection(.enabled)
                        }.padding(.vertical, 5)
                    }
                    Button("Continue this branch on this Mac") { model.continueBranch(thread: row, leafID: leaf.recordId) }
                }
            }
            Text("Continuing creates a new local conversation from this branch’s words.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
