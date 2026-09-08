import SwiftUI

struct DailyFocusEditor: View {
    var fileURL: URL = DailyFocus.url
    @State private var draft = ""
    @State private var snapshot: DailyFocus.Snapshot?
    @State private var message = ""
    // Refresh the active date/status without replacing an in-progress draft.
    private let clock = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    @State private var changedElsewhere = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(changedElsewhere ? "Saved briefing changed elsewhere · draft kept below" : (snapshot?.status(at: now) ?? "Loading daily context…"))
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 160)
                .accessibilityLabel("Daily context")
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
            HStack {
                Button("Save for today") { save() }
                    .disabled(snapshot == nil || draft.count > DailyFocus.maxCharacters)
                Button("Reload saved") { reload() }
                Spacer()
                Text("\(draft.count) / \(DailyFocus.maxCharacters)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { reload() }
        .onReceive(clock) { date in
            now = date
            do {
                let saved = try DailyFocus.read(from: fileURL)
                if saved.bytes != snapshot?.bytes {
                    if draft == snapshot?.text { reload() }
                    else { changedElsewhere = true }
                }
            } catch { message = error.localizedDescription }
        }
    }

    private func reload() {
        do {
            let saved = try DailyFocus.read(from: fileURL)
            snapshot = saved; draft = saved.text; message = ""; changedElsewhere = false
        } catch { message = error.localizedDescription }
    }

    private func save() {
        guard let snapshot else { return }
        do {
            try DailyFocus.replace(draft, expected: snapshot, to: fileURL)
            reload(); now = Date()
            message = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Daily context cleared." : "Saved for today's assistant turns and Watcher reviews."
        } catch { message = error.localizedDescription }
    }
}
