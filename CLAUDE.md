# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- Button order (consistent with popout toolbar): Pop-out → Logs → Pin → Screenshot (when connected) → Disconnect (when connected)
- When popped out: only a "Restore" (`pip.exit`) button remains in the main window title bar
- All buttons use `ToolbarButton(.glass)` — 36×36 interactive glass circles inside a `GlassEffectContainer`

**Pop-out phone window** (created in `PhonePanelView.makePopoutWindow()`):
- `NSWindow` with `.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView`
- `titlebarAppearsTransparent = true`, `titleVisibility = .hidden` — full-bleed content
- Traffic lights hidden at launch (alphaValue 0); hover-reveal toolbar restores them
- `contentAspectRatio` locked to the phone's native ratio; updated on rotation via `onChange(of: videoSize)` with orientation-flip resize animation
- `onToolbarExpand` closure updates `contentAspectRatio` to include `controlBarHeight` when toolbar is visible, so user drag-resize always maintains the phone's ratio
- Hosts `PopoutView(manager:onRetreat:onToolbarExpand:)` — takes the full `ScrcpyManager` directly (not individual stream/socket callbacks), so it can access `videoStream`, `controlSocket`, `pushFiles`, `disconnect`, `takeScreenshot`, and `screenshotFlash` without threading extra closures through `makePopoutWindow`

**Hover-reveal toolbar** (in `PopoutView`):
- `ToolbarHoverArea` NSViewRepresentable overlaid on the full view, tracking-area covers top 50pt
- Mouse enters top 50pt → `toolbarVisible = true`, traffic lights fade in; 0.8s after last enter → fade out
- `TrafficLightController` NSViewRepresentable syncs traffic-light alphaValue with `toolbarVisible`
- Button order matches main panel: Retreat → Logs → Pin → Screenshot → Disconnect

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
- Two-panel split: left = `ThreadListPanel` (thread list + search), right = `ConversationPanel` (contact header + message history + input bar).
- Both panels use `Color(white: 0.17)` fill + `clipShape(RoundedRectangle(cornerRadius: 16))` — no glass.
- Sidebar width received as `@Binding var listWidth`, clamped 160–340 pt via `PanelResizeDivider`.
- Search bar inside left panel: plain `.fill(.white.opacity(0.08))` rounded rect.
- Selected thread row: `Color.accentColor.opacity(0.15)` fill; unread badge: `Color.accentColor`.
- Conversation: `ScrollViewReader` scrolls to the last message `onAppear`. Input bar uses a plain capsule fill; send button uses `Color.accentColor`.
- Received message bubbles: `.white.opacity(0.12)` fill. Sent: `Color.blue` fill.
- `fakeConversation(for:)` free function maps thread name → `[FakeMessage]`.

**Photos tab** (in `ContentView.swift`):
- `LazyVGrid` with `[GridItem(.adaptive(minimum: 130, maximum: 240), spacing: 8)]` — fills available width, each cell 130–240 pt.
- `ScrollView` uses `Color(white: 0.17)` fill + `clipShape(RoundedRectangle(cornerRadius: 16))` — no glass.
- Photo cells (`PhotoCell`) are square `Rectangle` fills with a label overlay and `cornerRadius: 12`.
- Clicking a cell generates an 800×800 PNG in `NSTemporaryDirectory()` from `NSImage(size:flipped:)`, writes it, and opens it in Preview via `NSWorkspace.shared.open(url)`. Cursor shows pointing hand on hover via `onHover` + `NSCursor.pointingHand`.

**Calls tab** (in `ContentView.swift`):
- Same two-panel split as Messages; both panels use `Color(white: 0.17)` fill — no glass on content panels.
- Left panel (`CallListPanel`): search bar + scrollable `CallRow` list. Each row shows avatar, name (red if missed), direction icon + duration, time. Selection uses `Color.accentColor.opacity(0.15)`.
- Sidebar width received as `@Binding var listWidth` from `ContentPanelView` (shared with Messages tab).
- Right panel (`ContactDetailPanel`) — designed to mirror macOS Phone app:
  - `ZStack` with a `LinearGradient` background: contact's hue bleeds from the top (dark tinted, `brightness: 0.28`) and fades to `Color(white: 0.17)` by midpoint.
  - Large 90 pt avatar with a **colored glow shadow** matching the contact hue (not a generic black shadow).
  - **Action buttons** (Message / Call / Video): each is a Liquid Glass circle — `Button` with `.glassEffect(.regular.interactive(), in: Circle())`, icon inside, text label below. All three wrapped in `GlassEffectContainer(spacing: 16)`.
  - **Liquid Glass segmented control** (Details / Recent Calls): two glass pills inside `GlassEffectContainer(spacing: 2)` with `glassEffectID` morphing via `@Namespace var detailNS`. Switches tab content with `.smooth(duration: 0.25)`.
  - Section content (Details rows, Recent Calls rows) in `Color(white: 0.20)` rounded cards — plain fills, no glass.
- `fakeCalls` contains 10 entries (some contacts appear multiple times for history).
- `fakePhone()` / `fakeEmail()` generate deterministic fake contact info from `call.hue`.

**Control Panel** (floating side window alongside the popout):
- Borderless `NSWindow` hosting `ControlPanelView` SwiftUI view
- 9 buttons: Back, Home, Recents, Volume Up, Volume Down, Mute, Power, Rotate
- **`PopoutCoordinator`** (`NSWindowDelegate` on the popout window) manages the sidebar's lifetime:
  - `NSWindow.willMoveNotification` → fade sidebar to 0 (drag start)
  - `windowDidMove` → reposition sidebar + 0.15s debounce to restore alpha
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
