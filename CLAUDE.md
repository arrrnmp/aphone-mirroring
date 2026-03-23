# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Android companion app for aPhone Mirroring (macOS). Runs a foreground TCP service that exposes real phone data (SMS, calls, photos, contacts, notifications, active call state) to the macOS app over a local USB connection via `adb forward`. Does **not** handle screen mirroring — that is managed entirely by the scrcpy protocol on the macOS side.

## Build

Open in Android Studio (Electric Eel or later), or via CLI:

```bash
./gradlew assembleDebug
./gradlew assembleRelease
```

Install to a connected device:

```bash
adb install app/build/outputs/apk/debug/app-debug.apk
```

- **Min SDK**: API 29 (Android 10)
- **Target SDK**: API 35
- **Language**: Kotlin
- **Serialization**: `kotlinx.serialization` (JSON)
- **Coroutines**: `kotlinx.coroutines`

## Architecture

All source files are in `app/src/main/java/com/aaronmompie/phoneconnect/`.

**Key components:**

| File | Role |
|------|------|
| `MainActivity.kt` | Entry point. Requests all runtime permissions on launch, starts `DataBridgeService`, starts `NotificationService`. Shows connection status UI. |
| `DataBridgeService.kt` | Foreground `Service`. Runs a `ServerSocket` on port 27184. Accepts one client at a time; serves newline-delimited JSON requests from the Mac and pushes server-initiated events. Owns `smsReceiver` (`BroadcastReceiver`) and Content Observers for live SMS/call updates. |
| `DataProviders.kt` | `object` with all ContentProvider query functions: `getSmsThreads`, `getSmsMessages`, `getCallLog`, `getPhotos` (paginated), `getThumbnail` (200×200 JPEG base64), `markThreadRead`, `getContacts`, `getContactApps`. |
| `BridgeModels.kt` | `@Serializable` data classes shared between service and providers: `BridgeThread`, `BridgeMessage`, `BridgeCall`, `BridgePhoto`, `BridgeContact`, `BridgeContactAction`, `BridgeContactApp`. |
| `CallStateManager.kt` | Listens for phone state changes via `PhoneStateListener` (RINGING / OFFHOOK / IDLE). Looks up the caller's contact name via `PhoneLookup`. Pushes `call_state` events to the Mac via `DataBridgeService.instance?.pushEvent()`. |
| `NotificationService.kt` | `NotificationListenerService`. Intercepts posted notifications and forwards them to the Mac as `push_notification` events via `DataBridgeService.instance?.pushEvent()`. |

## Data Bridge Protocol

**Transport**: newline-delimited JSON over TCP, port 27184.

The Mac sets up the tunnel before connecting:
```bash
adb forward tcp:27184 tcp:27184
```

**Connection handshake**:
1. Mac connects to `localhost:27184`
2. Mac sends: `{"type":"ping"}`
3. Service responds: `{"type":"pong"}`
4. Mac fetches all data types in parallel

**Request/response pattern** (Mac → Android → Mac):

| `type` field | Description |
|---|---|
| `ping` | Heartbeat (sent every 20 s); response: `{"type":"pong"}` |
| `get_threads` | All SMS threads; response: `{"type":"threads","threads":[...]}` |
| `get_messages` | Messages for a thread (`threadId`); response: `{"type":"messages","messages":[...]}` |
| `get_calls` | Call log; response: `{"type":"calls","calls":[...]}` |
| `get_photos` | Photo page (`page`, 50/page); response: `{"type":"photos","photos":[...]}` |
| `get_contacts` | All contacts (up to 500); response: `{"type":"contacts","contacts":[...]}` |
| `get_thumbnail` | Photo thumbnail (`photoId`); response: `{"type":"thumbnail","photoId":"...","data":"<base64>"}` |
| `get_contact_apps` | Third-party apps for a contact (`contactId`); response: `{"type":"contact_apps","apps":[...]}` |
| `send_sms` | Send SMS (`to`, `body`); response: `{"type":"sms_sent","success":bool}` |
| `mark_read` | Mark thread read (`threadId`) |
| `place_call` | Place a phone call (`number`) |
| `call_action` | `action`: `hangup`, `mute`, `unmute`, `use_mac_audio`, `use_phone_audio` |
| `notification_action` | Reply to or dismiss a notification (`key`, `action`, optionally `replyText`) |
| `open_url` | Open a URL on the phone (`url`) |
| `execute_contact_action` | Launch a third-party app action (`uri`) |
| `open_bluetooth_settings` | Open Bluetooth settings on the phone |

**Push events** (Android → Mac, server-initiated):

| `type` field | Trigger |
|---|---|
| `new_sms` | `SMS_RECEIVED_ACTION` broadcast; carries new thread/message data |
| `new_call` | ContentObserver fires on call log URI after debounce (800 ms) |
| `call_state` | `PhoneStateListener` fires; carries `state` (`ringing`/`active`/`idle`), `number`, `contactName` |
| `call_audio_error` | Audio routing fails; carries `error` (`hfp_unavailable`) |
| `push_notification` | `NotificationListenerService` posts; carries `key`, `appName`, `title`, `text`, `replyAction` |

