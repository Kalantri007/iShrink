import SwiftUI
import iShrinkCore

// iShrink Phase 1 plan, U9 "App UI" — `ReportView`.
//
// Renders the post-run `CompressionReport` (R12) and offers the two
// post-report actions the plan calls for: reveal the output folder in
// Finder, and start another selection. All report math (totals, ratio,
// per-type breakdown, largest savers, the all-failed/zero-success case)
// lives in `CompressionReport` (Core, unit-tested) — this view only
// formats and lays it out.
//
// GPS export gating (R12): the "include GPS in export" affordance is a
// button that opens an explicit confirmation dialog, never a bare toggle —
// `AppModel.requestIncludeGPSInExport()`/`confirmIncludeGPSInExport()`
// enforce that; this view just presents the resulting state.
struct ReportView: View {
    @ObservedObject var appModel: AppModel
    @State private var showExportSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let report = appModel.compressionReport {
                    if report.isZeroSuccess {
                        failureSummary(report)
                    } else {
                        successSummary(report)
                        perTypeBreakdown(report)
                        largestSavers(report)
                    }
                    if !report.failures.isEmpty {
                        failuresList(report)
                    }
                    gpsExportSection
                } else {
                    Text("No report available.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                actions
            }
            .padding(32)
        }
        .frame(minWidth: 520, minHeight: 480)
        .confirmationDialog(
            "Include exact photo locations?",
            isPresented: $appModel.showGPSExportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Include Locations", role: .destructive) {
                appModel.confirmIncludeGPSInExport()
            }
            Button("Cancel", role: .cancel) {
                appModel.cancelIncludeGPSInExportRequest()
            }
        } message: {
            Text("This report will include exact photo locations — continue?")
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
        }
    }

    // MARK: - Explicit all-failed / zero-success state (not success-styled)

    @ViewBuilder
    private func failureSummary(_ report: CompressionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Compression failed", systemImage: "xmark.octagon.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("All \(report.failures.count) item(s) failed to compress. No output was produced.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Success summary

    @ViewBuilder
    private func successSummary(_ report: CompressionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Compression complete", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)

            Text("\(report.succeededItems.count) item(s) compressed, saved \(byteString(report.totalSavedBytes)).")
                .font(.headline)

            if let ratio = report.compressionRatio {
                Text("Output is \(Int((ratio * 100).rounded()))% of the original size.")
                    .foregroundStyle(.secondary)
            }

            if report.excludedCount > 0 {
                Text("\(report.excludedCount) item(s) were excluded and not attempted.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func perTypeBreakdown(_ report: CompressionReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By type").font(.headline)
            ForEach(Array(report.byCodec.keys).sorted(by: { "\($0)" < "\($1)" }), id: \.self) { codec in
                if let breakdown = report.byCodec[codec] {
                    HStack {
                        Text(String(describing: codec)).frame(width: 80, alignment: .leading)
                        Text("\(breakdown.count) item(s)")
                        Spacer()
                        Text("saved \(byteString(breakdown.savedBytes))")
                    }
                    .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func largestSavers(_ report: CompressionReport) -> some View {
        let top = report.largestSavers(limit: 5)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Largest savers").font(.headline)
                ForEach(top, id: \.localIdentifier) { item in
                    HStack {
                        Text(item.filename).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(byteString(item.savedBytes)).foregroundStyle(.green)
                    }
                    .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func failuresList(_ report: CompressionReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Failures").font(.headline)
            ForEach(report.failures, id: \.localIdentifier) { failure in
                HStack {
                    Text(failure.filename).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(failure.errorCode).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    // MARK: - GPS export section (R12)

    private var gpsExportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Report export").font(.headline)
            if appModel.gpsIncludedInExport {
                Label("Exact photo locations will be included in the export.", systemImage: "location.fill")
                    .foregroundStyle(.orange)
                Button("Exclude Locations") {
                    appModel.excludeGPSFromExport()
                }
            } else {
                Label("Exact photo locations are excluded from the export by default.", systemImage: "location.slash")
                    .foregroundStyle(.secondary)
                Button("Include Exact Locations…") {
                    appModel.requestIncludeGPSInExport()
                }
            }
        }
    }

    // MARK: - Post-report actions

    private var actions: some View {
        HStack {
            Button("Reveal Output Folder") {
                appModel.revealOutputInFinder()
            }
            Button("Export Report…") {
                showExportSheet = true
            }
            Spacer()
            Button("Start Another Selection") {
                appModel.startAnotherSelectionAfterReport()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exported Report").font(.headline)
            ScrollView {
                Text(appModel.exportedReportText ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { showExportSheet = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 420)
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
