package com.appsoflife.swipewise

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/**
 * Method-channel entry point for the in-Dart `LinkProgressNotifier`.
 * Delegates notification ownership to [LinkSyncForegroundService] —
 * the service holds the foreground notification (and, crucially,
 * keeps the Flutter process out of Doze / App Standby) for the whole
 * link → first-runSync window. This plugin's only job here is to
 * declare the notification channel and translate Dart method calls
 * into service Intents.
 *
 * Notification semantics (carried over from the previous standalone
 * implementation, now enforced inside the service):
 *  - one ongoing notification at a fixed id, updated in-place,
 *  - status-only transitions (polling, submitting) silent,
 *  - actionable stages (security question, OTP, captcha, token
 *    approval) and terminals (success / failure) fire sound +
 *    vibration via `setOnlyAlertOnce(false)`.
 *
 * The channel itself is `IMPORTANCE_HIGH` so the OS allows alerts at
 * all; the per-update `setOnlyAlertOnce` flag controls whether each
 * specific update fires the alert. This avoids creating two separate
 * channels (one silent, one loud) and the user-visible churn of
 * cancelling/reposting across them.
 *
 * Tapping the notification brings the app's `MainActivity` back to the
 * foreground; the Add Bank screen is already the topmost route when the
 * link is in flight, so no deep-link routing is needed.
 */
class LinkProgressPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        ensureChannel()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> {
                val title = call.argument<String>("title") ?: "Linking your bank"
                val body = call.argument<String>("body") ?: ""
                val alert = call.argument<Boolean>("alert") ?: false
                val ongoing = call.argument<Boolean>("ongoing") ?: true
                val indeterminate = call.argument<Boolean>("indeterminate") ?: true
                LinkSyncForegroundService.start(
                    context = context,
                    title = title,
                    body = body,
                    alert = alert,
                    ongoing = ongoing,
                    indeterminate = indeterminate,
                )
                result.success(null)
            }
            "dismiss" -> {
                LinkSyncForegroundService.stop(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureChannel() {
        // Channels arrived in API 26; below that NotificationCompat posts without one.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Bank link progress",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description =
                    "Status of an in-progress bank link, including when a " +
                    "security question, code, or approval is waiting on you."
                enableVibration(true)
                setShowBadge(false)
            }
            nm.createNotificationChannel(ch)
        }
    }

    companion object {
        const val CHANNEL = "com.appsoflife/link_progress"
        const val CHANNEL_ID = "swipewise_link_progress"
        // Fixed Int id so every `show` call lands on the same
        // notification (updated in-place by the service) and `dismiss`
        // cancels by the same id. Shared with
        // [LinkSyncForegroundService] so the foreground tile and the
        // refresh-tile collapse into one row.
        const val NOTIF_ID = 4001
    }
}
