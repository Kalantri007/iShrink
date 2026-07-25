import SwiftUI
import iShrinkCore

// iShrink Phase 1 plan, U9 "App UI" — `CompressionRunView`.
//
// Progress (items done/total, current file, elapsed/ETA, running GB
// saved) plus Pause/Cancel (R11), wired to `AppModel`'s compression-run
// state, which itself is driven by U7's `CompressionPipeline` via
// `AppModel.beginCompressionRun()`. All state updates land on `@MainActor`
// (this is a SwiftUI view driven entirely by `@Published` `AppModel`
// properties — no logic of its own beyond formatting).
//
// Pause is shown with its `PauseReason` and remediation copy; Cancel is
// gated behind an explicit confirmation dialog (plan: "so an accidental
// click doesn't silently abort a long run"); and a Resume/Discard prompt is
// shown up front instead of silently re-running when `AppModel` finds an
// incomplete manifest for the same selection+destination.
struct CompressionRunView: View {
    @ObservedObject var appModel: AppModel
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Compressing")
                .font(.title2)
                .fontWeight(.semibold)

            if let prompt = appModel.resumePrompt {
                resumePromptSection(prompt)
            } else {
                progressSection

                if let reason = appModel.pauseReason {
                    pauseBanner(reason)
                }

                Spacer()

                controls
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 360)
        .onReceive(timer) { date in now = date }
        .confirmationDialog(
            "Stop compressing?",
            isPresented: $appModel.showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Compressing", role: .destructive) {
                appModel.confirmCancelCompression()
            }
            Button("Keep Going", role: .cancel) {
                appModel.dismissCancelConfirmation()
            }
        } message: {
            Text("Files already finished are kept in \(destinationFolderName).")
        }
    }

    // MARK: - Resume / Discard prompt

    @ViewBuilder
    private func resumePromptSection(_ prompt: AppModel.ResumePrompt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("A previous run was interrupted", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("\(prompt.itemsDone) item(s) already finished, \(prompt.itemsRemaining) remaining.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Discard and Start Over", role: .destructive) {
                    appModel.discardAndRestartFromPrompt()
                }
                Spacer()
                Button("Resume") {
                    appModel.resumeFromPrompt()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progressFraction)

            if let progress = appModel.runProgress {
                Text("\(progress.itemsDone) of \(progress.itemsTotal) items")
                    .font(.headline)
                if let currentFilename = progress.currentFilename, appModel.pauseReason == nil {
                    Text("Compressing \(currentFilename)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Label(elapsedString, systemImage: "clock")
                if let eta = etaString {
                    Label(eta, systemImage: "hourglass")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text("Saved so far: \(byteString(appModel.runningSavedBytes))")
                .font(.callout)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Pause banner (R11: reason + remediation)

    @ViewBuilder
    private func pauseBanner(_ reason: PauseReason) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(pauseTitle(reason), systemImage: "pause.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(pauseRemediation(reason))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if reason != .destinationUnavailable {
                Button("Resume") {
                    appModel.resumeAfterPause()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pauseTitle(_ reason: PauseReason) -> String {
        switch reason {
        case .userRequested: return "Paused"
        case .lowDiskSpace: return "Paused — low disk space"
        case .authorizationRevoked: return "Paused — Photos access revoked"
        case .destinationUnavailable: return "Stopped — output folder unavailable"
        }
    }

    private func pauseRemediation(_ reason: PauseReason) -> String {
        switch reason {
        case .userRequested:
            return "Compression is paused. Resume whenever you're ready."
        case .lowDiskSpace:
            return "Free up space on \(destinationFolderName)'s volume, then resume."
        case .authorizationRevoked:
            return "Photos access was revoked. Re-grant Photos access in System Settings, then resume."
        case .destinationUnavailable:
            return "Reconnect \(destinationFolderName)'s volume. Compression will pick up where it left off once it's back."
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        HStack {
            if appModel.pauseReason == nil {
                Button("Pause") {
                    appModel.pauseCompression()
                }
            }
            Spacer()
            Button("Cancel", role: .destructive) {
                appModel.requestCancelCompression()
            }
        }
    }

    // MARK: - Formatting

    private var progressFraction: Double {
        guard let progress = appModel.runProgress, progress.itemsTotal > 0 else { return 0 }
        return Double(progress.itemsDone) / Double(progress.itemsTotal)
    }

    private var elapsedString: String {
        guard let startedAt = appModel.runStartedAt else { return "Elapsed: 0s" }
        return "Elapsed: \(durationFormatter.string(from: now.timeIntervalSince(startedAt)) ?? "0s")"
    }

    private var etaString: String? {
        guard
            let startedAt = appModel.runStartedAt,
            let progress = appModel.runProgress,
            progress.itemsDone > 0,
            progress.itemsDone < progress.itemsTotal
        else {
            return nil
        }
        let elapsed = now.timeIntervalSince(startedAt)
        let perItem = elapsed / Double(progress.itemsDone)
        let remaining = perItem * Double(progress.itemsTotal - progress.itemsDone)
        return "ETA: \(durationFormatter.string(from: remaining) ?? "—")"
    }

    private var destinationFolderName: String {
        appModel.destinationURL?.lastPathComponent ?? "the output folder"
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var durationFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }
}
