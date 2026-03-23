package com.aaronmompie.phoneconnect

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.MediaStore
import android.net.Uri
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream

private data class ContactBuilder(
    val contactId: Long,
    val displayName: String,
    val phones: MutableList<String> = mutableListOf(),
    val emails: MutableList<String> = mutableListOf(),
    val websites: MutableList<String> = mutableListOf(),
    val addresses: MutableList<String> = mutableListOf(),
    var organization: String? = null,
    var jobTitle: String? = null,
    var notes: String? = null,
    var birthday: String? = null
) {
    fun build() = BridgeContact(
        contactId, displayName,
        phones.toList(), emails.toList(),
        organization, jobTitle, notes, birthday,
        websites.toList(), addresses.toList()
    )
}

object DataProviders {

    private const val TAG = "DataProviders"

    // ── SMS Threads ──────────────────────────────────────────────────────────

    fun getSmsThreads(context: Context): List<BridgeThread> {
        val threadMap = LinkedHashMap<Long, BridgeThread>()
        val uri = Uri.parse("content://sms")
        val projection = arrayOf("_id", "thread_id", "address", "body", "date", "read")

        return try {
            context.contentResolver.query(
                uri, projection, null, null, "date DESC"
            )?.use { cursor ->
                val threadIdCol = cursor.getColumnIndexOrThrow("thread_id")
                val addressCol = cursor.getColumnIndexOrThrow("address")
                val bodyCol = cursor.getColumnIndexOrThrow("body")
                val dateCol = cursor.getColumnIndexOrThrow("date")
                val readCol = cursor.getColumnIndexOrThrow("read")

                while (cursor.moveToNext() && threadMap.size < 100) {
                    val threadId = cursor.getLong(threadIdCol)
                    if (threadMap.containsKey(threadId)) continue

                    val address = cursor.getString(addressCol) ?: ""
                    val body = cursor.getString(bodyCol) ?: ""
                    val date = cursor.getLong(dateCol)
                    val read = cursor.getInt(readCol)

                    val contactName = if (address.isNotBlank()) {
                        lookupContactName(context, address) ?: address
                    } else "Unknown"

                    val unreadCount = if (read == 0) countUnreadInThread(context, threadId) else 0

                    threadMap[threadId] = BridgeThread(
                        threadId = threadId,
                        contactName = contactName,
                        contactPhone = address,
                        preview = body.take(120),
                        timestamp = date,
                        unreadCount = unreadCount
                    )
                }
            }
            threadMap.values.toList()
        } catch (e: Exception) {
            Log.e(TAG, "getSmsThreads failed: ${e.message}")
            emptyList()
        }
    }

    // ── SMS Messages ─────────────────────────────────────────────────────────

    fun getSmsMessages(context: Context, threadId: Long): List<BridgeMessage> {
        val messages = mutableListOf<BridgeMessage>()
        val uri = Uri.parse("content://sms")
        val projection = arrayOf("_id", "thread_id", "address", "body", "date", "type", "read")

        return try {
            context.contentResolver.query(
                uri, projection,
                "thread_id = ?", arrayOf(threadId.toString()),
                "date ASC LIMIT 100"
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow("_id")
                val bodyCol = cursor.getColumnIndexOrThrow("body")
                val dateCol = cursor.getColumnIndexOrThrow("date")
                val typeCol = cursor.getColumnIndexOrThrow("type")
                val readCol = cursor.getColumnIndexOrThrow("read")

                while (cursor.moveToNext()) {
                    val msgId = cursor.getLong(idCol)
                    val body = cursor.getString(bodyCol) ?: ""
                    val date = cursor.getLong(dateCol)
                    val type = cursor.getInt(typeCol)
                    val isRead = cursor.getInt(readCol) == 1
                    // type 1 = received (inbox), type 2 = sent; others (drafts, failed, etc.) also exist
                    val isFromMe = type == 2

                    messages.add(
                        BridgeMessage(
                            messageId = msgId,
                            threadId = threadId,
                            body = body,
                            isFromMe = isFromMe,
                            timestamp = date,
                            isRead = isRead
                        )
                    )
                }
            }
            messages
        } catch (e: Exception) {
            Log.e(TAG, "getSmsMessages failed: ${e.message}")
            emptyList()
        }
    }

    // ── Call Log ─────────────────────────────────────────────────────────────

    fun getCallLog(context: Context): List<BridgeCall> {
        val calls = mutableListOf<BridgeCall>()
        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.CACHED_NAME,
            CallLog.Calls.TYPE,
            CallLog.Calls.DURATION,
            CallLog.Calls.DATE
        )

