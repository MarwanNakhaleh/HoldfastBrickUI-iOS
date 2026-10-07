# HoldfastBrickUI-iOS

The iOS app for **Holdfast** — a Raspberry Pi plugged into your router that
blocks ads and trackers for every device on your network. The app speaks
directly to the [HoldfastBrick API](https://github.com/MarwanNakhaleh/HoldfastBrickAPI)
running **on the Pi itself**: no cloud, no account, no centralized server.

Built for a technical layperson: services appear as "Ad Blocking", "Private
DNS", "Remote Access" — never `unbound` or `tailscaled`.

## Quick start

```bash
brew install xcodegen        # once
xcodegen generate
open HoldfastBrick.xcodeproj
```

Select the HoldfastBrick scheme and run. Requires Xcode 15+ / iOS 17+.

**Try it with no Raspberry Pi:** add `-mockAPI` to the scheme's launch
arguments (Edit Scheme → Run → Arguments). The app runs against an in-memory
brick — instant discovery, pairing code **123456**, working toggles, sample
stats. The same flag drives the UI tests.

## How connection works (the part worth knowing)

1. **First run:** the app finds the Pi over Bonjour (`_holdfastbrick._tcp`) on
   your WiFi — you never type an IP.
2. **Pairing:** enter the 6-digit code from `holdfastbrick-pair` on the Pi.
   The app gets a bearer token (kept in the Keychain) and immediately asks the
   Pi for its Tailscale addresses.
3. **Ever after:** every request goes through `EndpointResolver`, which probes
   **Tailscale first** (MagicDNS name → Tailscale IP → last-known LAN address)
   and uses whichever answers. Home or away, same app, zero switches — with
   the Tailscale VPN active on the phone, remote just works.

## Architecture

```
HoldfastBrick/
├── App/               # Composition root (the one place that knows concrete types)
├── Domain/            # Pure Swift: models + ports (BrickAPI, TokenStore, DeviceLocator)
├── Features/          # One folder per user-facing feature (@Observable models + SwiftUI)
│   ├── Onboarding/    #   discovery + pairing
│   ├── Dashboard/     #   "You're protected" + service cards
│   ├── AdBlocking/    #   toggle, stats, recent activity, blocklists
│   ├── PrivateDNS/    #   Unbound + DoH status, cache flush
│   ├── RemoteAccess/  #   Tailscale status + peers
│   ├── CloudFiltering/#   NextDNS
│   ├── NetworkMonitor/#   devices on the network (ntopng)
│   └── Device/        #   health, reboot, unpair
└── Infrastructure/    # Details behind the ports: HTTP client, EndpointResolver,
                       # Bonjour, Keychain, and the -mockAPI in-memory brick
```

Domain contains no SwiftUI/URLSession imports; features depend on the
`BrickAPI` protocol and receive it from the composition root — which is what
makes the mock, previews, and tests cheap.

## Tests

- **Unit** (`HoldfastBrickTests`): endpoint-resolution ordering and fallback,
  wire-contract decoding fixtures, pairing/session state machine.
- **UI smoke** (`HoldfastBrickUITests`): discovery → pairing → dashboard →
  Ad Blocking against the mock brick; wrong-code error path.

Run both with ⌘U, or:

```bash
xcodebuild test -project HoldfastBrick.xcodeproj -scheme HoldfastBrick \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Evening test checklist (with a real Pi)

1. Pi provisioned (`sudo bash deploy/provision.sh` in the API repo) and on the
   same network; `holdfastbrick-pair` run on the Pi.
2. App: device appears < 5 s → pair with the printed code → dashboard.
3. Toggle Ad Blocking off/on; check the card and AdGuard react.
4. Open Recent Activity; block a domain via swipe; verify it's then blocked.
5. Add + remove a blocklist.
6. Turn phone WiFi off (cellular + Tailscale VPN on) → pull to refresh →
   dashboard still loads.
7. Device screen → Restart → confirm it comes back.
