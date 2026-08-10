package com.appsoflife.swipewise

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/// Safety net for the pending-reregister handoff. The normal flow is
/// boundary EXIT (driving) → pending flag → activity-recognition settle →
/// re-register. But AR transitions can lag by minutes or get dropped
/// entirely, which would strand the pending flag forever. This alarm is
/// armed alongside the flag and ticks every [DELAY_MS]:
///
///   - pending gone (AR handled it)  → no-op
///   - still driving                 → re-arm and wait another tick
///   - settled (or AR state stale)   → consume the flag, re-register
///
/// Ticks are cheap receiver wakeups; no engine spins up until we actually
/// run. Inexact alarm on purpose — a few minutes of slip is fine for a net,
/// and it needs no exact-alarm grant.
class ReregisterFallbackReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (!PendingReregister.isPending(context)) {
            return
        }
        if (ActivityState.isLikelyDriving(context)) {
            arm(context)
            return
        }
        PendingReregister.set(context, false)
        ReregisterScheduler.enqueue(context)
    }

    companion object {
        private const val DELAY_MS = 5L * 60L * 1000L

        fun arm(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + DELAY_MS,
                pendingIntent(context),
            )
        }

        private fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, ReregisterFallbackReceiver::class.java)
            return PendingIntent.getBroadcast(
                context,
                REQ_FALLBACK,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private const val REQ_FALLBACK = 3001
    }
}
