# aPhone Mirroring

A native macOS app that mirrors your Android device screen and bridges your phone's data — messages, calls, photos, contacts, and notifications — directly to your Mac.

Built on the [scrcpy](https://github.com/Genymobile/scrcpy) protocol (v3.3.4) for mirroring, with a custom TCP data bridge to a companion Android service for real phone data.

---

## Features

### Screen Mirroring
- H.264 hardware-accelerated video over USB (scrcpy v3.3.4)
- PCM audio streamed in real-time with zero silence gaps
- Full input forwarding: keyboard, mouse, trackpad gestures, scroll
- File drag-and-drop: APKs install automatically, other files push to Downloads
- Pop-out phone window with aspect-ratio locking and rotation support
- Hardware control buttons: Back, Home, Recents, Volume, Mute, Power, Rotate

### Real Phone Data (via DataBridgeService companion app)
- **Messages**: Real SMS/MMS threads and conversations, send SMS replies, mark as read
- **Calls**: Full call log with contact names, duration, and call type
- **Photos**: Paginated photo grid with real thumbnails; open full-res in Preview
- **Contacts**: Full contact book with phone, email, organization, social apps
- **Notifications**: Android notifications delivered to macOS Notification Center with actionable reply support
- **Active Call UI**: Floating Liquid Glass call window with mute, end, and audio-routing controls

### Bluetooth & Audio
- Automatic Bluetooth pairing detection via `system_profiler` (HFP for call audio; IOBluetooth is not used — removed on macOS 26)
- Prompts user to pair if not already paired; polls for completion
- Route call audio between Mac and phone during active calls

### macOS Integration
- Menu bar battery status with charging indicator
- Biometric/password auth gating for the data panel (locks after 2 min inactivity)
- Screenshot capture to Desktop with shutter sound and thumbnail preview
- Bidirectional clipboard sync (text)
- Always-on-top pin mode

---

## Requirements

- macOS 26.2 or later
- Xcode 26+
- Android device with USB debugging enabled
- `adb` installed (`brew install android-platform-tools`)
- `scrcpy` installed (`brew install scrcpy`) — provides `scrcpy-server` used for mirroring
- [PhoneConnect](https://github.com/arrrnmp/phoneconnect) companion app installed on Android (for data bridge features)

---

## Install dependencies

```bash
brew install android-platform-tools
brew install scrcpy
```

Verify ADB can see your device:

```bash
adb devices
```

---

## Build & Run

Open `macos/aPhone Mirroring.xcodeproj` in Xcode, select your Mac as the run destination, and build.

Or via CLI:

```bash
cd macos
xcodebuild -scheme "Scrcpy SwiftUI" -configuration Debug -destination 'platform=macOS' build
```

---

## Usage

1. Connect your Android device via USB and allow USB debugging.
2. Launch aPhone Mirroring — it will detect the device automatically.
3. Tap **Connect** to start mirroring.
4. Install the **PhoneConnect** companion app on Android to enable Messages, Calls, Photos, Contacts, and Notifications.

---

## Troubleshooting

- **Device not detected**: Run `adb kill-server && adb start-server`, reconnect the device.
- **No audio**: Ensure the device allows audio over USB. The audio engine restarts automatically if you switch output devices (headphones, Bluetooth speakers, etc.) while mirroring. If audio still doesn't recover, disconnect and reconnect the device.
- **Data bridge not connecting**: Make sure the PhoneConnect companion app is running on Android and USB is connected. The bridge auto-retries with exponential backoff.
- **Bluetooth pairing fails**: Make the Android device discoverable manually before tapping "Pair Now."

---

## Architecture

See [CLAUDE.md](../CLAUDE.md) for a detailed breakdown of every component, the scrcpy protocol, data bridge protocol, state management patterns, and UI design rules.

---

## License

This project is provided under the terms of the LICENSE file in the repository.
