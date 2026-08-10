package com.appsoflife.swipewise

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/// One-shot dwell timers, one per merchant geofence. Armed on geofence
/// ENTER, cancelled on EXIT; firing wakes [DwellCheckReceiver], which
/// verifies the user is still at the fence before posting.
///
/// Uses an exact alarm when the user has granted "Alarms & reminders"
/// (SCHEDULE_EXACT_ALARM — denied by default on Android 14+), else falls
/// back to an inexact while-idle alarm. The fallback can slip by a minute
/// or two under Doze, but the device is rarely idle in the walk-into-a-store
/// scenario, so in practice it lands close to on-time either way.
///
/// PendingIntents are distinguished by Intent action ("<prefix><geofenceId>"),
/// not requestCode — extras don't participate in PendingIntent matching, so
/// a per-fence action is what makes cancel() hit the right timer.
object DwellAlarms {
    private const val ACTION_PREFIX = "com.appsoflife.swipewise.DWELL_CHECK:"

    fun arm(context: Context, geofenceId: String, dwellSeconds: Int) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pendingIntent(context, geofenceId)
        val at = SystemClock.elapsedRealtime() + dwellSeconds * 1000L
        val exact = try {
            am.canScheduleExactAlarms()
        } catch (_: Exception) {
            false
        }
        try {
            if (exact) {
                am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            }
        } catch (e: SecurityException) {
            // Exact-alarm grant revoked between check and call; degrade.
            am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
        }
    }

    fun cancel(context: Context, geofenceId: String) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context, geofenceId))
    }

    fun geofenceIdFromIntent(intent: Intent): String? =
        intent.action?.takeIf { it.startsWith(ACTION_PREFIX) }
            ?.removePrefix(ACTION_PREFIX)

    private fun pendingIntent(context: Context, geofenceId: String): PendingIntent {
        val intent = Intent(context, DwellCheckReceiver::class.java).apply {
            action = ACTION_PREFIX + geofenceId
        }
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
