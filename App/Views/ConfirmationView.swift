import SwiftUI
import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI" — `ConfirmationView`.
//
// Mandatory gate (R8): item count, current size → estimated size, estimated
// savings for the **selected subset** (via `SelectionRules.
// confirmationSummary`, never the whole-library number from the analytics
// screen), and the output-folder picker. Nothing runs until the user picks
// a destination and confirms — the "Start Compression" action itself is a
// stub here; wiring it to `CompressionPipeline` is U9's job.
//
// Destination validation is delegated entirely to `DestinationValidator`
// (Core, unit-tested): a rejected (unwritable) destination blocks Start
// outright; a cloud-sync destination requires an explicit acknowledgement
// checkbox before Start enables (R13 egress risk); low free space is shown
// as a non-blocking warning.
struct ConfirmationView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Confirm compression")
                .font(.title2)
                .fontWeight(.semibold)

            if appModel.selection.isEmpty {
                zeroItemMessage
            } else {
                summarySection
                destinationSection
            }

            Spacer()

            HStack {
                Button("Back") {
                    appModel.backToSelection()
                }
                Spacer()
                if !appModel.selection.isEmpty {
                    Button("Start Compression") {
                        // U9's territory: wiring this to
                        // `CompressionPipeline` and `CompressionRunView`.
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appModel.canStartCompression)
                }
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 440)
    }

    /// Distinct zero-item copy (plan: "'filter matches nothing' vs
    /// 'library has nothing compressible' read differently") — read
    /// verbatim from `SelectionRules.ZeroSelectionReason`, the same source
    /// `SelectionView` uses, so the two screens never disagree.
    @ViewBuilder
    private var zeroItemMessage: some View {
        if let reason = appModel.zeroSelectionReason {
            Text(reason.message).foregroundStyle(.secondary)
        } else {
            Text("Nothing is selected.").foregroundStyle(.secondary)
        }
    }

    private var summarySection: some View {
        let confirmation = appModel.confirmationSummary
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(confirmation.itemCount) items")
                .font(.headline)
            Text(
                "\(byteString(confirmation.currentBytes)) → "
                    + "\(byteString(confirmation.estimate.estimatedBytesLow))–"
                    + "\(byteString(confirmation.estimate.estimatedBytesHigh))"
            )
            Text(
                "Estimated savings: \(byteString(confirmation.estimate.savingsBytesLow))–"
                    + "\(byteString(confirmation.estimate.savingsBytesHigh))"
            )
            .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output folder").font(.headline)

            HStack {
                Text(appModel.destinationURL?.path ?? "No folder chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(appModel.destinationURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose Folder…") {
                    appModel.chooseDestination()
                }
            }

            if let validation = appModel.destinationValidation {
                validationMessages(validation)
            }
        }
    }

    @ViewBuilder
    private func validationMessages(_ validation: DestinationValidation) -> some View {
        if validation.isRejected {
            Label("This folder isn't writable. Choose another.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        } else {
            if validation.isLowOnFreeSpace {
                Label("Low free space on this volume.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if validation.requiresCloudSyncAcknowledgement {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "This folder syncs to the cloud (iCloud Drive, Dropbox, or OneDrive). Output photos "
                            + "carry GPS/EXIF data and would be uploaded there automatically.",
                        systemImage: "exclamationmark.icloud.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    Toggle("I understand and want to continue anyway", isOn: $appModel.cloudSyncAcknowledged)
                }
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
