# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## gstack

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.

Available skills: `/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`

## Project Overview

A native macOS SwiftUI application that mirrors Android device screens over USB using the scrcpy protocol (v3.3.4). Handles H.264 video streaming, PCM audio streaming, hardware-accelerated decoding, and full input forwarding (keyboard, mouse, touch, scroll, gesture simulation).

## Build

Open `aPhone Mirroring/aPhone Mirroring.xcodeproj` in Xcode, or build via CLI:

```bash
cd "aPhone Mirroring"
xcodebuild -scheme "Scrcpy SwiftUI" -configuration Debug build
xcodebuild -scheme "Scrcpy SwiftUI" -configuration Release build
```

- **Deployment target**: macOS 26.2
- **Swift version**: 5.0
- No tests, no linting tools, no third-party dependencies — all system frameworks only.

## Architecture

All source files are in `aPhone Mirroring/aPhone MIrroring/`.

**Key components and their roles:**

| File | Role |
|------|------|
| `ScrcpyManager.swift` | Main orchestrator (`@MainActor ObservableObject`). Owns connection lifecycle, ADB device discovery, TCP listener, handshake, battery polling, menu bar status icon, file drag-and-drop push, and screenshot capture. Publishes `screenshotFlash: ScreenshotFlash?` (set with `withAnimation`; auto-cleared after 3.5 s). |
| `ScrcpyVideoStream.swift` | H.264 decoder. Reads 12-byte frame headers, converts Annex B → AVCC, enqueues `CMSampleBuffer` to `AVSampleBufferDisplayLayer`. Publishes `videoSize` (updated from SPS on every config packet, including rotation). Maintains a persistent `VTDecompressionSession` that decodes every frame in the background and stores the latest `CVPixelBuffer` for screenshot capture. |
| `ScrcpyAudioStream.swift` | PCM audio processor. Reads raw s16le stereo 48 kHz frames, converts to Float32 planar, feeds an `AVAudioSourceNode` pull-model render callback via a lock-protected SPSC ring buffer (`AudioRingBuffer`). This prevents inter-buffer silence gaps that caused crackling with the old `scheduleBuffer` push model. |
| `ScrcpyControlSocket.swift` | Input protocol. Encodes keyboard/mouse/touch/scroll/rotation as scrcpy v3 binary messages (big-endian). Bidirectional clipboard sync. |
| `ContentView.swift` | Root split-panel layout (`PhonePanelView` left + `ContentPanelView` right). `PhonePanelView` owns phone viewport, hover-reveal title bar, glass control pills, log panel, screenshot flash overlay, and the pop-out flow. `ContentPanelView` hosts a top-mounted Liquid Glass segmented tab bar (Messages / Photos / Calls) with `AuthManager`-gated content. Also contains `PopoutCoordinator`, `PopoutView`, `ToolbarHoverArea`, `TrafficLightController`, `ScreenshotFlashView`, `PanelResizeDivider`, and all tab sub-views. |
| `ToolbarButton.swift` | Shared button component with two styles: `.glass` (36×36, interactive glass circle, used in title bar and hover toolbars) and `.panel` (36×36, plain, used in `ControlPanelView`). Replaces the duplicated `barButton`/`popBtn`/`panelButton` private helpers that previously existed in each view. |
| `AuthManager.swift` | `@Observable` class that gates access to the right-panel tabs via biometrics/password. Locks after 2 min background or 2 min inactivity. |
| `VideoDisplayView.swift` | `NSViewRepresentable` bridging SwiftUI to `AVSampleBufferDisplayLayer`. Captures all mouse/keyboard/scroll events, supports trackpad gesture simulation, and drag-and-drop file handling. |
| `ControlPanelView.swift` | Floating side panel with hardware control buttons (Back, Home, Recents, Volume Up/Down, Mute, Power, Rotate). Exposes `onInteraction` callback used by `PopoutCoordinator` to reset idle-fade timer. |
| `Scrcpy_SwiftUIApp.swift` | App entry point + `WindowManager` (`@Observable`) for window chrome (transparent title bar, traffic lights, always-on-top). Simplified — no aspect-ratio locking in the main window (that lives in the popout). |
| `AppLog.swift` | Singleton logger, max 500 entries, displayed as overlay in `PhonePanelView`. |
| `NWConnectionExtensions.swift` | Protocol helpers: async `receiveExactly()` on `NWConnection`, big-endian `Data` readers. |
| `DataBridgeClient.swift` | TCP client connecting to the Android `DataBridgeService` companion app on port 27184 (forwarded via `adb forward`). Fetches real SMS threads, messages, call log, photos, and contacts. Delivers Android push notifications to macOS Notification Center with actionable reply support. Handles `activeCall` state and `callAudioError`. Auto-retries with exponential backoff on disconnect. |
| `DataBridgeModels.swift` | Swift models mirroring the Android bridge models: `BridgeThread`, `BridgeMessage`, `BridgeCall`, `BridgePhoto`, `BridgeContact`, `BridgeContactApp`, `BridgeCallState`, `BridgeRelativeDate`. All `Codable` for JSON decode over the TCP bridge. |
| `BluetoothPairingManager.swift` | Detects whether the Android device is paired via Classic Bluetooth (required for HFP call-audio routing). Uses `IOBluetooth` to look up the device by BT address read from ADB, then calls `requestAuthentication()` to trigger the macOS pairing dialog. Polls `isPaired()` every 2 s (60 s timeout). All IOBluetooth calls dispatched to `DispatchQueue.main`. |
| `CallWindowController.swift` | Singleton that manages a floating borderless `NSWindow` shown during active calls. Hosts `CallView` — a Liquid Glass card with contact name, call status, elapsed timer, and glass circle action buttons (Mute, End, Mac Audio, Phone Audio). Positioned top-right of the main screen with a 12 pt margin. |

