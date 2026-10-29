package com.appsoflife.swipewise

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager

/// Enqueues the one-shot geofence re-registration [ReregisterWorker].
/// Shared by [BoundaryGeofenceReceiver] (crossed into a new area),
/// [ActivityTransitionReceiver] (settled after a drive), and
/// [ReregisterFallbackReceiver] (safety-net alarm) so the WorkManager
/// wiring lives in one place.
///
/// Expedited: a plain OneTimeWorkRequest can be deferred for minutes under
/// Doze/battery-saver — fatal here, because the whole point is fencing the
/// stores around the user *before* they walk into one. Expedited jobs run
/// near-immediately; if the app's expedited quota is exhausted the request
/// silently degrades to a normal one instead of being dropped.
object ReregisterScheduler {
    const val UNIQUE_WORK = "swipewise.geofence.reregister"
    @Volatile var enqueueOverride: ((Context) -> Unit)? = null

    /// Every reregister path needs the Places API to find nearby merchants, so
    /// gate the work on connectivity: WorkManager defers it until a network is
    /// available instead of firing offline only to fail and burn a retry. Shared
    /// with [BootReceiver] and [MainActivity]'s periodic validation.
    val networkConstraints: Constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun enqueue(context: Context) {
        enqueueOverride?.let { it(context); return }
        val request = OneTimeWorkRequestBuilder<ReregisterWorker>()
            .setConstraints(networkConstraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        // Never interrupt a running engine or accumulate headless engines.
        // Persisted generation/deadline state keeps later recovery owed.
        WorkManager.getInstance(context).enqueueUniqueWork(
            UNIQUE_WORK,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }
}

/// When the last re-registration on foot (boundary EXIT, not driving) ran.
/// In a dense area the boundary is only ~300 m, so walking — or slow city
/// traffic that activity recognition calls walking — crossed it every minute
/// and ran a fresh Places search each time (4 in 4 min, 2026-10-17).
object FootReregister {
    const val COOLDOWN_MS = 5L * 60L * 1000L
    private const val PREFS = "swipewise_reregister"
    private const val KEY_AT = "foot_at"

    fun tooSoon(context: Context, nowMillis: Long): Boolean =
        remaining(context, nowMillis) > 0L

    fun remaining(context: Context, nowMillis: Long = android.os.SystemClock.elapsedRealtime()): Long {
        val p = prefs(context)
        if (p.getInt("foot_boot", -1) != BootIdentity.getBootCount(context)) return 0L
        return (p.getLong(KEY_AT, -COOLDOWN_MS) + COOLDOWN_MS - nowMillis).coerceIn(0L, COOLDOWN_MS)
    }

    fun mark(context: Context, nowMillis: Long) {
        prefs(context).edit().putLong(KEY_AT, nowMillis)
            .putInt("foot_boot", BootIdentity.getBootCount(context)).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/// Recovery stays owed until a registration for its generation succeeds.
object PendingReregister {
    private const val PREFS = "swipewise_reregister"
    private const val KEY_PENDING = "pending"

    fun set(context: Context, pending: Boolean) {
        if (pending) request(context, FootReregister.COOLDOWN_MS, "recovery")
        else complete(context, generation(context))
    }

    fun generation(context: Context): Long = prefs(context).getLong("generation", 0L)

    fun forceRecovery(context: Context): Boolean = prefs(context).getBoolean("force", false)

    fun due(context: Context, now: Long = android.os.SystemClock.elapsedRealtime()): Long {
        val p = prefs(context)
        return if (p.getInt("boot", -1) == BootIdentity.getBootCount(context)) p.getLong("due", now) else now
    }

    fun request(context: Context, delayMs: Long, reason: String, force: Boolean = false,
        now: Long = android.os.SystemClock.elapsedRealtime()): Long {
        val p = prefs(context)
        val next = generation(context) + 1L
        val deadline = if (isPending(context)) minOf(due(context, now), now + delayMs) else now + delayMs
        p.edit().putBoolean(KEY_PENDING, true).putLong("generation", next)
            .putLong("due", deadline).putString("reason", reason)
            .putInt("boot", BootIdentity.getBootCount(context))
            .putBoolean("force", force || forceRecovery(context)).commit()
        ReregisterFallbackReceiver.arm(context)
        return next
    }

    fun defer(context: Context, delayMs: Long, now: Long = android.os.SystemClock.elapsedRealtime()) {
        prefs(context).edit().putLong("due", now + delayMs)
            .putInt("boot", BootIdentity.getBootCount(context)).commit()
        ReregisterFallbackReceiver.arm(context)
    }

    fun complete(context: Context, expectedGeneration: Long): Boolean {
        if (generation(context) != expectedGeneration) return false
        prefs(context).edit().putBoolean(KEY_PENDING, false).remove("due").remove("force").remove("reason").commit()
        ReregisterFallbackReceiver.cancel(context)
        return true
    }

    fun isPending(context: Context): Boolean =
        prefs(context).getBoolean(KEY_PENDING, false)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
