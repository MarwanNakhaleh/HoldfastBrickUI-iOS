import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    let locator: any DeviceLocator

    var body: some View {
        switch appModel.phase {
        case .needsDevice:
            DiscoveryView(locator: locator)
        case let .pairing(brick):
            PairingView(brick: brick)
        case .connected:
            DashboardView()
        }
    }
}