**Connection flow** (in `ScrcpyManager.performConnect`):
1. Verify ADB (`adb version`)
2. Locate `scrcpy-server.jar` in app bundle
3. Push JAR to device at `/data/local/tmp/scrcpy-server.jar`
4. Generate random SCID (1...0x7FFFFFFF)
5. Detect device refresh rate via `dumpsys display` (fallback: 60 Hz)
6. Clean any stale reverse tunnel (`adb reverse --remove`)
7. Start `NWListener` on TCP port 27183, waiting for **3 connections** (video, audio, control)
8. Set up ADB reverse tunnel `localabstract:scrcpy_XXXXXXXX → tcp:27183`
9. Launch scrcpy-server via `adb shell app_process` with codec/audio/control/fps args
10. Perform 64-byte device name handshake, then read 12-byte codec metadata (codec ID, width, height)
11. Hand connections off to `ScrcpyVideoStream`, `ScrcpyAudioStream`, and `ScrcpyControlSocket`

**Protocol details:**
- All binary fields are big-endian
- Video/audio frame header: 12 bytes (8-byte PTS + 4-byte size, config flag in PTS high bit)
- Config packets carry SPS/PPS NAL units; data packets are H.264 Annex B frames
- Audio frames are raw s16le interleaved stereo 48 kHz PCM; config packets (bit 63 set) are skipped
- Control messages use scrcpy v3 type bytes: `0x00` keycode, `0x01` text, `0x02` touch, `0x03` scroll, `0x04` back/screen-on, `0x08` get clipboard, `0x09` set clipboard, `0x0A` display power, `0x0B` rotate device
- **GET_CLIPBOARD (`0x08`) is 2 bytes**: `[0x08, copy_key]` where `copy_key=0x00` (SC_COPY_KEY_NONE). Sending only 1 byte causes protocol desync — the server blocks waiting for the second byte, then misinterprets subsequent messages.
- Device → client messages: `0x00` CLIPBOARD (`len:4 + text:N`), `0x01` ACK_CLIPBOARD (`seq:8`)
- Coordinates: macOS bottom-left origin → Android top-left origin (Y-axis flip + aspect ratio scale)

**Control message sizes (all big-endian):**
- `0x00` INJECT_KEYCODE: 14 bytes (type + action:1 + keycode:4 + repeat:4 + metaState:4)
- `0x01` INJECT_TEXT: 5+N bytes (type + len:4 + text:N)
- `0x02` INJECT_TOUCH_EVENT: 32 bytes (type + action:1 + pointerId:8 + x:4 + y:4 + width:2 + height:2 + pressure:2 + actionButton:4 + buttons:4)
- `0x03` INJECT_SCROLL_EVENT: 21 bytes (type + x:4 + y:4 + width:2 + height:2 + hScroll:2 + vScroll:2 + buttons:4)
- `0x04` BACK_OR_SCREEN_ON: 2 bytes (type + action:1)
- `0x08` GET_CLIPBOARD: **2 bytes total** (type + copy_key:1) ⚠️ must be exactly 2
- `0x09` SET_CLIPBOARD: 14+N bytes (type + seq:8 + paste:1 + len:4 + text:N)
- `0x0A` SET_DISPLAY_POWER: 2 bytes (type + power:1)
- `0x0B` ROTATE_DEVICE: 1 byte (type only)

