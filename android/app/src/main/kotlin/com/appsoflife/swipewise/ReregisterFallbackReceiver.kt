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
/// armed at the persisted deadline and re-arms while recovery remains owed:
///
///   - pending gone (AR handled it)  → no-op
///   - still driving                 → re-arm and wait another tick
///   - settled (or AR state stale)   → enqueue, retain until its generation succeeds
///
/// Ticks are cheap receiver wakeups; no engine spins up until we actually
/// run. Inexact alarm on purpose — a few minutes of slip is fine for a net,
/// and it needs no exact-alarm grant.
class ReregisterFallbackReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (!PendingReregister.isPending(context)) {
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (now < PendingReregister.due(context, now)) {
            arm(context)
            return
        }
        if (ActivityState.isLikelyDriving(context)) {
            PendingReregister.defer(context, FootReregister.COOLDOWN_MS)
            return
        }
        val remaining = FootReregister.remaining(context, now)
        if (remaining > 0L) {
            PendingReregister.defer(context, remaining)
            return
        }
        FootReregister.mark(context, now)
        PendingReregister.defer(context, FootReregister.COOLDOWN_MS)
        ReregisterScheduler.enqueue(context)
    }

    companion object {
        fun cancel(context: Context) {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pendingIntent(context))
        }

        fun arm(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                maxOf(SystemClock.elapsedRealtime(), PendingReregister.due(context)),
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
