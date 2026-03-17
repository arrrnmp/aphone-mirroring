# Scrcpy SwiftUI

A small macOS SwiftUI app that displays and interacts with an Android device screen using scrcpy.

### Prerequisites
- macOS 26 with the Xcode 26+
- Homebrew (https://brew.sh/)
- An Android device with USB debugging enabled

### Install dependencies
1. Install adb and scrcpy via Homebrew: `brew install android-platform-tools scrcpy`
2. Verify adb can see your device: `adb devices`

### Usage
1. Open `Scrcpy SwiftUI.xcodeproj` in Xcode.
2. Connect your Android device via USB and ensure USB debugging is allowed.
3. Build and run the app from Xcode (select your Mac as the run target).

### Notes
- The app relies on the scrcpy server and adb. If scrcpy fails to start, try running `scrcpy` from Terminal to confirm the environment is working.
- For wireless debugging, follow `adb tcpip` workflows and connect to the device's IP address.

### Troubleshooting
- If the app doesn't see the device, run `adb kill-server && adb start-server` and reconnect the device.
- If permissions are required for network or device access, grant them in System Settings.

### License
This project is provided under the terms of the existing LICENSE file in the repository.
