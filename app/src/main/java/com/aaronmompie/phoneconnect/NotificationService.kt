package com.aaronmompie.phoneconnect

import android.app.Notification
import android.app.NotificationManager
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class NotificationService : NotificationListenerService() {

    companion object {
        @Volatile var instance: NotificationService? = null
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i("NotificationService", "Listener connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
        Log.i("NotificationService", "Listener disconnected")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)

        val pkg = sbn?.packageName ?: return
        if (pkg == applicationContext.packageName) return

        val notification = sbn.notification ?: return

        // Skip group summary notifications (they're containers, not real content)
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return

        // Skip silent notifications using the ranking system, which accounts for user-level
        // overrides (muted conversations, per-app settings) beyond just channel importance.
        if (!isImportantEnough(sbn)) return

        val extras = notification.extras ?: return
        val title = extras.getString(Notification.EXTRA_TITLE) ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        if (title.isBlank() && text.isBlank()) return

        val service = DataBridgeService.instance ?: run {
            Log.d("NotificationService", "DataBridgeService not running — notification dropped")
            return
        }

        val actionsJson = buildActionsJson(notification.actions)

        val json = buildString {
            append("""{"type":"push_notification","pkg":"${escapeJson(pkg)}"""")
            append(""","notifKey":"${escapeJson(sbn.key)}"""")
            append(""","title":"${escapeJson(title)}"""")
            append(""","text":"${escapeJson(text)}"""")
            append(""","ts":${System.currentTimeMillis()}""")
            if (actionsJson != null) append(""","actions":$actionsJson""")
            append("}")
        }

        service.pushEvent(json)
        Log.d("NotificationService", "Forwarded from $pkg: $title")
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
    }

    /** Called by DataBridgeService when the Mac user taps a notification action. */
    fun executeAction(notifKey: String, actionIndex: Int, replyText: String?) {
        try {
            val sbn = activeNotifications?.firstOrNull { it.key == notifKey } ?: run {
                Log.w("NotificationService", "executeAction: key not found ($notifKey)")
                return
            }
            val actions = sbn.notification?.actions ?: run {
                Log.w("NotificationService", "executeAction: no actions on notification")
                return
            }
            val action = actions.getOrNull(actionIndex) ?: run {
                Log.w("NotificationService", "executeAction: actionIndex $actionIndex out of range (${actions.size})")
                return
            }

            val remoteInputs = action.remoteInputs
            if (replyText != null && !remoteInputs.isNullOrEmpty()) {
                val fillIn = Intent()
                val results = Bundle().apply {
                    for (ri in remoteInputs) putCharSequence(ri.resultKey, replyText)
                }
                RemoteInput.addResultsToIntent(remoteInputs, fillIn, results)
                action.actionIntent.send(applicationContext, 0, fillIn)
            } else {
                action.actionIntent.send()
            }
            Log.d("NotificationService", "Executed action $actionIndex on $notifKey")
        } catch (e: Exception) {
            Log.e("NotificationService", "executeAction failed: ${e.message}")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun isImportantEnough(sbn: StatusBarNotification): Boolean {
        val ranking = android.service.notification.NotificationListenerService.Ranking()
        return if (currentRanking.getRanking(sbn.key, ranking)) {
            ranking.importance >= NotificationManager.IMPORTANCE_DEFAULT
        } else {
            // Fallback: read the channel directly
            val channelId = sbn.notification.channelId ?: return false
            val importance = getSystemService(NotificationManager::class.java)
                .getNotificationChannel(channelId)?.importance
                ?: NotificationManager.IMPORTANCE_DEFAULT
            importance >= NotificationManager.IMPORTANCE_DEFAULT
        }
    }

    private fun buildActionsJson(actions: Array<Notification.Action>?): String? {
        if (actions.isNullOrEmpty()) return null
        val list = actions.take(4).mapIndexed { i, action ->
            val hasReply = action.remoteInputs?.any { it.allowFreeFormInput } ?: false
            """{"id":$i,"title":"${escapeJson(action.title?.toString() ?: "")}","hasReply":$hasReply}"""
        }
        return "[${list.joinToString(",")}]"
    }

    private fun escapeJson(s: String): String =
        s.replace("\\", "\\\\")
         .replace("\"", "\\\"")
         .replace("\n", "\\n")
         .replace("\r", "\\r")
         .replace("\t", "\\t")
}