**State management:**
- `ScrcpyManager` uses `ObservableObject` + `@Published`; `WindowManager` uses `@Observable` (Swift 5.10 macro)
- Video, audio, and control objects use `@MainActor` for thread safety
- Video/audio reading uses `Task.detached` to avoid blocking `@MainActor` during network I/O
- Frames use `kCMSampleAttachmentKey_DisplayImmediately` to bypass PTS scheduling
- `ScrcpyVideoStream`, `ScrcpyAudioStream`, and `ScrcpyControlSocket` all expose `var onDisconnect: (() -> Void)?`; fired from `MainActor.run` in their read loops on unexpected error (only when `!Task.isCancelled`)
- `ScrcpyManager.handleUnexpectedDisconnect()` is the shared handler; it calls `await disconnect()` then sets `state = .error(...)`. Double-fire is prevented by checking `state == .connected` at entry (sync guard) and again inside the Task (async guard).
- Controlled teardown (`disconnect()`) sets `onDisconnect = nil` on all three objects before cancelling, so callbacks never fire during intentional stops
- ADB shell commands wrapped with `withTaskCancellationHandler` to call `process.terminate()` on Swift Task cancellation

**ADB paths searched** (in `ScrcpyManager`): `/opt/homebrew/bin/adb`, `/usr/local/bin/adb`, `~/Library/Android/sdk/platform-tools/adb`.

**DataBridge protocol** (in `DataBridgeClient`):
- Transport: newline-delimited JSON over TCP, port 27184, forwarded via `adb forward tcp:27184 tcp:27184`
- Bootstrap: client sends `{"type":"ping"}` → server responds `{"type":"pong"}` → client requests all data in parallel
- Heartbeat: client pings every 20 s so Android service knows the Mac is alive
- Request types: `get_threads`, `get_messages` (with `threadId`), `get_calls`, `get_photos` (paginated, 50/page), `get_contacts`, `get_thumbnail` (200×200 JPEG base64), `get_contact_apps`, `place_call`, `send_sms`, `mark_read`, `call_action` (hangup/mute/unmute/use_mac_audio/use_phone_audio), `notification_action`, `open_url`, `execute_contact_action`, `open_bluetooth_settings`
- Push events from Android: `new_sms`, `new_call`, `call_state` (ringing/active/idle), `call_audio_error`, `push_notification`
- `DataBridgeClient.shared` (nonisolated unsafe) used by the AppDelegate notification action handler to route UNNotificationResponse back to Android
- Auto-retries on disconnect with exponential backoff (2 s → 30 s cap); re-runs `adb forward` on every retry

**Bluetooth pairing flow** (in `BluetoothPairingManager`):
1. After USB connect: `checkAndPair(adbPath:serial:)` called
2. Phone's BT address read via `adb shell settings get secure bluetooth_address`
3. `IOBluetoothDevice(addressString:).isPaired()` decides status
4. If paired: `openConnection(nil)` to establish HFP link; status → `.paired`
5. If not paired: UI shows banner; user taps "Pair Now" → `startPairing()` makes phone discoverable for 120 s via ADB intent, then calls `requestAuthentication()` → macOS pairing dialog appears
6. Background task polls `isPaired()` every 2 s for up to 60 s; on success → `.paired`; on timeout → `.notPaired`

**Active call window** (in `CallWindowController` + `CallView`):
- `CallWindowController.shared` is a singleton; `show(call:bridge:)` creates or updates the window
- Borderless `NSWindow`, `.floating` level, `canJoinAllSpaces`, movable by background
- Positioned top-right of main screen (12 pt margin from visible frame edges)
- `CallView`: Liquid Glass card (`glassEffect(.regular, in: RoundedRectangle(cornerRadius:20))`), contact name, status dot (green = active, orange = ringing), elapsed timer
- Glass circle action buttons in `GlassEffectContainer`: Mute/Unmute (orange tint when muted), End (red), Mac Audio, Phone Audio
- HFP help banner shown when `callAudioError == "hfp_unavailable"` — prompts user to open Bluetooth settings on the phone

