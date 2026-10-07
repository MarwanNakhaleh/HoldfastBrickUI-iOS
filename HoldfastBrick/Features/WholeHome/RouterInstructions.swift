import Foundation

/// Short, vendor-specific "turn off your router's DHCP" steps shown in the
/// Whole-Home Protection blocker, keyed by the `vendor_key` the brick detects.
enum RouterInstructions {
    static let steps: [RouterVendor: [String]] = [
        .xfinity: [
            "Open the Xfinity app — these settings aren't on the web portal.",
            "Go to WiFi → Advanced Settings → DHCP.",
            "Turn the DHCP server off, then come back here and check again.",
        ],
        .netgear: [
            "Open your router's admin page with the link below.",
            "Go to Advanced → Setup → LAN Setup.",
            "Uncheck “Use Router as DHCP Server”, apply, then check again.",
        ],
        .tplink: [
            "Open your router's admin page with the link below.",
            "Go to Advanced → Network → DHCP Server.",
            "Turn the DHCP server off, save, then check again.",
        ],
        .eero: [
            "Open the eero app.",
            "Go to Settings → Advanced → DHCP & NAT.",
            "Turn off eero's DHCP, then come back here and check again.",
        ],
        .asus: [
            "Open your router's admin page with the link below.",
            "Go to LAN → DHCP Server.",
            "Set “Enable the DHCP Server” to No, apply, then check again.",
        ],
        .verizon: [
            "Open your router's admin page with the link below.",
            "Go to Advanced → Network Settings → IPv4 LAN / DHCP.",
            "Turn the DHCP server off, save, then check again.",
        ],
        .att: [
            "Open your gateway's admin page with the link below.",
            "Go to Settings → LAN → DHCP.",
            "Turn DHCP off, save, then check again.",
        ],
        .unknown: [
            "Open your router's admin page with the link below.",
            "Look for LAN or DHCP Server settings — usually under Advanced.",
            "Turn the DHCP server off, save, then check again.",
        ],
    ]

    static func steps(for vendor: RouterVendor) -> [String] {
        steps[vendor] ?? steps[.unknown]!
    }
}
