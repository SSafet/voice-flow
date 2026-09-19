import SwiftUI

/// The About tab of the native Settings window. It shows what the launch-time
/// contract self-check found, and nothing that needs the web view.
struct AboutSettingsView: View {
    let outcome: ContractSelfCheck.Outcome?

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return short == build ? short : "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice Flow \(version)").font(.system(size: 13, weight: .semibold))
            if let outcome {
                Text(outcome.aboutLine)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(outcome.passed ? Color.primary : Color.red)
                if !outcome.passed {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(outcome.problems.prefix(8), id: \.self) { problem in
                            Text(problem).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .textSelection(.enabled)
                }
            } else {
                Text("The contract self-check has not run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}
