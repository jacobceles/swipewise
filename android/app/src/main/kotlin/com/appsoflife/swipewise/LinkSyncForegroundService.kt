package com.appsoflife.swipewise

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Foreground service that keeps the Flutter process alive (and its
 * network stack out of Doze) for the duration of an in-app bank link
 * plus the immediately-following first runSync.
 *
 * The link flow is in-Dart polling — Sophtron's v2 API requires us to
 * call `getJobInfo` every ~2s to spot MFA prompts and the eventual
 * success/failure terminal. If the user backgrounds the app, Android
 * suspends sockets and DNS within seconds (App Standby / Doze
 * lite). The polling Dart code then sees `Failed host lookup` until
 * the user returns, which means stage-change notifications can't fire
 * because we never observe the stage change in the first place.
 *
 * A foreground service is the canonical Android workaround: as long
 * as it's running with `startForeground()` called within 5s of start,
 * the OS won't freeze the process. The same persistent notification
 * we already show via [LinkProgressPlugin] doubles as the
 * service's foreground notification — one persistent UI surface, no
 * second tile.
 *
 * Lifecycle:
 *   - [LinkProgressPlugin.show] routes through here. The first `show`
 *     starts the service; subsequent ones update the notification
 *     in-place.
 *   - [LinkProgressPlugin.dismiss] sends `ACTION_STOP` → the service
 *     stops and removes its notification.
 *   - If the user swipe-kills the app, [onTaskRemoved] stops the
 *     service so we don't leave a zombie notification or persistent
 *     foreground tile behind. The in-Dart flow state is gone with the
 *     process anyway; the next app launch will pick up wherever
 *     Sophtron is now.
 */
class LinkSyncForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stop()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Linking your bank"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: ""
        val alert = intent?.getBooleanExtra(EXTRA_ALERT, false) ?: false
        val ongoing = intent?.getBooleanExtra(EXTRA_ONGOING, true) ?: true
        val indeterminate = intent?.getBooleanExtra(EXTRA_INDETERMINATE, true) ?: true

        val notification = buildNotification(
            title = title,
            body = body,
            alert = alert,
            ongoing = ongoing,
            indeterminate = indeterminate,
        )
        // First call needs `startForeground` within 5s of `startForegroundService`.
        // Subsequent calls just refresh the same notification id and are no-ops
        // for the service's foreground state — but calling `startForeground`
        // again is harmless and ensures we stay foreground if the OS dropped us.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                LinkProgressPlugin.NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(LinkProgressPlugin.NOTIF_ID, notification)
        }
        // If the OS kills us, don't restart — the in-Dart flow state is gone
        // with the process and a phantom service tile would just confuse.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // User swiped the app away. The Dart isolate is being torn down;
        // there's nothing left to keep alive. Stop cleanly so we don't
        // leak the foreground notification past app death.
        stop()
        super.onTaskRemoved(rootIntent)
    }

    private fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        NotificationManagerCompat.from(this).cancel(LinkProgressPlugin.NOTIF_ID)
        stopSelf()
    }

    private fun buildNotification(
        title: String,
        body: String,
        alert: Boolean,
        ongoing: Boolean,
        indeterminate: Boolean,
    ): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            PI_OPEN,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, LinkProgressPlugin.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setContentIntent(contentIntent)
            // Inverse of the Dart `alert` flag so silent ticks pass through
            // quietly while actionable stage-changes ring. Same scheme as
            // the LinkProgressPlugin standalone path so behavior is
            // identical whether or not the service is running.
            .setOnlyAlertOnce(!alert)
        if (indeterminate) {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    companion object {
        const val ACTION_START = "com.appsoflife.linksync.START"
        const val ACTION_STOP = "com.appsoflife.linksync.STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_ALERT = "alert"
        const val EXTRA_ONGOING = "ongoing"
        const val EXTRA_INDETERMINATE = "indeterminate"

        private const val PI_OPEN = 71

        fun start(
            context: Context,
            title: String,
            body: String,
            alert: Boolean,
            ongoing: Boolean,
            indeterminate: Boolean,
        ) {
            val intent = Intent(context, LinkSyncForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
                putExtra(EXTRA_ALERT, alert)
                putExtra(EXTRA_ONGOING, ongoing)
                putExtra(EXTRA_INDETERMINATE, indeterminate)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, LinkSyncForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            // `startService` (not `startForegroundService`) — STOP is just
            // a one-shot signal, not a foreground-warranting call.
            context.startService(intent)
        }
    }
}
