package com.aaronmompie.phoneconnect

import kotlinx.serialization.Serializable

@Serializable
data class BridgeThread(
    val threadId: Long,
    val contactName: String,
    val contactPhone: String,
    val preview: String,
    val timestamp: Long,   // epoch millis
    val unreadCount: Int
)

@Serializable
data class BridgeMessage(
    val messageId: Long,
    val threadId: Long,
    val body: String,
    val isFromMe: Boolean,
    val timestamp: Long,   // epoch millis
    val isRead: Boolean
)

@Serializable
data class BridgeCall(
    val callId: Long,
    val number: String,
    val contactName: String?,
    val callType: Int,     // 1=incoming, 2=outgoing, 3=missed
    val duration: Long,    // seconds
    val timestamp: Long    // epoch millis
)

@Serializable
data class BridgePhoto(
    val mediaId: Long,
    val filename: String,
    val timestamp: Long,   // epoch seconds (MediaStore DATE_ADDED)
    val filePath: String   // on-device absolute path for ADB pull
)

@Serializable
data class BridgeContact(
    val contactId: Long,
    val displayName: String,
    val phoneNumbers: List<String>,
    val emails: List<String>,
    val organization: String? = null,
    val jobTitle: String? = null,
    val notes: String? = null,
    val birthday: String? = null,
    val websites: List<String> = emptyList(),
    val addresses: List<String> = emptyList()
)

@Serializable
data class BridgeContactAction(
    val dataId: Long,      // ContactsContract.Data._ID
    val mimeType: String,
    val label: String      // e.g. "Send message", "Video call"
)

@Serializable
data class BridgeContactApp(
    val packageName: String,
    val appName: String,
    val icon: String?,     // base64 PNG, nullable
    val actions: List<BridgeContactAction>
)
