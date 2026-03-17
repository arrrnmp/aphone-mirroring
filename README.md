# PhoneConnect

PhoneConnect is an Android project skeleton for building device connection and communication features.

## Requirements

### Hardware
- Android device (phone or tablet) with USB debugging enabled
- USB cable (for initial setup, if needed)

### Software
- Android Studio (Giraffe or newer recommended)
- Android SDK 36+
- Gradle (wrapper included)
- Java 11+

### Project Setup
- Clone this repository: `git clone https://github.com/arrrnmp/phoneconnect.git`
- Open in Android Studio
- Let Gradle sync and download dependencies
- Minimum SDK: 36
- Target SDK: 36

### Permissions & Features

PhoneConnect requests a range of permissions to enable seamless integration with the companion Swift macOS app (features in progress):

| Permission | Why Needed / Feature |
|------------|---------------------|
| Ignore Battery Optimizations | Keep connection alive in background for uninterrupted sync |
| Notification Access | Mirror Android notifications instantly to your Mac |
| Bluetooth (Scan/Advertise/Connect) | Auto-pair and connect to Mac for proximity-based features |
| Overlay (Draw over apps) | Show floating controls and alerts on Android while connected |
| Microphone | Bridge call audio and voice to your Mac |
| Location | Enable Find My Phone and location-based triggers from Mac |
| Gallery/Media | Share photos/videos between Android and Mac |
| Phone/Contacts/Call Log | View, sync, and initiate calls from your Mac |
| SMS | Read/send SMS from your Mac desktop |
| Camera | Use phone camera as webcam or for document scanning on Mac |
| Post Notifications | Show connection status and alerts on Android |


## Getting Started
- Build and run the app on your device or emulator
- Use the project as a base for your own device connection features

## License
See LICENSE file for details.
