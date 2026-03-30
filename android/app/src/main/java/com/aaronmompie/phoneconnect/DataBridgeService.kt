package com.aaronmompie.phoneconnect

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.net.Uri
import android.os.IBinder
import android.provider.CallLog
import android.provider.Settings
import android.provider.Telephony
import android.telecom.TelecomManager
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

class DataBridgeService : Service() {

    companion object {
        @Volatile var instance: DataBridgeService? = null
        private const val NOTIF_ID = 1001
        private const val CHANNEL_ID = "aphone_data_bridge"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var serverSocket: ServerSocket? = null
    @Volatile private var activeWriter: BufferedWriter? = null
    @Volatile private var activeSocket: Socket? = null
    private var clientJob: Job? = null
    private var serverJob: Job? = null
    private var callStateManager: CallStateManager? = null
    private var smsObserverJob: Job? = null
    private var callObserverJob: Job? = null

    private val smsReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
                debouncedSmsPush()
            }
        }
    }

    private val smsContentObserver = object : android.database.ContentObserver(
        android.os.Handler(android.os.Looper.getMainLooper())
    ) {
        override fun onChange(selfChange: Boolean) { debouncedSmsPush() }
    }

    private val callLogObserver = object : android.database.ContentObserver(
        android.os.Handler(android.os.Looper.getMainLooper())
    ) {
        override fun onChange(selfChange: Boolean) { debouncedCallPush() }
    }

    private fun debouncedCallPush() {
        callObserverJob?.cancel()
        callObserverJob = scope.launch {
            delay(800)
            pushEvent("""{"type":"new_call"}""")
        }
    }

    private fun debouncedSmsPush() {
        smsObserverJob?.cancel()
        smsObserverJob = scope.launch {
            delay(800)
            val threadId = DataProviders.getLatestSmsThreadId(applicationContext)
            pushEvent("""{"type":"new_sms","threadId":$threadId}""")
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
        registerReceiver(smsReceiver, IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION))
        contentResolver.registerContentObserver(Uri.parse("content://sms"), true, smsContentObserver)
        contentResolver.registerContentObserver(CallLog.Calls.CONTENT_URI, true, callLogObserver)
        callStateManager = CallStateManager(applicationContext).also { it.start() }
        launchServer()
        Log.i("DataBridgeService", "Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Relaunch the TCP server if it exited (e.g., port was temporarily in use on first bind)
        val ss = serverSocket
        if (ss == null || ss.isClosed) {
            launchServer()
        }
        return START_STICKY
    }

    private fun launchServer() {
        serverJob?.cancel()
        serverJob = scope.launch { runServer() }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        try { unregisterReceiver(smsReceiver) } catch (_: Exception) {}
        try { contentResolver.unregisterContentObserver(smsContentObserver) } catch (_: Exception) {}
        try { contentResolver.unregisterContentObserver(callLogObserver) } catch (_: Exception) {}
        smsObserverJob?.cancel(); smsObserverJob = null
        callObserverJob?.cancel(); callObserverJob = null
        try { activeSocket?.close() } catch (_: Exception) {}
        callStateManager?.stop(); callStateManager = null
        scope.cancel()
        try { serverSocket?.close() } catch (_: Exception) {}
        Log.i("DataBridgeService", "Service destroyed")
    }

    // ── TCP Server ───────────────────────────────────────────────────────────

    private suspend fun runServer() {
        val ss = try {
            ServerSocket().also { s ->
                s.reuseAddress = true
                s.bind(InetSocketAddress("127.0.0.1", 27184))
            }
        } catch (e: Exception) {
            Log.e("DataBridgeService", "Failed to bind port 27184: ${e.message}")
            return
        }
        serverSocket = ss
        Log.i("DataBridgeService", "TCP server ready on port 27184")
        try {
            while (scope.isActive) {
                // runInterruptible lets coroutine cancellation interrupt accept()
                val socket = kotlinx.coroutines.runInterruptible(Dispatchers.IO) { ss.accept() }
                Log.i("DataBridgeService", "Client connected")
                // Close any lingering old socket so its blocking readLine() unblocks immediately
                activeSocket?.let { old -> try { old.close() } catch (_: Exception) {} }
                activeSocket = socket
                clientJob?.cancel()
                clientJob = scope.launch { handleClient(socket) }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            if (scope.isActive) Log.e("DataBridgeService", "Server accept error: ${e.message}")
        } finally {
            try { ss.close() } catch (_: Exception) {}
            if (serverSocket === ss) serverSocket = null
        }
    }

    private suspend fun handleClient(socket: Socket) {
        Log.i("DataBridgeService", "handleClient started for ${socket.inetAddress}")
        socket.soTimeout = 45_000  // 45s read timeout — catches dead connections (heartbeat is every 20s)
        val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
        val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream()))

        // Verify the per-session token sent by the Mac as the first message.
        // The Mac writes the token via `adb shell settings put secure aphone_bridge_token TOKEN`
        // before connecting. Settings.Secure is writable by ADB (shell UID) and readable by
        // this app via ContentResolver — no unreliable intent extras needed.
        val expectedToken = Settings.Secure.getString(contentResolver, "aphone_bridge_token")
            ?.takeIf { it.length == 32 }
        if (expectedToken == null) {
            Log.w("DataBridgeService", "Rejected connection: no session token configured (Mac not connected yet)")
            socket.close()
            return
        }
        val authLine = runCatching {
            kotlinx.coroutines.runInterruptible(Dispatchers.IO) { reader.readLine() }
        }.getOrNull()
        val authObj = runCatching {
            Json.parseToJsonElement(authLine ?: "").jsonObject
        }.getOrNull()
        val sentToken = authObj?.get("token")?.jsonPrimitive?.contentOrNull
        if (authObj?.get("type")?.jsonPrimitive?.contentOrNull != "auth" || sentToken != expectedToken) {
            Log.w("DataBridgeService", "Rejected connection: bad or missing auth token")
            socket.close()
            return
        }

        activeWriter = writer
        updateNotification(connected = true)
        try {
            while (true) {
                // runInterruptible makes readLine() respond to coroutine cancellation
                val line = kotlinx.coroutines.runInterruptible(Dispatchers.IO) {
                    reader.readLine()
                } ?: break
                Log.d("DataBridgeService", "Received: ${line.take(80)}")
                val response = processRequest(line) ?: continue
                withContext(Dispatchers.IO) {
                    writer.write(response + "\n")
                    writer.flush()
                }
            }
            Log.i("DataBridgeService", "Client closed connection (EOF)")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.i("DataBridgeService", "Client disconnected: ${e.javaClass.simpleName}: ${e.message}")
        } finally {
            if (activeWriter === writer) activeWriter = null
            try { socket.close() } catch (_: Exception) {}
            Log.i("DataBridgeService", "handleClient finished — waiting for next connection")
            updateNotification(connected = false)
        }
    }

    // ── Request Dispatch ─────────────────────────────────────────────────────

    private suspend fun processRequest(json: String): String? {
        return try {
            val type = extractStringField(json, "type") ?: return null
            when (type) {
                "ping" -> """{"type":"pong"}"""

                "get_threads" -> {
                    val threads = withContext(Dispatchers.IO) {
                        DataProviders.getSmsThreads(applicationContext)
                    }
                    """{"type":"threads_response","threads":${Json.encodeToString(threads)}}"""
                }

                "get_messages" -> {
                    val threadId = extractLongField(json, "threadId") ?: return null
                    val messages = withContext(Dispatchers.IO) {
                        DataProviders.getSmsMessages(applicationContext, threadId)
                    }
                    """{"type":"messages_response","threadId":$threadId,"messages":${Json.encodeToString(messages)}}"""
                }

                "get_calls" -> {
                    val calls = withContext(Dispatchers.IO) {
                        DataProviders.getCallLog(applicationContext)
                    }
                    """{"type":"calls_response","calls":${Json.encodeToString(calls)}}"""
                }

                "get_photos" -> {
                    val offset = (extractLongField(json, "offset") ?: 0L).toInt()
                    val limit  = (extractLongField(json, "limit")  ?: 50L).toInt()
                    val photos = withContext(Dispatchers.IO) {
                        DataProviders.getPhotos(applicationContext, offset, limit)
                    }
                    """{"type":"photos_response","offset":$offset,"photos":${Json.encodeToString(photos)}}"""
                }

                "mark_read" -> {
                    val threadId = extractLongField(json, "threadId") ?: return null
                    withContext(Dispatchers.IO) {
                        DataProviders.markThreadRead(applicationContext, threadId)
                    }
                    null // no response needed
                }

                "get_thumbnail" -> {
                    val mediaId = extractLongField(json, "mediaId") ?: return null
                    val jpeg = withContext(Dispatchers.IO) {
                        DataProviders.getThumbnail(applicationContext, mediaId)
                    }
                    if (jpeg != null) {
                        """{"type":"thumbnail_response","mediaId":$mediaId,"jpeg":"$jpeg"}"""
                    } else {
                        """{"type":"error","requestType":"get_thumbnail","message":"Not found"}"""
                    }
                }

                "notification_action" -> {
                    val el = Json.parseToJsonElement(json).jsonObject
                    val notifKey = el["notifKey"]?.jsonPrimitive?.content ?: return null
                    val actionIndex = el["actionIndex"]?.jsonPrimitive?.int ?: 0
                    val replyText = el["replyText"]?.jsonPrimitive?.contentOrNull
                    withContext(Dispatchers.IO) {
                        NotificationService.instance?.executeAction(notifKey, actionIndex, replyText)
                    }
                    null
                }

                "open_url" -> {
                    val url = extractStringField(json, "url") ?: return null
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try { applicationContext.startActivity(intent) } catch (e: Exception) {
                        Log.w("DataBridgeService", "open_url failed: ${e.message}")
                    }
                    null
                }

                "call_action" -> {
                    val action = extractStringField(json, "action") ?: return null
                    val audioManager = getSystemService(AudioManager::class.java)
                    when (action) {
                        "hangup" -> {
                            try {
                                getSystemService(TelecomManager::class.java).endCall()
                            } catch (e: Exception) {
                                Log.w("DataBridgeService", "hangup failed: ${e.message}")
                            }
                        }
                        "mute"   -> audioManager.isMicrophoneMute = true
                        "unmute" -> audioManager.isMicrophoneMute = false
                        "use_mac_audio" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                val btSco = audioManager.availableCommunicationDevices
                                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                                if (btSco != null) {
                                    audioManager.setCommunicationDevice(btSco)
                                } else {
                                    // HFP not configured — tell the Mac and open BT settings on the phone
                                    pushEvent("""{"type":"call_audio_error","error":"hfp_unavailable"}""")
                                    val btIntent = Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    try { applicationContext.startActivity(btIntent) } catch (e: Exception) {
                                        Log.w("DataBridgeService", "open BT settings failed: ${e.message}")
                                    }
                                }
                            } else {
                                @Suppress("DEPRECATION")
                                audioManager.mode = AudioManager.MODE_IN_CALL
                                @Suppress("DEPRECATION")
                                audioManager.startBluetoothSco()
                                @Suppress("DEPRECATION")
                                audioManager.isBluetoothScoOn = true
                            }
                        }
                        "use_phone_audio" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                // Clear BT SCO — system routes back to earpiece automatically
                                audioManager.clearCommunicationDevice()
                            } else {
                                @Suppress("DEPRECATION")
                                audioManager.stopBluetoothSco()
                                @Suppress("DEPRECATION")
                                audioManager.isBluetoothScoOn = false
                                // Keep MODE_IN_CALL so the call stays active; earpiece is the default
                            }
                            audioManager.isSpeakerphoneOn = false
                        }
                    }
                    null
                }

                "get_contacts" -> {
                    val contacts = withContext(Dispatchers.IO) {
                        DataProviders.getContacts(applicationContext)
                    }
                    """{"type":"contacts_response","contacts":${Json.encodeToString(contacts)}}"""
                }

                "open_bluetooth_settings" -> {
                    val btIntent = Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try { applicationContext.startActivity(btIntent) } catch (e: Exception) {
                        Log.w("DataBridgeService", "open BT settings failed: ${e.message}")
                    }
                    null
                }

                "place_call" -> {
                    val phone = extractStringField(json, "phone") ?: return null
                    val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$phone")).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try { applicationContext.startActivity(intent) } catch (e: Exception) {
                        Log.w("DataBridgeService", "place_call failed: ${e.message}")
                    }
                    null
                }

                "send_sms" -> {
                    val to   = extractStringField(json, "to")   ?: return null
                    val body = extractStringField(json, "body") ?: return null
                    try {
                        val smsManager = if (android.os.Build.VERSION.SDK_INT >= 31) {
                            applicationContext.getSystemService(android.telephony.SmsManager::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            android.telephony.SmsManager.getDefault()
                        }
                        smsManager?.sendTextMessage(to, null, body, null, null)
                    } catch (e: Exception) {
                        Log.w("DataBridgeService", "send_sms failed: ${e.message}")
                    }
                    null
                }

                "get_contact_apps" -> {
                    val phone = extractStringField(json, "phone") ?: return null
                    val name  = extractStringField(json, "name")
                    val apps = withContext(Dispatchers.IO) {
                        DataProviders.getContactApps(applicationContext, phone, name)
                    }
                    val phoneEscaped = phone.replace("\"", "\\\"")
                    """{"type":"contact_apps_response","phone":"$phoneEscaped","apps":${Json.encodeToString(apps)}}"""
                }

                "execute_contact_action" -> {
                    val dataId   = extractLongField(json, "dataId")     ?: return null
                    val mimeType = extractStringField(json, "mimeType") ?: return null
                    val uri = ContentUris.withAppendedId(
                        android.provider.ContactsContract.Data.CONTENT_URI, dataId
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mimeType)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try { applicationContext.startActivity(intent) } catch (e: Exception) {
                        Log.w("DataBridgeService", "execute_contact_action failed: ${e.message}")
                    }
                    null
                }

                else -> null
            }
        } catch (e: Exception) {
            Log.e("DataBridgeService", "processRequest error for: $json", e)
            null
        }
    }

    // ── Push Events ──────────────────────────────────────────────────────────

    fun pushEvent(json: String) {
        if (activeWriter == null) {
            Log.d("DataBridgeService", "pushEvent: no active client — event dropped")
            return
        }
        scope.launch {
            try {
                activeWriter?.apply {
                    write(json + "\n")
                    flush()
                    Log.d("DataBridgeService", "pushEvent: sent ${json.take(80)}")
                } ?: Log.d("DataBridgeService", "pushEvent: writer gone before send")
            } catch (e: Exception) {
                Log.w("DataBridgeService", "pushEvent failed: ${e.message}")
            }
        }
    }

    // ── App Icon Encoding ────────────────────────────────────────────────────

    fun encodeAppIcon(packageName: String): String? {
        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, 48, 48)
            drawable.draw(canvas)
            val baos = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, baos)
            bitmap.recycle()
            val bytes = baos.toByteArray()
            if (bytes.size > 6144) null  // skip if > 6 KB
            else Base64.encodeToString(bytes, Base64.NO_WRAP)
        } catch (e: Exception) { null }
    }

    // ── Notification Channel ─────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "aPhone Data Bridge",
            NotificationManager.IMPORTANCE_LOW
        ).apply { description = "Syncing phone data with your Mac" }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun updateNotification(connected: Boolean) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIF_ID, buildNotification(connected))
    }

    private fun buildNotification(connected: Boolean = false): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("aPhone Mirroring")
            .setContentText(if (connected) "Connected to Mac — syncing data" else "Waiting for Mac connection…")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()

    // ── Simple JSON Field Extraction ─────────────────────────────────────────

    private fun extractStringField(json: String, key: String): String? =
        Regex(""""$key"\s*:\s*"([^"]*)"""").find(json)?.groupValues?.get(1)

    private fun extractLongField(json: String, key: String): Long? =
        Regex(""""$key"\s*:\s*(\d+)""").find(json)?.groupValues?.get(1)?.toLongOrNull()
}
