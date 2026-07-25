import SwiftUI
import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI" — `ScanView`.
//
// Scan progress screen (R1/R2/R11): items scanned, elapsed time, and a
// Cancel affordance so a long 100k-asset scan can be aborted without
// force-quitting. All progress numbers come from `AppModel`'s
// `ScanProgress` state (fed by U3's `LibraryScanner` callbacks) — this view
// holds no scan logic of its own.
struct ScanView: View {
    @ObservedObject var appModel: AppModel
    @State private var elapsed: TimeInterval = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView(value: progressFraction)
                .frame(maxWidth: 320)

            if let progress = appModel.scanProgress {
                Text("\(progress.scanned) of \(progress.total) items scanned")
                    .font(.headline)
            } else {
                Text("Starting scan…")
                    .font(.headline)
            }

            Text("Elapsed: \(formattedElapsed)")
                .font(.callout)
                .foregroundStyle(.secondary)

            if appModel.scanWasCancelled {
                Text("Scan cancelled.")
                    .foregroundStyle(.secondary)
                Button("Retry Scan") {
                    appModel.beginScan()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel", role: .destructive) {
                    appModel.cancelScan()
                }
            }

            Spacer()
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 280)
        .onReceive(timer) { _ in
            guard appModel.isScanning, let startedAt = appModel.scanStartedAt else { return }
            elapsed = Date().timeIntervalSince(startedAt)
        }
    }

    private var progressFraction: Double {
        guard let progress = appModel.scanProgress, progress.total > 0 else { return 0 }
        return Double(progress.scanned) / Double(progress.total)
    }

    private var formattedElapsed: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: elapsed) ?? "0s"
    }
}
