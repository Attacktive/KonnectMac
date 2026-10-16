<p align="center">
  <img src="KonnectMac/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="KonnectMac Icon">
</p>

<h1 align="center">KonnectMac</h1>

<p align="center">
  <strong>Connect your Android phone to your Mac.</strong><br>
  A native macOS KDE Connect client with in-app updates.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/KDE%20Connect-Protocol%20v7-green" alt="Protocol v7">
  <img src="https://img.shields.io/badge/license-GPL%20v3-blue" alt="GPL v3">
</p>

---

<!-- TODO: Add hero demo GIF here -->
<!-- <p align="center"><img src="assets/demo.gif" width="720" alt="KonnectMac Demo"></p> -->

## What is KonnectMac?

KonnectMac is a **native macOS menu bar app** that connects your Android phone to your Mac using the [KDE Connect](https://kdeconnect.kde.org/) protocol. It works with the official KDE Connect Android app (v1.34+) available on [Google Play](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) and [F-Droid](https://f-droid.org/packages/org.kde.kdeconnect_tp/).

Native Swift + AppKit + SwiftUI, with [Sparkle](https://sparkle-project.org/) for secure in-app updates.

## Download

📦 **[Download KonnectMac](https://github.com/Attacktive/KonnectMac/releases/latest)** (.dmg disk image, Apple silicon and Intel)

Open the disk image and drag **KonnectMac** into **Applications** before launching it.

> **Note:** Releases are ad-hoc signed, not Developer ID signed or notarized. macOS may block the first launch; only approve it in **System Settings → Privacy & Security** if you trust the download. Sparkle signatures authenticate update archives but do not remove Gatekeeper warnings.

Use **Check for Updates…** in the menu bar popover or **Preferences → About** to check manually. **Preferences → General → Updates** controls automatic checks; Sparkle asks for permission before enabling them and prompts before installing updates.

Existing installations without Sparkle need one manual installation of an updater-enabled release. Later releases can update in place.

## Features

| Feature | Description |
|---------|-------------|
| **Notification Mirroring** | See your phone notifications on your Mac with app icons and OTP auto-detection with one-tap copy |
| **Call Alerts** | Incoming/outgoing call notifications with automatic media pause and resume |
| **Clipboard Sync** | Bidirectional text sharing; image sharing with KDE Connect desktop peers that advertise `kdeconnect.clipboard.file` |
| **File Transfer** | Send and receive files over encrypted TLS — drag files to the menu bar icon |
| **Battery Monitor** | Phone battery level in the menu bar with low battery alerts |
| **Find My Phone** | Ring your phone from your Mac |
| **Ping** | Bidirectional ping to test connectivity |

Clipboard images are normalized to PNG and transferred over certificate-pinned TLS.
Image sync requires support on both peers; text sync remains available with text-only peers, including KDE Connect Android.
Copy image content rather than a file in Finder; inbound clipboard files are staged to temporary storage and applied to the pasteboard.

## Setup

### Requirements
- macOS 14 (Sonoma) or later
- [KDE Connect](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) on your Android phone
- Both devices on the same WiFi network (or connected via [Tailscale](https://tailscale.com/))

### Getting Started
1. **Install** KonnectMac and KDE Connect on your phone
2. **Launch** KonnectMac — the onboarding wizard guides you through permissions
3. **Pair** — your phone appears automatically, click to pair and verify the security key
4. **Done** — look for the antenna icon in your menu bar

### Discovery and reconnection

KonnectMac uses KDE Connect UDP identity announcements on port 1716 and mDNS (`_kdeconnect._udp.local`) service discovery for LAN discovery. When local Wi-Fi networks filter UDP broadcast packets, mDNS automatically locates nearby devices and triggers direct identity exchange. TCP connections use ports 1716-1764 independently, so discovery remains on 1716 even when another app occupies the preferred TCP port. Missing peer listening ports default to 1716, and obsolete saved ports below 1716 are ignored.

After a successful authenticated pairing, KonnectMac remembers the device's last known address and advertised listening port. On launch, wake, and network changes, it combines normal broadcast discovery with directed identity announcements and direct reconnect attempts for those known devices.

If your network filters broadcast traffic, use **Preferences → Devices → Connect by IP** once to reach the device directly. After the device is authenticated, KonnectMac stores that endpoint for later reconnect attempts. This fallback helps reconnect a known device; it cannot discover an unknown device whose broadcast announcements never reach the Mac.

### OTP/SMS Visibility (Android 15+)

Android 15 hides sensitive notification content from third-party apps. To enable OTP/SMS visibility for KDE Connect:

```bash
brew install android-platform-tools
adb shell appops set org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow
```

The onboarding wizard covers this as well.

## How It Works

```
Mac                              Phone
 │                                 │
 ├──── UDP Broadcast ────────────► │  Discovery (UDP port 1716)
 │ ◄──── TCP Connect ─────────────┤  Phone connects to Mac
 │                                 │
 ├──── TLS Handshake ────────────► │  Encrypted channel (self-signed certs)
 │ ◄──── Identity Exchange ───────┤  Both sides identify
 │                                 │
 ├──── Pair Request ─────────────► │  SHA256 verification key
 │ ◄──── Pair Accept ─────────────┤  Certificate pinned
 │                                 │
 │ ◄═══ Encrypted JSON Packets ══►│  Notifications, clipboard, files...
```

## Security

- **End-to-end TLS** on all channels (main connection, file transfers, icon downloads)
- **Certificate pinning** after pairing — rejects impersonators
- **SHA256 verification key** displayed during pairing for visual confirmation
- **App-specific keychain** — no login keychain prompts
- **No sensitive data in logs** — OTP codes, notification text, caller names, clipboard content are never logged

## Build from Source

```bash
git clone https://github.com/Attacktive/KonnectMac.git
cd KonnectMac
xcodebuild -project KonnectMac.xcodeproj -scheme KonnectMac -configuration Release build
```

Run the regression suite with:

```bash
xcodebuild -project KonnectMac.xcodeproj -scheme KonnectMac -destination 'platform=macOS' test
```

### Publishing releases

The release workflow runs on numeric version tags, with an optional `v` prefix, such as `v2.8` or `2.8.1`. It builds a universal macOS app, ad-hoc signs it, and publishes a DMG, a signed update ZIP, and `appcast.xml` to a GitHub Release. The numeric tag supplies both the app version and Sparkle build version; use increasing versions. Prerelease suffixes are not supported by this stable feed.

Before the first release, create a dedicated Sparkle signing key and configure the repository. No Apple Developer certificate is required:

```bash
mkdir -p build/sparkle
curl --fail --location \
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
  -o build/Sparkle-2.10.0.tar.xz
printf '%s  %s\n' \
  c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c \
  build/Sparkle-2.10.0.tar.xz | shasum -a 256 -c -
tar -xf build/Sparkle-2.10.0.tar.xz -C build/sparkle

build/sparkle/bin/generate_keys --account KonnectMac
gh variable set SPARKLE_PUBLIC_KEY --repo Attacktive/KonnectMac \
  --body "$(build/sparkle/bin/generate_keys --account KonnectMac -p)"
(
  umask 077
  key_dir=$(mktemp -d)
  trap 'rm -rf "$key_dir"' EXIT
  build/sparkle/bin/generate_keys --account KonnectMac -x "$key_dir/private-key"
  gh secret set SPARKLE_PRIVATE_KEY --repo Attacktive/KonnectMac < "$key_dir/private-key"
)
```

`SPARKLE_PUBLIC_KEY` is a repository **Actions variable**, not a secret. `SPARKLE_PRIVATE_KEY` is a repository **Actions secret**. Keep a secure backup of the private key: losing or replacing it can strand existing ad-hoc-signed installations on their old update key. Never commit the private key or paste it into an issue or pull request.

The workflow refuses to build or publish with missing or mismatched keys. The app embeds the public key and reads its feed from `https://github.com/Attacktive/KonnectMac/releases/latest/download/appcast.xml`. Source builds without `SPARKLE_PUBLIC_KEY` disable update controls; supply that Xcode build setting to enable them. `SPARKLE_FEED_URL` can override the feed for local development.

To exercise the same packaging path locally without publishing, set `SPARKLE_PUBLIC_KEY` and `SPARKLE_PRIVATE_KEY` in the environment and run:

```bash
./scripts/package-release.sh \
  --version 2.8 \
  --tag v2.8 \
  --sparkle-bin "$PWD/build/sparkle/bin"
```

Artifacts appear in `build/artifacts/`. The script checks the embedded versions, feed, public key, architecture slices, app signature, and update ZIP signature before exposing the finished artifacts. Keep the Sparkle package version, workflow tool version/checksum, and setup commands above in sync when upgrading Sparkle.


<details>
<summary><strong>Architecture</strong></summary>

```
KonnectMac/
├── KonnectMacApp.swift          — App entry, menu bar, onboarding
├── OnboardingView.swift         — First-launch setup wizard
├── PreferencesView.swift        — Settings: General, Devices, About
├── MenuBarView.swift            — Menu bar popover UI
├── Core/
│   ├── NetworkPacket.swift      — JSON packet serialization
│   ├── Config.swift             — UserDefaults, capabilities, identity
│   ├── Device.swift             — Device model
│   ├── DeviceManager.swift      — Discovery, connections, pairing
│   ├── CertificateManager.swift — TLS certificate generation & keychain
│   └── Logger.swift             — Thread-safe file logging with rotation
├── Network/
│   ├── UDPDiscovery.swift       — BSD socket UDP broadcast
│   ├── LanServer.swift          — BSD socket TCP server
│   ├── KDEConnection.swift      — Full TLS connection lifecycle
│   └── VerificationKeyHelper.swift — SHA256 pairing verification
├── Pairing/
│   └── PairingHandler.swift     — Pairing state machine & verification
└── Plugins/
    ├── PluginProtocol.swift     — Plugin interface
    ├── PingPlugin.swift         — Bidirectional ping
    ├── BatteryPlugin.swift      — Battery level & alerts
    ├── NotificationPlugin.swift — Notification mirroring & OTP detection
    ├── TelephonyPlugin.swift    — Call alerts & media control
    ├── ClipboardPlugin.swift    — Clipboard sync
    ├── FindMyPhonePlugin.swift  — Ring phone
    └── SharePlugin.swift        — File transfer
```

</details>

<details>
<summary><strong>Tech Stack</strong></summary>

| Component | Choice | Why |
|-----------|--------|-----|
| Language | Swift 5.9+ | Native, fast, type-safe |
| UI | SwiftUI + AppKit | SwiftUI for views, AppKit for menu bar & windows |
| Networking | BSD Sockets | Network.framework can't do TLS startTLS |
| TLS | SecureTransport | Ships with macOS, no dependencies |
| Certificates | openssl CLI + Keychain | Self-signed RSA-2048, app-specific keychain |
| Media Control | MediaRemote (private) | Only way to pause/resume without Accessibility |
| Updates | Sparkle | Signed update archives and standard update prompts |

</details>

## Branches

| Branch | Purpose |
|--------|---------|
| `stable` | Production releases |
| `beta` | Testing builds |
| `alpha` | Active development |

## Support Me

I built this in my free time because I wanted a proper Mac + Android experience. If KonnectMac is useful to you, a small sponsorship means a lot — it keeps development going.

<a href="https://github.com/sponsors/aryarajsingh"><img src="https://img.shields.io/badge/Sponsor-♥_Support_Me-ea4aaa?style=for-the-badge&logo=github" alt="Sponsor"></a>

## License

KonnectMac is open source under the [GNU General Public License v3.0](LICENSE).
You are free to view, modify, and build from source.

Copyright © 2026 Aryaraj Singh.

---

<p align="center">
  Built with care for the Mac.
</p>
