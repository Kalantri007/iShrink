import SwiftUI
import AppKit
import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI" — `PermissionGateView`.
//
// First-run permission gate (R7): a pre-prompt explaining why iShrink needs
// full Photos access and that nothing leaves the Mac, then distinct copy
// for `.denied`/`.needsFullAccess` (Settings deep-link) versus `.restricted`
// (no deep-link — not user-resolvable). Reuses `AuthState.explanation` /
// `.canDeepLinkToSettings` from U2 rather than re-deriving that copy here.
// Foreground re-check (`NSApplication.didBecomeActiveNotification`) is
// wired at the app-root level (`iShrinkApp.swift`), calling
// `AppModel.refreshAuthorizationOnForeground()`.
struct PermissionGateView: View {
    @ObservedObject var appModel: AppModel
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("iShrink needs access to your Photos library")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            content

            Spacer()
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.authState {
        case .notDetermined:
            prePrompt
        case .authorized:
            // Transitional only — `AppModel` advances past `.permission`
            // the moment this state is observed, so this rarely renders.
            ProgressView()
        case .denied, .needsFullAccess:
            deniedOrNeedsFullAccess
        case .restricted:
            restricted
        }
    }

    private var prePrompt: some View {
        VStack(spacing: 16) {
            Text(
                "iShrink reads your library to scan storage usage, show a codec breakdown, and compress "
                    + "eligible photos to a folder you choose. Nothing is ever uploaded or sent off this Mac, "
                    + "and your Photos library is never modified."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)

            Button {
                isRequesting = true
                Task {
                    await appModel.requestPhotoAccess()
                    isRequesting = false
                }
            } label: {
                if isRequesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Continue")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)
        }
    }

    /// `.denied` and `.needsFullAccess` are user-resolvable via System
    /// Settings — `AuthState.canDeepLinkToSettings` is `true` for both.
    private var deniedOrNeedsFullAccess: some View {
        VStack(spacing: 16) {
            Text(appModel.authState.explanation)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            if appModel.authState.canDeepLinkToSettings {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Text("iShrink notices automatically once access is granted — no need to relaunch.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// `.restricted` (MDM/parental controls) is **not** user-resolvable —
    /// no Settings deep-link is offered, matching
    /// `AuthState.canDeepLinkToSettings == false` for this case.
    private var restricted: some View {
        VStack(spacing: 16) {
            Text(appModel.authState.explanation)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
    }
}

// MARK: - iCloud first-run question

/// One-time modal shown after Photos access is granted, asking whether
/// iCloud Photos is enabled (plan: "iCloud first-run question", R6). Kept
/// here rather than as its own file in `Views/` — it's a small, one-shot
/// piece of the permission-to-scan handoff, not a standalone screen in the
/// plan's Output Structure (which lists five specific view files).
struct ICloudQuestionView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Is iCloud Photos turned on for this Mac?")
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(
                "iShrink only ever processes photos that are already fully downloaded to this Mac. "
                    + "If iCloud Photos is on, some originals may still live only in iCloud — those are "
                    + "automatically skipped, never downloaded."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 380)

            HStack(spacing: 12) {
                Button("No, it's off") {
                    appModel.answerICloudQuestion(enabled: false)
                }
                Button("Yes, it's on") {
                    appModel.answerICloudQuestion(enabled: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 260)
    }
}

/// Persistent, dismissible banner shown on `AnalyticsDashboardView` and
/// `SelectionView` when the user answered "yes" to the iCloud question
/// (plan: sets expectations only — does not itself change exclusion logic,
/// which already skips non-local assets regardless of this banner).
struct ICloudBannerView: View {
    @Binding var isVisible: Bool

    var body: some View {
        if isVisible {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "icloud")
                Text("iCloud Photos is on — only originals already downloaded to this Mac will be scanned and compressed.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
