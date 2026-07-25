import SwiftUI
import AppKit
import iShrinkCore

/// App entry point. U1 shipped a placeholder window; U8 wires it to the
/// real permission → scan → analytics → selection → confirmation flow,
/// routed through `AppModel`'s `Stage`.
@main
struct iShrinkApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Plan U8: "Re-check authorization on app foreground" —
                    // a user who grants Photos access in System Settings
                    // advances past the permission gate without relaunching.
                    appModel.refreshAuthorizationOnForeground()
                }
        }
    }
}

/// Routes to one of the five U8 screens based on `AppModel.stage`, and
/// presents the one-time iCloud first-run question as a sheet over
/// whichever screen is current when it's triggered.
struct RootView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Group {
            switch appModel.stage {
            case .permission:
                PermissionGateView(appModel: appModel)
            case .scanning:
                ScanView(appModel: appModel)
            case .analytics:
                AnalyticsDashboardView(appModel: appModel)
            case .selection:
                SelectionView(appModel: appModel)
            case .confirmation:
                ConfirmationView(appModel: appModel)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $appModel.showICloudQuestion) {
            ICloudQuestionView(appModel: appModel)
        }
    }
}