## Window & UI Design

The app window uses `.hiddenTitleBar` style (set via `WindowGroup.windowStyle`) with `isOpaque = false` / `backgroundColor = .clear` so the macOS compositor clips to the natural corner radius.

**WindowManager** (in `Scrcpy_SwiftUIApp.swift`) owns main-window chrome:
- Traffic lights always visible (they live in the permanent phone-panel title bar)
- `collectionBehavior = [.managed, .fullScreenNone]` — fullscreen disabled
- No aspect-ratio locking in the main window; the split-panel layout drives its own sizing

**Split layout** (in `ContentView.swift`):
- Left panel (`PhonePanelView`): fixed width 300–420pt, `.thinMaterial` background, phone viewport
- Right panel (`ContentPanelView`): flexible, dark grey `Color(white: 0.12)` background, floating tab bar + auth
- No explicit divider between panels — the contrasting backgrounds provide visual separation

**Phone panel title bar** (46pt, in `PhonePanelView`):
- `WindowDragArea` makes the bar draggable
- Always-visible traffic-light clearance (76pt spacer) + device label + glass utility buttons
- Button order (consistent with popout toolbar): Pop-out → Logs → Pin → Audio (when connected) → Screenshot (when connected) → Disconnect (when connected)
- When popped out: only a "Restore" (`pip.exit`) button remains in the main window title bar
- All buttons use `ToolbarButton(.glass)` — 36×36 interactive glass circles inside a `GlassEffectContainer`

**Pop-out phone window** (created in `PhonePanelView.makePopoutWindow()`):
- `NSWindow` with `.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView`
- `titlebarAppearsTransparent = true`, `titleVisibility = .hidden` — full-bleed content
- Traffic lights hidden at launch (alphaValue 0); hover-reveal toolbar restores them
- `contentAspectRatio` locked to the phone's native ratio; updated on rotation via `onChange(of: videoSize)` with orientation-flip resize animation
- `onToolbarExpand` closure updates `contentAspectRatio` to include `controlBarHeight` when toolbar is visible, so user drag-resize always maintains the phone's ratio
- Hosts `PopoutView(manager:coordinator:onRetreat:onToolbarExpand:)` — takes the full `ScrcpyManager` and `PopoutCoordinator` directly, so it can access `videoStream`, `controlSocket`, `pushFiles`, `disconnect`, `takeScreenshot`, `screenshotFlash`, and observe `coordinator.isFullscreen`/`isPinned` without threading extra closures through `makePopoutWindow`

**Hover-reveal toolbar** (in `PopoutView`):
- `ToolbarHoverArea` NSViewRepresentable overlaid on the full view, tracking-area covers top 50pt
- Mouse enters top 50pt → `toolbarVisible = true`, traffic lights fade in; 0.8s after last enter → fade out
- `TrafficLightController` NSViewRepresentable syncs traffic-light alphaValue with `toolbarVisible`
- Button order matches main panel: Retreat → Logs → Pin → Audio → Screenshot → Disconnect

**Right panel tab bar** (in `ContentPanelView`):
- Layout is `VStack`: tab bar at top, content fills remaining height. No bottom floating bar.
- Tab bar: a single `.glassEffect(.regular, in: Capsule())` on the outer `HStack` — one glass surface for the whole bar, not per-item glass pills.
- Selection indicator: a `Capsule().fill(Color.white.opacity(0.15))` behind the selected item, animated via `matchedGeometryEffect(id: "tab-selection", in: tabNS)` — slides smoothly between tabs with `.smooth(duration: 0.28)`.
- Selected text: `.semibold` + `.primary`. Unselected: `.regular` + `.secondary`. Text-only labels, no SF Symbol icons.
- `PhoneTab` enum only has `title: String`.
- Auth gating: `LockedView` overlays the full content area when locked; tab content is not rendered while locked. Tab taps while locked trigger `auth.authenticate()`.

**Liquid Glass rules enforced throughout `ContentView.swift`:**
- **Content panels are never glass.** Per Apple HIG: "Don't use Liquid Glass in the content layer." Content panels (thread lists, conversation views, photo grids, call lists, contact detail) use plain `Color(white: 0.17)` elevated fills clipped to `RoundedRectangle(cornerRadius: 16)`.
- **Glass is reserved for interactive controls only**: tab bar, toolbar buttons, control pills, action buttons, and inline segmented controls.
- `.prominent` glass style is **not available on macOS** — only `.regular` is supported.
- Multiple adjacent glass elements must be wrapped in `GlassEffectContainer` so their surfaces share a sampling region. Do not use `GlassEffectContainer` around non-glass content.

