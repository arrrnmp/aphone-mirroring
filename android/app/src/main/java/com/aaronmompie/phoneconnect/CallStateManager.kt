package com.aaronmompie.phoneconnect

import android.content.Context
import android.net.Uri
import android.provider.ContactsContract
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Listens for phone call state changes and pushes call_state events to the Mac
 * via DataBridgeService.pushEvent().
 *
 * Supports RINGING (with caller ID), OFFHOOK (active/outgoing), and IDLE.
 */
@Suppress("DEPRECATION")
class CallStateManager(private val context: Context) {

    private val telephonyManager = context.getSystemService(TelephonyManager::class.java)
    private var listener: PhoneStateListener? = null
    private var lastNumber: String = ""

    fun start() {
        val l = object : PhoneStateListener() {
            override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                handleStateChange(state, phoneNumber)
            }
        }
        listener = l
        @Suppress("DEPRECATION")
        telephonyManager.listen(l, PhoneStateListener.LISTEN_CALL_STATE)
        Log.i("CallStateManager", "Phone state listener registered")
    }

    fun stop() {
        listener?.let { telephonyManager.listen(it, PhoneStateListener.LISTEN_NONE) }
        listener = null
        lastNumber = ""
        Log.i("CallStateManager", "Phone state listener unregistered")
    }

    private fun handleStateChange(state: Int, phoneNumber: String?) {
        val json = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                val number = phoneNumber ?: ""
                lastNumber = number
                val name = lookupContactName(number)
                val nameValue = if (name != null) "\"${escapeJson(name)}\"" else "null"
                "{\"type\":\"call_state\",\"state\":\"ringing\",\"number\":\"${escapeJson(number)}\",\"contactName\":$nameValue}"
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                val number = if (!phoneNumber.isNullOrBlank()) phoneNumber else lastNumber
                lastNumber = number
                val name = lookupContactName(number)
                val nameValue = if (name != null) "\"${escapeJson(name)}\"" else "null"
                "{\"type\":\"call_state\",\"state\":\"active\",\"number\":\"${escapeJson(number)}\",\"contactName\":$nameValue}"
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                lastNumber = ""
                "{\"type\":\"call_state\",\"state\":\"idle\",\"number\":\"\",\"contactName\":null}"
            }
            else -> return
        }

        DataBridgeService.instance?.pushEvent(json)
        Log.d("CallStateManager", "State changed: $json")
    }

    private fun lookupContactName(phone: String): String? {
        if (phone.isBlank()) return null
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(phone)
            )
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (e: Exception) { null }
    }

    private fun escapeJson(s: String): String =
        s.replace("\\", "\\\\")
         .replace("\"", "\\\"")
         .replace("\n", "\\n")
         .replace("\r", "\\r")
         .replace("\t", "\\t")
}
