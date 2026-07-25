import SwiftUI
import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI" — `AnalyticsDashboardView`.
//
// The savings estimate is the **primary** element (the low-disk user's
// headline), with codec breakdown, totals, and largest files as secondary
// detail. Excluded assets are shown as a **count-per-reason summary**,
// driven by `ExclusionReason.displayText` (the copy table added to Core in
// this unit) rather than any reason-to-string logic living in this view.
struct AnalyticsDashboardView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if appModel.showICloudBanner {
                    ICloudBannerView(isVisible: $appModel.showICloudBanner)
                }

                headline

                if let analytics = appModel.analytics {
                    codecBreakdownSection(analytics)
                    largestFilesSection(analytics)
                    exclusionSummarySection(analytics)
                }

                Button("Choose What to Compress") {
                    appModel.proceedToSelection()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - Primary element: savings estimate

    @ViewBuilder
    private var headline: some View {
        if let estimate = appModel.savingsEstimate {
            VStack(alignment: .leading, spacing: 4) {
                Text("Estimated savings")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("\(byteString(estimate.savingsBytesLow)) – \(byteString(estimate.savingsBytesHigh))")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Secondary detail

    private func codecBreakdownSection(_ analytics: StorageAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codec breakdown").font(.headline)
            ForEach(analytics.codecBreakdown, id: \.codec) { entry in
                HStack {
                    Text(codecName(entry.codec))
                    Spacer()
                    Text("\(entry.count) items")
                        .foregroundStyle(.secondary)
                    Text(byteString(entry.bytes))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            Divider()
            Text("Total: \(analytics.totalCount) items, \(byteString(analytics.totalBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func largestFilesSection(_ analytics: StorageAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Largest files").font(.headline)
            if analytics.largestFiles.isEmpty {
                Text("No files to show.").foregroundStyle(.secondary)
            } else {
                ForEach(analytics.largestFiles, id: \.localIdentifier) { file in
                    HStack {
                        Text(file.originalFilename ?? file.localIdentifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(byteString(file.bytes))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Excluded assets as a **count-per-reason summary** (plan): every
    /// `ExclusionReason` with a non-zero count, in enum declaration order,
    /// using its `displayText` copy.
    private func exclusionSummarySection(_ analytics: StorageAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Excluded from compression").font(.headline)
            let nonZeroReasons = ExclusionReason.allCases.filter { (analytics.excludedCountByReason[$0] ?? 0) > 0 }
            if nonZeroReasons.isEmpty {
                Text("Nothing excluded.").foregroundStyle(.secondary)
            } else {
                ForEach(nonZeroReasons, id: \.self) { reason in
                    HStack {
                        Text(reason.displayText)
                        Spacer()
                        Text("\(analytics.excludedCountByReason[reason] ?? 0)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func codecName(_ codec: MediaCodec) -> String {
        switch codec {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .rawOrProRaw: return "RAW / ProRAW"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .otherVideo: return "Other video"
        case .unknown: return "Unknown"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
