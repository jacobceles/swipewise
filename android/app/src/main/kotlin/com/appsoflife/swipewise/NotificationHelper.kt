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
import java.util.Locale

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

    /// True means submitted to Android, not proof of presentation or audibility.
    fun postDwell(meta: MerchantMeta, verifiedAtMillis: Long = System.currentTimeMillis()): Boolean {
        val age = System.currentTimeMillis() - verifiedAtMillis
        if (age !in 0 until ARRIVAL_TTL_MS) return false
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
            title = "You're near ${opt.name}"
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
            .setWhen(verifiedAtMillis)
            .setTimeoutAfter(ARRIVAL_TTL_MS - age)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        return try {
            cancelDwell(context)
            nm.notify(ARRIVAL_TAG, 0, notification)
            val channel = nm.getNotificationChannel(CHANNEL_ID)
            WalkinLog.w(context, "notification submitted age_ms=$age importance=${channel?.importance} " +
                "sound=${channel?.sound != null} vibration=${channel?.shouldVibrate()}")
            true
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted on Android 13+.
            false
        }
    }

    private fun cardLine(opt: MerchantOption): String {
        if (opt.bestCardName.isNullOrEmpty()) return "Open SwipeWise to see the best card here."
        val rate = opt.bestRate?.let { formatRate(it, opt.bestCurrency) }
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

    companion object {
        const val CHANNEL_ID = "swipewise_dwell"
        const val EXTRA_OPTIONS_JSON = "swipewise.options_json"
        const val ARRIVAL_TTL_MS = 30L * 60_000L
        private const val ARRIVAL_TAG = "swipewise.arrival"

        fun cancelDwell(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                // No channel IDs before Android 8: cancel only our known arrival.
                nm.cancel(ARRIVAL_TAG, 0)
                return
            }
            // Channel IDs also identify older per-merchant-ID arrivals without
            // cancelling payment reminders or bank-link progress.
            nm.activeNotifications.filter { it.notification.channelId == CHANNEL_ID }
                .forEach { nm.cancel(it.tag, it.id) }
        }

        /// "5%" for cash back, "5x points" / "2x miles" for a programme. A
        /// points card used to read "5%" (2026-10-19). Locale.US so a French
        /// phone doesn't print "1,5%".
        fun formatRate(rate: Double, currency: String?): String {
            val whole = rate.toLong()
            val n = if (rate == whole.toDouble()) "$whole" else String.format(Locale.US, "%.1f", rate)
            return when (currency) {
                "POINTS" -> "${n}x points"
                "MILES" -> "${n}x miles"
                else -> "$n%"
            }
        }
    }
}
