# aPhone Mirroring

Mirror your Android device screen on your Mac and access your messages, calls, photos, contacts, and notifications — all in a native macOS interface.

Built on the [scrcpy](https://github.com/Genymobile/scrcpy) protocol (v3.3.4) for hardware-accelerated screen mirroring, with a custom TCP data bridge to a companion Android service for real phone data.

---

## Repositories

| Platform | Location | Description |
|---|---|---|
| macOS | [`macos/`](macos/) | Native SwiftUI app — screen mirroring, UI, data bridge client |
| Android | [`android/`](android/) | Companion service — DataBridgeService, SMS/calls/photos/contacts |

---

## Quick Start

### Requirements
- macOS 26.2 or later, Xcode 26+
- Android 10 (API 29) or later
- USB debugging enabled on the Android device
- `adb` installed (`brew install android-platform-tools`)
- `scrcpy` installed (`brew install scrcpy`) — the app uses the `scrcpy-server` binary from your Homebrew installation

### Build & run

```bash
# macOS app
make build-macos

# Android companion app (builds + installs via adb)
make install-android

# Verify adb can see your device
make check-device
```

### Manual build

```bash
# macOS
cd macos
xcodebuild -scheme "Scrcpy SwiftUI" -configuration Debug -destination 'platform=macOS' build

# Android
cd android
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

---

## How it works

1. Connect your Android device via USB and allow USB debugging.
2. Launch **aPhone Mirroring** on your Mac — it detects the device and starts mirroring automatically.
3. Install the Android companion app to unlock Messages, Calls, Photos, Contacts, and Notifications.

See [`macos/CLAUDE.md`](macos/CLAUDE.md) for the full architecture, protocol details, and UI design rules.

---

## DataBridge Protocol

Both apps implement the same TCP data bridge on port **27184** (forwarded via `adb forward`). The protocol uses newline-delimited JSON:

- Bootstrap: `{"type":"ping"}` → `{"type":"pong"}`
- Requests: `get_threads`, `get_messages`, `get_calls`, `get_photos`, `get_contacts`, `send_sms`, `place_call`, `call_action`, …
- Push events from Android: `new_sms`, `new_call`, `call_state`, `push_notification`

Changes to the protocol require coordinated updates to both `macos/` and `android/`.

---

## License

See [LICENSE](macos/LICENSE).
