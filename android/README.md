# aPhone Mirroring (Android)

The Android companion app for [aPhone Mirroring](https://github.com/arrrnmp/aphone-mirroring) — a native macOS app that mirrors your Android device screen and bridges your phone's data to your Mac.

---

## What this app does

aPhone Mirroring (Android) runs a background service that exposes your phone's data over USB to the macOS companion app. It does not mirror the screen itself — that is handled by the scrcpy protocol on the Mac side.

### Features

- **Messages**: Real SMS/MMS threads and conversations; receive and send SMS replies from your Mac; mark threads as read
- **Call Log**: Full history with contact names, duration, call type (incoming/outgoing/missed)
- **Photos**: Paginated photo grid with thumbnails; open full-resolution images in Preview on Mac
- **Contacts**: Full contact book with phone, email, organization, notes, birthday, websites, addresses, and deep-links to third-party apps (Signal, WhatsApp, etc.)
- **Notifications**: Android notifications forwarded to macOS Notification Center with actionable reply support
- **Active Call Control**: Real-time call state pushed to Mac (ringing → active → ended); supports hangup, mute/unmute, and audio routing between phone and Mac
- **Bluetooth Discoverability**: Makes the phone discoverable on demand so the Mac can initiate HFP pairing for call audio routing

---

## Requirements

- Android 10 (API 29) or later
- USB debugging enabled on the device
- [aPhone Mirroring](https://github.com/arrrnmp/aphone-mirroring) installed on your Mac

---

## Build & Install

Open the project in Android Studio and run on your device, or build via CLI:

```bash
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

---

## Setup

1. Install the app on your Android device.
2. Grant all requested permissions (SMS, Contacts, Call Log, Photos, Phone State, Notifications).
3. Enable the **Notification Listener** in Android Settings → Apps → Special app access → Notification access → aPhone Mirroring.
4. Connect your device via USB with USB debugging enabled.
5. Launch **aPhone Mirroring** on your Mac — it detects the companion app automatically and starts the data bridge.

---

## Permissions

| Permission | Purpose |
|---|---|
| `READ_SMS`, `RECEIVE_SMS`, `SEND_SMS` | Read and send text messages |
| `READ_CONTACTS` | Access contact book |
| `READ_CALL_LOG`, `WRITE_CALL_LOG` | Access and update call history |
| `CALL_PHONE`, `ANSWER_PHONE_CALLS` | Place and answer calls |
| `READ_PHONE_STATE` | Detect call state changes (ringing, active, ended) |
| `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` | Access photos and videos |
| `POST_NOTIFICATIONS` | Show persistent foreground service notification |
| `FOREGROUND_SERVICE*` | Run background data bridge service |
| `BLUETOOTH_*` | Make phone discoverable for HFP pairing with Mac |
| `MODIFY_AUDIO_SETTINGS` | Route call audio between phone and Bluetooth |
| `INTERNET` | TCP socket for local USB data bridge |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Keep service alive during mirroring sessions |

---

## Troubleshooting

- **Data not loading on Mac**: Ensure the companion app is running (check the persistent notification). Try unplugging and reconnecting the USB cable.
- **Notifications not forwarding**: Verify Notification Listener access is enabled in Android Settings → Apps → Special app access → Notification access.
- **Call state not updating**: Grant Phone State permission and ensure Battery Optimization is disabled for the app.
- **Photos not showing**: Grant Media Images permission; on Android 13+ grant `READ_MEDIA_IMAGES` specifically.

---

## Architecture

See [CLAUDE.md](../CLAUDE.md) for a detailed breakdown of every component, the data bridge protocol, state management, and threading model.

---

## License

This project is provided under the terms of the LICENSE file in the repository.
