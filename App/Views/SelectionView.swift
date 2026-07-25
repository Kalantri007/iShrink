import SwiftUI
import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI" — `SelectionView`.
//
// Starts from the smart default (all `.compressible`) and layers
// rule-based filters (type, size threshold, age) on top. All filter/
// predicate logic lives in `SelectionRules` (Core, unit-tested) — this
// view only tracks the filter control state and forwards it to `AppModel`,
// which re-applies `SelectionRules.apply` and republishes `selection`. Zero-
// item copy is read straight from `SelectionRules.ZeroSelectionReason`, not
// re-worded here, so this screen and `ConfirmationView` never disagree
// about why nothing is selected.
struct SelectionView: View {
    @ObservedObject var appModel: AppModel

    @State private var minimumSizeMB: Double = 0
    @State private var ageYears: Double = 0
    @State private var typeFilter: TypeFilterOption = .any

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if appModel.showICloudBanner {
                ICloudBannerView(isVisible: $appModel.showICloudBanner)
            }

            Text("Select photos to compress")
                .font(.title2)
                .fontWeight(.semibold)

            filterControls

            statusLine

            Spacer()

            HStack {
                Button("Back") {
                    appModel.backToAnalytics()
                }
                Spacer()
                Button("Review & Confirm") {
                    appModel.proceedToConfirmation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.selection.isEmpty)
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 420)
        .onChange(of: minimumSizeMB) { _ in applyFilter() }
        .onChange(of: ageYears) { _ in applyFilter() }
        .onChange(of: typeFilter) { _ in applyFilter() }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Type", selection: $typeFilter) {
                ForEach(TypeFilterOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            HStack {
                Text("Minimum size")
                    .frame(width: 110, alignment: .leading)
                Slider(value: $minimumSizeMB, in: 0...200)
                Text(minimumSizeMB == 0 ? "Any size" : "\(Int(minimumSizeMB)) MB")
                    .frame(width: 70, alignment: .trailing)
            }

            HStack {
                Text("Older than")
                    .frame(width: 110, alignment: .leading)
                Slider(value: $ageYears, in: 0...10)
                Text(ageYears == 0 ? "Any age" : "\(Int(ageYears)) yrs")
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let reason = appModel.zeroSelectionReason {
            // Distinct copy per `ZeroSelectionReason` case (plan: "these
            // must read differently") — read verbatim from Core.
            Text(reason.message)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            Text("\(appModel.selection.count) items selected")
                .font(.headline)
        }
    }

    private func applyFilter() {
        var filter = SelectionFilter()
        if minimumSizeMB > 0 {
            filter.minimumBytes = Int64(minimumSizeMB * 1_000_000)
        }
        if ageYears > 0, let cutoff = Calendar.current.date(byAdding: .year, value: -Int(ageYears), to: Date()) {
            filter.createdBefore = cutoff
        }
        if let codecs = typeFilter.codecs {
            filter.codecs = codecs
        }
        appModel.selectionFilter = filter
        appModel.updateSelection()
    }
}

/// Coarse "type" filter offered by the UI, translated to a `MediaCodec` set
/// for `SelectionFilter`. Kept small deliberately — Phase 1's compressible
/// set is JPEG/PNG only (`MediaClassifier` never marks anything else
/// `.compressible`), so a handful of options covers the real space without
/// exposing codecs that could never actually be selected.
enum TypeFilterOption: String, CaseIterable, Identifiable {
    case any = "Any Type"
    case jpeg = "JPEG"
    case png = "PNG"

    var id: String { rawValue }

    var codecs: Set<MediaCodec>? {
        switch self {
        case .any: return nil
        case .jpeg: return [.jpeg]
        case .png: return [.png]
        }
    }
}