        return try {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                projection, null, null,
                "${CallLog.Calls.DATE} DESC"
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(CallLog.Calls._ID)
                val numberCol = cursor.getColumnIndexOrThrow(CallLog.Calls.NUMBER)
                val nameCol = cursor.getColumnIndexOrThrow(CallLog.Calls.CACHED_NAME)
                val typeCol = cursor.getColumnIndexOrThrow(CallLog.Calls.TYPE)
                val durationCol = cursor.getColumnIndexOrThrow(CallLog.Calls.DURATION)
                val dateCol = cursor.getColumnIndexOrThrow(CallLog.Calls.DATE)

                while (cursor.moveToNext() && calls.size < 100) {
                    val id = cursor.getLong(idCol)
                    val number = cursor.getString(numberCol) ?: ""
                    val cachedName = cursor.getString(nameCol)
                    val type = cursor.getInt(typeCol)
                    val duration = cursor.getLong(durationCol)
                    val date = cursor.getLong(dateCol)

                    calls.add(
                        BridgeCall(
                            callId = id,
                            number = number,
                            contactName = if (cachedName.isNullOrBlank()) null else cachedName,
                            callType = type,
                            duration = duration,
                            timestamp = date
                        )
                    )
                }
            }
            calls
        } catch (e: Exception) {
            Log.e(TAG, "getCallLog failed: ${e.message}")
            emptyList()
        }
    }

    // ── Photos ───────────────────────────────────────────────────────────────

    @Suppress("DEPRECATION")
    fun getPhotos(context: Context, offset: Int = 0, limit: Int = 50): List<BridgePhoto> {
        val photos = mutableListOf<BridgePhoto>()
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.DATA          // on-device path for ADB pull
        )

        return try {
            context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection, null, null,
                "${MediaStore.Images.Media.DATE_ADDED} DESC"
            )?.use { cursor ->
                val idCol   = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                val pathCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)

                // Jump to offset using cursor positioning (O(1) for SQLite-backed cursors)
                cursor.moveToPosition(offset - 1)
                while (cursor.moveToNext() && photos.size < limit) {
                    val id   = cursor.getLong(idCol)
                    val name = cursor.getString(nameCol) ?: "Photo"
                    val date = cursor.getLong(dateCol)
                    val path = cursor.getString(pathCol) ?: ""
                    photos.add(BridgePhoto(mediaId = id, filename = name, timestamp = date, filePath = path))
                }
            }
            photos
        } catch (e: Exception) {
            Log.e(TAG, "getPhotos failed: ${e.message}")
            emptyList()
        }
    }

    // ── Thumbnail ────────────────────────────────────────────────────────────

    fun getThumbnail(context: Context, mediaId: Long): String? {
        return try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId
            )
            val bitmap: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.contentResolver.loadThumbnail(uri, android.util.Size(200, 200), null)
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Images.Thumbnails.getThumbnail(
                    context.contentResolver, mediaId,
                    MediaStore.Images.Thumbnails.MINI_KIND, null
                )
            }

            bitmap?.let {
                val baos = ByteArrayOutputStream()
                it.compress(Bitmap.CompressFormat.JPEG, 80, baos)
                it.recycle()
                Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
            }
        } catch (e: Exception) {
            Log.w(TAG, "getThumbnail failed for mediaId=$mediaId: ${e.message}")
            null
        }
    }

    // ── Mark thread as read ──────────────────────────────────────────────────

    fun markThreadRead(context: Context, threadId: Long) {
        try {
            val values = android.content.ContentValues().apply { put("read", 1) }
            context.contentResolver.update(
                Uri.parse("content://sms"),
                values,
                "thread_id = ? AND read = 0",
                arrayOf(threadId.toString())
            )
        } catch (e: Exception) {
            // Expected to fail on Android 9+ if we're not the default SMS app — that's OK
            Log.d(TAG, "markThreadRead: ${e.message}")
        }
    }

    // ── SMS new-message helper ───────────────────────────────────────────────

    fun getLatestSmsThreadId(context: Context): Long {
        return try {
            context.contentResolver.query(
                Uri.parse("content://sms"),
                arrayOf("thread_id"),
                null, null, "date DESC LIMIT 1"
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getLong(0) else -1L
            } ?: -1L
        } catch (e: Exception) { -1L }
    }

    // ── Contacts ─────────────────────────────────────────────────────────────

    fun getContacts(context: Context): List<BridgeContact> {
        val contactMap = LinkedHashMap<Long, ContactBuilder>()

        return try {
            // Collect phone numbers grouped by contact (sorted by display name)
            val phoneProj = arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER
            )
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                phoneProj, null, null,
                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"
            )?.use { cursor ->
                val idCol   = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
                val nameCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numCol  = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)

                while (cursor.moveToNext() && contactMap.size < 500) {
                    val cid    = cursor.getLong(idCol)
                    val name   = cursor.getString(nameCol) ?: continue
                    val number = cursor.getString(numCol)  ?: continue
                    val builder = contactMap.getOrPut(cid) { ContactBuilder(cid, name) }
                    if (!builder.phones.contains(number)) builder.phones.add(number)
                }
            }

            // Collect emails for contacts already in the map
            val emailProj = arrayOf(
                ContactsContract.CommonDataKinds.Email.CONTACT_ID,
                ContactsContract.CommonDataKinds.Email.ADDRESS
            )
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                emailProj, null, null, null
            )?.use { cursor ->
                val idCol    = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Email.CONTACT_ID)
                val emailCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Email.ADDRESS)

                while (cursor.moveToNext()) {
                    val cid   = cursor.getLong(idCol)
                    val email = cursor.getString(emailCol) ?: continue
                    contactMap[cid]?.emails?.add(email)
                }
            }

            // Organisation
            context.contentResolver.query(
                ContactsContract.Data.CONTENT_URI,
                arrayOf(ContactsContract.Data.CONTACT_ID,
                        ContactsContract.CommonDataKinds.Organization.COMPANY,
                        ContactsContract.CommonDataKinds.Organization.TITLE),
                "${ContactsContract.Data.MIMETYPE} = ?",
                arrayOf(ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE), null
            )?.use { cursor ->
                val idCol  = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
                val orgCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Organization.COMPANY)
                val ttlCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Organization.TITLE)
                while (cursor.moveToNext()) {
                    val cid = cursor.getLong(idCol)
                    val b   = contactMap[cid] ?: continue
                    if (b.organization == null) {
                        b.organization = cursor.getString(orgCol)?.takeIf { it.isNotBlank() }
                        b.jobTitle     = cursor.getString(ttlCol)?.takeIf { it.isNotBlank() }
                    }
                }
            }

            // Notes
            context.contentResolver.query(
                ContactsContract.Data.CONTENT_URI,
                arrayOf(ContactsContract.Data.CONTACT_ID, ContactsContract.CommonDataKinds.Note.NOTE),
                "${ContactsContract.Data.MIMETYPE} = ?",
                arrayOf(ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE), null
            )?.use { cursor ->
                val idCol   = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
                val noteCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Note.NOTE)
                while (cursor.moveToNext()) {
                    val cid  = cursor.getLong(idCol)
                    val note = cursor.getString(noteCol)?.trim()
                    if (!note.isNullOrBlank()) contactMap[cid]?.notes = note
                }
            }

            // Birthday
            context.contentResolver.query(
                ContactsContract.Data.CONTENT_URI,
                arrayOf(ContactsContract.Data.CONTACT_ID, ContactsContract.CommonDataKinds.Event.START_DATE),
                "${ContactsContract.Data.MIMETYPE} = ? AND ${ContactsContract.CommonDataKinds.Event.TYPE} = ?",
                arrayOf(ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE,
                        ContactsContract.CommonDataKinds.Event.TYPE_BIRTHDAY.toString()), null
            )?.use { cursor ->
                val idCol   = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
                val dateCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Event.START_DATE)
                while (cursor.moveToNext()) {
                    val cid  = cursor.getLong(idCol)
                    val date = cursor.getString(dateCol)?.takeIf { it.isNotBlank() }
                    if (date != null) contactMap[cid]?.birthday = date
                }
            }

            // Websites
            context.contentResolver.query(
                ContactsContract.Data.CONTENT_URI,
                arrayOf(ContactsContract.Data.CONTACT_ID, ContactsContract.CommonDataKinds.Website.URL),
                "${ContactsContract.Data.MIMETYPE} = ?",
                arrayOf(ContactsContract.CommonDataKinds.Website.CONTENT_ITEM_TYPE), null
            )?.use { cursor ->
                val idCol  = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
                val urlCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Website.URL)
                while (cursor.moveToNext()) {
                    val cid = cursor.getLong(idCol)
                    val url = cursor.getString(urlCol)?.takeIf { it.isNotBlank() } ?: continue
                    contactMap[cid]?.websites?.add(url)
                }
            }

            // Addresses
            context.contentResolver.query(
                ContactsContract.Data.CONTENT_URI,
                arrayOf(ContactsContract.Data.CONTACT_ID, ContactsContract.CommonDataKinds.StructuredPostal.FORMATTED_ADDRESS),
                "${ContactsContract.Data.MIMETYPE} = ?",
                arrayOf(ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE), null
            )?.use { cursor ->
                val idCol   = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
                val addrCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.StructuredPostal.FORMATTED_ADDRESS)
                while (cursor.moveToNext()) {
                    val cid  = cursor.getLong(idCol)
                    val addr = cursor.getString(addrCol)?.takeIf { it.isNotBlank() } ?: continue
                    contactMap[cid]?.addresses?.add(addr)
                }
            }

            contactMap.values.map { it.build() }
        } catch (e: Exception) {
            Log.e(TAG, "getContacts failed: ${e.message}")
            emptyList()
        }
    }

    // ── Contact Apps (connected third-party apps) ─────────────────────────────

    fun getContactId(context: Context, phone: String): Long? {
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone)
        )
        return try {
            context.contentResolver.query(
                uri, arrayOf(ContactsContract.PhoneLookup._ID), null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getLong(0) else null
            }
        } catch (e: Exception) { null }
    }

    fun getContactApps(context: Context, phone: String, contactName: String? = null): List<BridgeContactApp> {
        val contactId = getContactId(context, phone) ?: return emptyList()

        val projection = arrayOf(
            ContactsContract.Data._ID,
            ContactsContract.Data.MIMETYPE,
            ContactsContract.Data.DATA3
        )
        val selection = "${ContactsContract.Data.CONTACT_ID} = ? AND ${ContactsContract.Data.MIMETYPE} LIKE ?"
        val selectionArgs = arrayOf(contactId.toString(), "vnd.android.cursor.item/vnd.%")

        data class DataRow(val dataId: Long, val mimeType: String, val label: String)
        val rows = mutableListOf<DataRow>()

        try {
            context.contentResolver.query(
                ContactsContract.Data.CONTENT_URI, projection, selection, selectionArgs, null
            )?.use { cursor ->
                val idCol    = cursor.getColumnIndexOrThrow(ContactsContract.Data._ID)
                val mimeCol  = cursor.getColumnIndexOrThrow(ContactsContract.Data.MIMETYPE)
                val labelCol = cursor.getColumnIndex(ContactsContract.Data.DATA3)
                while (cursor.moveToNext()) {
                    val dataId   = cursor.getLong(idCol)
                    val mimeType = cursor.getString(mimeCol) ?: continue
                    val label    = if (labelCol >= 0) cursor.getString(labelCol) ?: "" else ""
                    rows.add(DataRow(dataId, mimeType, label))
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getContactApps query failed: ${e.message}")
            return emptyList()
        }

        val appActions = LinkedHashMap<String, MutableList<BridgeContactAction>>()
        val appNames   = LinkedHashMap<String, String>()

        for ((dataId, mimeType, rawLabel) in rows) {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(
                    ContentUris.withAppendedId(ContactsContract.Data.CONTENT_URI, dataId),
                    mimeType
                )
            }
            // Use queryIntentActivities + MATCH_ALL so Android 11+ package visibility
            // restrictions don't hide Signal and other apps that aren't in <queries>.
            val resolveList = try {
                @Suppress("DEPRECATION")
                context.packageManager.queryIntentActivities(intent, android.content.pm.PackageManager.MATCH_ALL)
            } catch (e: Exception) { emptyList() }
            val info = resolveList.firstOrNull() ?: continue

            val pkg     = info.activityInfo.packageName
            val appName = info.loadLabel(context.packageManager).toString()
            appNames[pkg] = appName
            // Replace trailing phone number with contact name, or strip it
            val cleanLabel = if (!contactName.isNullOrBlank()) {
                rawLabel.replace(Regex("""([\s\u00A0]+)\+?[\d\s\-().]{6,}$"""), " $contactName")
                    .trim()
            } else {
                rawLabel.replace(Regex("""[\s\u00A0]+\+?[\d\s\-().]{6,}$"""), "").trim()
            }
            val label = cleanLabel.ifBlank { mimeType.substringAfterLast('.') }
            appActions.getOrPut(pkg) { mutableListOf() }
                .add(BridgeContactAction(dataId, mimeType, label))
        }

        return appActions.entries.mapNotNull { (pkg, actions) ->
            val appName = appNames[pkg] ?: return@mapNotNull null
            val icon = try {
                val drawable = context.packageManager.getApplicationIcon(pkg)
                val bitmap = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                drawable.setBounds(0, 0, 48, 48)
                drawable.draw(canvas)
                val baos = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, baos)
                bitmap.recycle()
                val bytes = baos.toByteArray()
                if (bytes.size <= 6144) Base64.encodeToString(bytes, Base64.NO_WRAP) else null
            } catch (e: Exception) { null }
            BridgeContactApp(pkg, appName, icon, actions)
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun lookupContactName(context: Context, phone: String): String? {
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

    private fun countUnreadInThread(context: Context, threadId: Long): Int {
        return try {
            val cursor = context.contentResolver.query(
                Uri.parse("content://sms"),
                arrayOf("_id"),
                "thread_id = ? AND read = 0",
                arrayOf(threadId.toString()), null
            )
            val count = cursor?.count ?: 0
            cursor?.close()
            count
        } catch (e: Exception) { 0 }
    }
}
