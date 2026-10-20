package com.appsoflife.swipewise

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
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
///
/// A timer already counting down is left alone on a repeat ENTER: indoor fixes
/// drift across the fence edge, and re-arming on every ENTER restarted the
/// countdown so a flapping fence could never fire. Due times are kept in prefs
/// (wall clock), cleared on fire, cancel and boot.
object DwellAlarms {
    private const val ACTION_PREFIX = "com.appsoflife.swipewise.DWELL_CHECK:"
    private const val EXTRA_RECHECK = "recheck"
    private const val EXTRA_NEXT_DOOR = "next_door"
    private const val PREFS = "swipewise_dwell_armed"

    fun isArmed(context: Context, geofenceId: String): Boolean =
        prefs(context).getLong(geofenceId, 0L) > System.currentTimeMillis()

    /// [recheck]: this is the second and last look after the first one found
    /// the user still moving (see [DwellCheckReceiver]). [nextDoor]: armed by
    /// the user settling during a visit, not by a fence ENTER, so it must not
    /// count towards [ResidentGuard].
    fun arm(
        context: Context,
        geofenceId: String,
        dwellSeconds: Int,
        recheck: Boolean = false,
        nextDoor: Boolean = false,
    ) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pendingIntent(context, geofenceId, recheck, nextDoor)
        val at = SystemClock.elapsedRealtime() + dwellSeconds * 1000L
        prefs(context).edit()
            .putLong(geofenceId, System.currentTimeMillis() + dwellSeconds * 1000L)
            .apply()
        // canScheduleExactAlarms() is API 31+. Below that, exact alarms need no
        // permission, so the answer is simply yes. The try/catch below it does NOT
        // stand in for this check: calling a method that does not exist throws
        // NoSuchMethodError, an Error rather than an Exception, so it goes uncaught.
        val exact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                am.canScheduleExactAlarms()
            } catch (_: Exception) {
                false
            }
        } else {
            true
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
        markFired(context, geofenceId)
    }

    fun markFired(context: Context, geofenceId: String) {
        prefs(context).edit().remove(geofenceId).apply()
    }

    /// A reboot drops every alarm.
    fun clearAll(context: Context) {
        prefs(context).edit().clear().apply()
    }

    fun geofenceIdFromIntent(intent: Intent): String? =
        intent.action?.takeIf { it.startsWith(ACTION_PREFIX) }
            ?.removePrefix(ACTION_PREFIX)

    fun isRecheck(intent: Intent): Boolean = intent.getBooleanExtra(EXTRA_RECHECK, false)

    fun isNextDoor(intent: Intent): Boolean = intent.getBooleanExtra(EXTRA_NEXT_DOOR, false)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun pendingIntent(
        context: Context,
        geofenceId: String,
        recheck: Boolean = false,
        nextDoor: Boolean = false,
    ): PendingIntent {
        // Extras don't take part in matching, and FLAG_UPDATE_CURRENT replaces
        // them, so a plain ENTER arm always resets the recheck flag.
        val intent = Intent(context, DwellCheckReceiver::class.java).apply {
            action = ACTION_PREFIX + geofenceId
            putExtra(EXTRA_RECHECK, recheck)
            putExtra(EXTRA_NEXT_DOOR, nextDoor)
        }
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
