.PHONY: build-macos build-android install-android check-device setup logs-android clean-android

# macOS app
build-macos:
	cd macos && xcodebuild -scheme "Scrcpy SwiftUI" -configuration Debug -destination 'platform=macOS' build

# Android companion app
build-android:
	cd android && ./gradlew assembleDebug

install-android: build-android
	adb install -r android/app/build/outputs/apk/debug/app-debug.apk

# Utilities
check-device:
	adb devices

logs-android:
	adb logcat -s DataBridgeService:* aPhoneMirroring:*

setup:
	@command -v adb >/dev/null 2>&1 || (echo "Installing android-platform-tools..." && brew install android-platform-tools)
	@echo "ADB version: $$(adb version | head -1)"
	@adb devices

clean-android:
	cd android && ./gradlew clean
