import SwiftUI
import iShrinkCore

/// App entry point. U1 scaffolding only: a minimal placeholder window.
/// The real permission → scan → analytics → selection → confirmation flow
/// (`PermissionGateView`, `ScanView`, `AnalyticsDashboardView`, ...) lands in
/// U8/U9, wired through `AppModel`.
@main
struct iShrinkApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderRootView()
        }
    }
}

/// Placeholder root view, replaced by the real UI flow in U8.
///
/// References `iShrinkCoreModule` only to prove the app target links against
/// the local `iShrinkCore` package (per plan: "App target depends on the
/// local iShrinkCore package").
private struct PlaceholderRootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("iShrink")
                .font(.title)
            Text("Core module linked: \(iShrinkCoreModule.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 400, minHeight: 300)
        .padding()
    }
}
