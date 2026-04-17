import SwiftUI

struct ProviderTestRow: View {
    enum Kind {
        case refinement(RefinementProviderID)
        case transcription(TranscriptionProviderID)
    }

    let kind: Kind

    @State private var isRunning: Bool = false
    @State private var outcome: ProviderTestOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button {
                    run()
                } label: {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(isRunning ? "Testing…" : "Test")
                    }
                }
                .disabled(isRunning)
            }

            if let outcome {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: outcome.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(outcome.isError ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.2fs", outcome.latency))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(outcome.message)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        outcome = nil
        Task {
            let result: ProviderTestOutcome
            switch kind {
            case .refinement(let id):
                result = await ProviderTestRunner.testRefinement(id)
            case .transcription(let id):
                result = await ProviderTestRunner.testTranscription(id)
            }
            outcome = result
            isRunning = false
        }
    }
}
