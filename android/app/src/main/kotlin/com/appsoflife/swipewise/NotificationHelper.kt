package com.appsoflife.swipewise

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray

class NotificationHelper(private val context: Context) {

    init {
        ensureChannel()
    }

    private fun ensureChannel() {
        // Channels arrived in API 26; below that NotificationCompat posts without one.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Card recommendations",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Notifies you which card to use when you arrive at a store."
            }
            nm.createNotificationChannel(channel)
        }
    }

    /// False when the notification can't be shown (notifications or this
    /// channel turned off, permission missing), so the caller doesn't count a
    /// silent drop as the visit's alert.
    fun postDwell(meta: MerchantMeta): Boolean {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE
        ) {
            return false
        }
        val title: String
        val body: String
        if (meta.isCluster && meta.usualFirst) {
            // The user picked this store here before; the others stay one tap away.
            val opt = meta.primary
            title = "You're probably at ${opt.name}"
            body = "${cardLine(opt)} · or ${meta.options.drop(1).joinToString(", ") { it.name }} — tap to switch"
        } else if (meta.isCluster) {
            val names = meta.options.map { it.name }
            title = "You may be at one of these"
            body = formatClusterBody(names)
        } else {
            val opt = meta.primary
            title = "You're at ${opt.name}"
            body = cardLine(opt)
        }

        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            // Always carry the full options list as JSON so the Dart side can
            // pick the right destination (single → reward sheet, cluster →
            // disambiguation sheet).
            putExtra(EXTRA_OPTIONS_JSON, optionsJson(meta.options))
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            meta.primary.merchantId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_map)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        return try {
            nm.notify(meta.primary.merchantId.hashCode(), notification)
            true
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted on Android 13+.
            false
        }
    }

    private fun cardLine(opt: MerchantOption): String {
        if (opt.bestCardName.isNullOrEmpty()) return "Open SwipeWise to see the best card here."
        val rate = opt.bestRate?.let { formatRate(it) }
        return if (rate != null) "Use ${opt.bestCardName} for $rate" else "Use ${opt.bestCardName}"
    }

    private fun formatClusterBody(names: List<String>): String {
        if (names.size <= 2) return "${names.joinToString(" or ")} — tap to pick"
        val front = names.dropLast(1).joinToString(", ")
        return "$front, or ${names.last()} — tap to pick"
    }

    private fun optionsJson(options: List<MerchantOption>): String {
        val arr = JSONArray()
        for (o in options) arr.put(o.toJson())
        return arr.toString()
    }

    private fun formatRate(rate: Double): String {
        val whole = rate.toLong()
        return if (rate == whole.toDouble()) "$whole%" else String.format("%.1f%%", rate)
    }

    companion object {
        const val CHANNEL_ID = "swipewise_dwell"
        const val EXTRA_OPTIONS_JSON = "swipewise.options_json"
    }
}
