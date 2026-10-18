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

    /// Every reregister path needs the Places API to find nearby merchants, so
    /// gate the work on connectivity: WorkManager defers it until a network is
    /// available instead of firing offline only to fail and burn a retry. Shared
    /// with [BootReceiver] and [MainActivity]'s periodic validation.
    val networkConstraints: Constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun enqueue(context: Context) {
        val request = OneTimeWorkRequestBuilder<ReregisterWorker>()
            .setConstraints(networkConstraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        // APPEND_OR_REPLACE, not REPLACE: replacing a running worker only
        // interrupts its latch, while its Flutter engine carries on — two
        // registerSet calls then interleave and the fence set and its metadata
        // can come from different runs (`no_meta`). Appending runs this one
        // after the current one finishes.
        WorkManager.getInstance(context).enqueueUniqueWork(
            UNIQUE_WORK,
            ExistingWorkPolicy.APPEND_OR_REPLACE,
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
        nowMillis - prefs(context).getLong(KEY_AT, 0L) < COOLDOWN_MS

    fun mark(context: Context, nowMillis: Long) {
        prefs(context).edit().putLong(KEY_AT, nowMillis).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/// One-bit persisted flag: "the user crossed the boundary while driving, so a
/// re-registration is owed once they settle." Set by the boundary receiver
/// when it defers, consumed by the activity receiver on the next STILL/WALKING
/// transition. This is what makes geofences follow the user to a destination
/// without re-registering repeatedly during the drive itself.
object PendingReregister {
    private const val PREFS = "swipewise_reregister"
    private const val KEY_PENDING = "pending"

    fun set(context: Context, pending: Boolean) {
        prefs(context).edit().putBoolean(KEY_PENDING, pending).apply()
    }

    fun isPending(context: Context): Boolean =
        prefs(context).getBoolean(KEY_PENDING, false)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