**`PanelResizeDivider`** (shared component, private in `ContentView.swift`):
- A thin 1pt `Rectangle` with an 8pt invisible hit target; dragging changes the left panel's `@Binding var width`.
- `startWidth` captured `onAppear` and `onEnded`; `onChanged` clamps to `[minWidth, maxWidth]`.
- `onHover` pushes/pops `NSCursor.resizeLeftRight` for native cursor feedback.
- Used identically in both `MessagesTabView` and `CallsTabView`.

**Shared sidebar width** (in `ContentPanelView`):
- `@State private var sidebarWidth: CGFloat = 232` lives in `ContentPanelView` and is passed as `@Binding` to both `MessagesTabView` and `CallsTabView` — the sidebar width persists across tab switches.
- Each tab view uses `.onGeometryChange(for: CGFloat.self, of: \.size.width)` to clamp `sidebarWidth` when the window shrinks, ensuring the right panel always has at least 220 pt.

**Messages tab** (in `ContentView.swift`):
- Two-panel split: left = `ThreadListPanel` (thread list + search + compose button), right = `ConversationPanel` (contact header + message history + input bar).
- Both panels use `Color(white: 0.17)` fill + `clipShape(RoundedRectangle(cornerRadius: 16))` — no glass.
- Sidebar width received as `@Binding var listWidth`, clamped 160–340 pt via `PanelResizeDivider`.
- Search bar inside left panel: plain `.fill(.white.opacity(0.08))` rounded rect.
- Compose button (`square.and.pencil`): 34×34pt, `.buttonStyle(.plain)`, `NSCursor.pointingHand` on hover.
- Selected thread row: `Color.accentColor.opacity(0.15)` fill; unread badge: `Color.accentColor`.
- Loading state: `ProgressView` + "Loading messages…" label (no bare spinner).
- Conversation: `ScrollViewReader` scrolls to the last message `onAppear`. Messages come from `bridge.messages[thread.threadId]`. Input bar uses a plain capsule fill with placeholder "Text Message"; send button uses `Color.accentColor`.
- Received message bubbles: `.white.opacity(0.12)` fill. Sent: `Color.blue` fill. Timestamp labels at 11pt.
- Day grouping via `groupedByDay(_:)` + `DayDivider`. New-conversation flow via `NewConversationPanel`.

**Photos tab** (in `ContentView.swift`):
- `LazyVGrid` with `[GridItem(.adaptive(minimum: 130, maximum: 240), spacing: 8)]` — fills available width, each cell 130–240 pt.
- `ScrollView` uses `Color(white: 0.17)` fill + `clipShape(RoundedRectangle(cornerRadius: 16))` — no glass.
- Loading state: `ProgressView` + "Loading photos…" label (no bare spinner).
- Photo cells (`PhotoCell`): square `Rectangle` fill, thumbnail loaded via `bridge.fetchThumbnail(mediaId:)` on appear, `NSCursor.pointingHand` on hover. Clicking calls `bridge.openFullPhoto(mediaId:)`. Checkmark overlay when `photo.localURL != nil`.
- Infinite scroll: sentinel `Color.clear` at grid end triggers `bridge.loadMorePhotos()` when it appears.

**Calls tab** (in `ContentView.swift`):
- Same two-panel split as Messages; both panels use `Color(white: 0.17)` fill — no glass on content panels.
- Left panel (`CallListPanel`): search bar + scrollable `CallRow` list. Each row shows avatar, name (red if missed), direction icon + duration, time. Selection uses `Color.accentColor.opacity(0.15)`. Data from `bridge.calls`.
- Sidebar width received as `@Binding var listWidth` from `ContentPanelView` (shared with Messages/Contacts tabs).
- Right panel (`ContactDetailPanel`) — designed to mirror macOS Phone app:
  - `ZStack` with a `LinearGradient` background: contact's hue bleeds from the top (dark tinted, `brightness: 0.28`) and fades to `Color(white: 0.17)` by midpoint.
  - Large 90 pt avatar with a **colored glow shadow** matching the contact hue (not a generic black shadow).
  - **Action buttons** (Message / Call / Other): each is a Liquid Glass circle — `Button` with `.glassEffect(.regular.interactive(), in: Circle())`, icon inside, text label below. All three wrapped in `GlassEffectContainer(spacing: 16)`. "Other" shows a `popover` with `AppActionsMenu` — third-party app actions from `bridge.contactApps`.
  - **Liquid Glass segmented control** (Details / Recent Calls): two glass pills inside `GlassEffectContainer(spacing: 2)` with `glassEffectID` morphing via `@Namespace var detailNS`. Switches tab content with `.smooth(duration: 0.25)`.
  - Section content (Details rows, Recent Calls rows) in `Color(white: 0.20)` rounded cards — plain fills, no glass.

