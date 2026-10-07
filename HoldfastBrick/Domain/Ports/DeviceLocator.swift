import Foundation
import Observation

/// Finds bricks on the local network during onboarding.
/// Bonjour in production, a canned device in previews/UI tests.
@MainActor
protocol DeviceLocator: AnyObject, Observable {
    var found: [DiscoveredBrick] { get }
    func start()
    func stop()
}