**Socket lifecycle**:
- `ServerSocket` bound to `0.0.0.0:27184` on service start; accepts in a loop.
- One active client at a time; prior client is dropped when a new one connects.
- `SO_TIMEOUT = 45 000 ms` on client sockets — disconnects stale connections.
- `activeWriter` and `activeSocket` are `@Volatile`; `pushEvent()` is thread-safe via `synchronized`.

## Threading Model

- `scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)` — all coroutines run on IO dispatcher.
- `serverJob` accepts incoming connections in a loop.
- `clientJob` reads requests line-by-line; each request is dispatched with `scope.launch`.
- ContentObserver callbacks debounce with a 800 ms `delay` before pushing updates.
- `CallStateManager` uses `Handler(mainLooper)` for `PhoneStateListener` callbacks, then `scope.launch` to push events off the main thread.
- `DataProviders` functions are `suspend fun` and run on the calling coroutine's dispatcher (always IO).

## Data Providers Detail

**`getSmsThreads`**: Queries `Telephony.MmsSms.CONTENT_CONVERSATIONS_URI`. Returns `BridgeThread` list sorted by date descending.

**`getSmsMessages`**: Queries `Telephony.Sms.CONTENT_URI` filtered by `thread_id`. Returns `BridgeMessage` list (incoming/outgoing, body, timestamp).

**`getCallLog`**: Queries `CallLog.Calls.CONTENT_URI`. Returns `BridgeCall` list with type (incoming/outgoing/missed), duration, contact name.

**`getPhotos`**: Queries `MediaStore.Images.Media.EXTERNAL_CONTENT_URI` with `LIMIT/OFFSET` for pagination (50 per page), sorted by `DATE_ADDED DESC`. Returns `BridgePhoto` with URI, display name, date.

**`getThumbnail`**: On API 29+, uses `ContentResolver.loadThumbnail(uri, Size(200,200), null)`. On older APIs, uses `MediaStore.Images.Thumbnails.getThumbnail`. Result encoded as base64 JPEG.

**`getContacts`**: Multi-query approach against `ContactsContract`:
  1. `CommonDataKinds.Phone` — phone numbers
  2. `CommonDataKinds.Email` — email addresses
  3. `CommonDataKinds.Organization` — company/title
  4. `CommonDataKinds.Note` — notes
  5. `CommonDataKinds.Event` (type BIRTHDAY) — birthday
  6. `CommonDataKinds.Website` — websites
  7. `CommonDataKinds.StructuredPostal` — addresses
  Up to 500 contacts. Returns `BridgeContact` with all fields.

**`getContactApps`**: Queries installed apps that can handle the contact's phone/email via `PackageManager.queryIntentActivities`. Returns `BridgeContactApp` list (label, package name, action URI) for third-party apps like Signal, WhatsApp, Telegram.

**`markThreadRead`**: Updates `Telephony.Sms.read = 1` for all messages in the thread.

## Permissions

All declared in `AndroidManifest.xml`. Runtime permissions requested in `MainActivity` on launch:

- **SMS**: `READ_SMS`, `RECEIVE_SMS`, `SEND_SMS`
- **Contacts**: `READ_CONTACTS`
- **Calls**: `READ_CALL_LOG`, `WRITE_CALL_LOG`, `CALL_PHONE`, `ANSWER_PHONE_CALLS`, `READ_PHONE_STATE`
- **Media**: `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_VISUAL_USER_SELECTED` (API 33+), `READ_EXTERNAL_STORAGE` (API ≤32)
- **Notifications**: `POST_NOTIFICATIONS` (API 33+); Notification Listener granted separately in system settings
- **Bluetooth**: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` (API 31+); `BLUETOOTH`, `BLUETOOTH_ADMIN` (API ≤30)
- **Audio**: `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`
- **Foreground Service**: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`
- **Battery**: `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — must be granted to keep service alive

## Key Design Decisions

- **Single active client**: Only one Mac can connect at a time. A new connection replaces the previous one immediately — no queuing.
- **Content Observers over polling**: SMS and call log changes are observed via `ContentResolver.registerContentObserver` rather than polling, with 800 ms debounce to batch rapid updates (e.g. MMS multi-part messages).
- **BroadcastReceiver for incoming SMS**: `SMS_RECEIVED_ACTION` fires before the message lands in the ContentProvider, so the service uses both: the receiver for immediacy, the observer for reliability.
- **Deprecated `PhoneStateListener`**: `TelephonyManager.listen(listener, LISTEN_CALL_STATE)` is deprecated in API 31+ in favor of `TelephonyCallback`, but retained for broad compatibility. Replace with `TelephonyCallback` when min SDK is raised to 31.
- **`stopWithTask = false`** on `DataBridgeService`: Service survives app task removal so mirroring sessions are not interrupted when the user swipes away the app.
- **`runInterruptible`**: Not used — `ServerSocket.accept()` and socket I/O run in coroutines on `Dispatchers.IO`; the job is cancelled via `scope.cancel()` in `onDestroy`.