**Contacts tab** (in `ContentView.swift`):
- Same two-panel split as Messages/Calls; both panels use `Color(white: 0.17)` fill — no glass on content panels.
- Left panel (`ContactListPanel`): search bar + scrollable `ContactRow` list. Each row shows hue-tinted avatar, name, first phone number. Data from `bridge.contacts`. Sidebar width shared via `@Binding var listWidth`.
- Right panel (`ContactInfoPanel`): identical layout to `ContactDetailPanel` in the Calls tab.
  - `LinearGradient` background with contact hue tint fading to `Color(white: 0.17)`.
  - 90 pt avatar with colored glow shadow. Contact name at 22pt bold.
  - Action buttons (Message / Call / Other) — same glass circles + `GlassEffectContainer` as Calls tab.
  - `infoSection(title:content:)` helper renders each section: uppercase 11pt title label above a `Color(white: 0.20)` rounded card. Sections shown: Organisation, Phone, Email, Birthday, Address, Website, Notes (each only when non-nil/non-empty).
  - Phone numbers deduplicated by digits-only comparison before rendering.
  - Email rows are tappable — open `mailto:` URL in default Mail app.

**Control Panel** (floating side window alongside the popout):
- Borderless `NSWindow` hosting `ControlPanelView` SwiftUI view
- 9 buttons: Back, Home, Recents, Volume Up, Volume Down, Mute, Power, Rotate
- **`PopoutCoordinator`** (`NSWindowDelegate` + `ObservableObject` on the popout window) manages the sidebar's lifetime and publishes state to `PopoutView`:
  - `@Published isFullscreen` — drives the fullscreen bottom controls bar in `PopoutView`
  - `@Published isPinned` — drives the pin button tint in `PopoutView`'s toolbar; `togglePin()` sets the **popout** window level (`.floating` / `.normal`). The main window's `WindowManager.toggleAlwaysOnTop()` is **not used** from the popout — they are independent.
  - `NSWindow.willMoveNotification` → fade sidebar to 0 (drag start)
  - `windowDidMove` → reposition sidebar + 0.15s debounce to restore alpha
  - `NSWindow.didResizeNotification` → reposition sidebar (handles device rotation resizes), guarded by `!isFullscreen`
  - `windowWillEnterFullScreen` → save `preFSHeight`, set `isFullscreen = true`, fade out + orderOut sidebar
  - `windowDidExitFullScreen` → snap window via `preFSHeight × videoRatio`, reset `contentAspectRatio`, restore + fade in sidebar
  - `windowDidBecomeKey` / `windowDidResignKey` → show / hide sidebar (`orderFront` / `orderOut`)
  - `windowDidMiniaturize` / `windowDidDeminiaturize` → hide / show sidebar
  - Idle timer: 4s after last interaction → fade to 0.35 alpha; any button tap resets via `onInteraction` callback

**Clipboard sync** (in `ScrcpyControlSocket`):
- **Text-only bidirectional**: Mac→Android via `sendSetClipboard` (`0x09`) polled every 500ms on `NSPasteboard.changeCount`; Android→Mac via `GET_CLIPBOARD` (`0x08`) fallback every 3s + device pushes CLIPBOARD messages
- Image clipboard is **not supported** by the scrcpy protocol
- Polling task started in `startClipboardSync()`, cancelled in `stop()`

**Rotation handling:**
- Rotate button sends `sendRotateDevice()` → scrcpy `0x0B`
- Device sends new config packet with flipped SPS dimensions
- `ScrcpyVideoStream.processConfigPacket` extracts dimensions from `CMVideoFormatDescription` and updates `videoSize`
- `ContentView.onChange(of: manager.videoStream.videoSize)` calls `controlSocket.updateVideoSize` (for input coordinate mapping); the main split-panel window does NOT lock to the phone's aspect ratio — the phone video is letterboxed inside the fixed-width phone panel
- When popped out: `PhonePanelView.onChange(of: manager.videoStream.videoSize)` detects orientation flip (portrait↔landscape) and animates the pop-out window to a new size (current phone height becomes new phone width, keeping scale constant), then updates `contentAspectRatio`
- `PopoutView` observes `manager.videoStream.videoSize` (via `@ObservedObject var manager`) so the in-window `fitSize` computation updates live on every `videoSize` change

**Video display:**
- `AVSampleBufferDisplayLayer.videoGravity = .resize` (not `.resizeAspect`) — no black bars because the window is always constrained to the phone's exact aspect ratio

**Trackpad gesture simulation** (in `VideoNSView.scrollWheel`):
- Precise scroll events (trackpad phase began/changed/ended) → simulated finger touch events (pointer ID 0)
- Scale × 1.5 to meet Android gesture recognition threshold (~100 device px)
- Enables native swipe-back, carousels, gesture-driven UI
- Non-precise events (mouse wheel) → scroll event with divisor 3; trackpad momentum/precise → divisor 80

**File drag-and-drop** (in `VideoDisplayView`):
- APK files → `adb install -r`
- Other files → `adb push` to `/sdcard/Download/` + media scanner notification + opens Downloads folder on device
- Blue overlay shown during drag

**Battery status** (in `ScrcpyManager`):
- Polled every 60s from `dumpsys battery`, parsed for `level:` and `status:` (2=charging, 5=full)
- Displayed as macOS menu bar status item with battery icon + level + ⚡ charging indicator

**Screenshot** (in `ScrcpyManager` + `ScrcpyVideoStream`):
- Triggered via `camera` button in main panel title bar (when connected) or popout hover toolbar
- `ScrcpyVideoStream` keeps a persistent `VTDecompressionSession` (`captureSession`) that decodes every incoming frame on a background VT thread and stores the result in `latestDecodedBuffer` via `DispatchQueue.main.async`. This avoids the deadlock that occurs when creating a VT session on `@MainActor` and blocking with `VTDecompressionSessionWaitForAsynchronousFrames` (the output handler can't be delivered while main is blocked).
- `captureCurrentFrame()` converts `latestDecodedBuffer` (CVPixelBuffer → CIImage → CGImage). Returns nil if no frame has been decoded yet.
- `ScrcpyManager.takeScreenshot()`: captures frame, writes PNG to Desktop as `aPhone Screenshot yyyy-MM-dd at HH.mm.ss.png`, plays `/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif` (fallback: `NSSound(named: "Pop")`), sets `screenshotFlash` with `withAnimation`, clears it after 3.5 s.
- `ScreenshotFlashView` (private in `ContentView.swift`): thumbnail overlay at `.bottomTrailing` of the phone viewport; springs in via `onAppear`; clicking opens the file in the default viewer (`NSWorkspace.shared.open`). Shown in both main panel (`!viewportIsPopped`) and popout.
- `CGWindowListCreateImage` is **unavailable** in the macOS 26 SDK — do not attempt to use it.

**Audio** (in `ScrcpyAudioStream`):
- Pull-model: `AVAudioSourceNode` render callback drains `AudioRingBuffer` on every engine tick — no silence gaps on USB jitter.
- `AudioRingBuffer`: SPSC ring buffer, 2 s capacity (96 000 frames @ 48 kHz), `os_unfair_lock`-protected. Converts s16le interleaved → Float32 non-interleaved on write; fills silence on underrun.
- Do **not** revert to `scheduleBuffer`/`AVAudioPlayerNode` — that approach inserts silence whenever a buffer hasn't arrived yet, causing audible crackling.

**Debug log panel** (in `PhonePanelView`):
- Slides up from the bottom of the phone panel.
- Auto-scrolls to the latest entry only when the user is already at the bottom (`isAtBottom` tracked via `.onScrollGeometryChange`). If the user scrolls up to read, auto-scroll is suppressed until they return to the bottom.

**Keyboard input** (in `VideoNSView` + `ScrcpyControlSocket`):
- Cmd+key → remapped to Ctrl+key for Android shortcuts
- Printable characters → text injection (`0x01`); control characters → keycode (`0x00`)
- 50+ key mapping table (letters, numbers, function keys, arrows, symbols)
- `androidMetaState()` maps Shift/Alt/Ctrl/Cmd to Android meta bits
