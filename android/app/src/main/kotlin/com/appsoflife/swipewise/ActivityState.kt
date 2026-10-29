package com.appsoflife.swipewise

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity

object BootIdentity {
    const val UNKNOWN_BOOT_COUNT = -1

    @Volatile
    var testBootCount: Int? = null

    fun getBootCount(context: Context): Int {
        testBootCount?.let { return it }
        return try {
            val count = android.provider.Settings.Global.getInt(
                context.contentResolver,
                android.provider.Settings.Global.BOOT_COUNT,
                UNKNOWN_BOOT_COUNT,
            )
            if (count < 0) UNKNOWN_BOOT_COUNT else count
        } catch (_: Exception) {
            UNKNOWN_BOOT_COUNT
        }
    }
}

/// In-memory and persisted cache of the user's latest activity.
/// Updated by `ActivityTransitionReceiver` whenever the OS reports a transition.
/// Defaults to UNKNOWN if we've never received a transition. Missing or
/// stale activity state is treated as unknown, not stationary.
object ActivityState {
    private const val PREFS = "swipewise_activity_state"
    private const val KEY_BOOT_COUNT = "boot_count"
    private const val KEY_TYPE = "type"
    private const val KEY_TRANSITION = "transition"
    private const val KEY_EVENT_ELAPSED_NANOS = "event_elapsed_nanos"
    private const val KEY_AT = "at"

    fun set(
        context: Context,
        activityType: Int,
        transitionType: Int,
        eventElapsedRealtimeNanos: Long,
        atWallMillis: Long,
    ) {
        val bootCount = BootIdentity.getBootCount(context)
        if (bootCount == BootIdentity.UNKNOWN_BOOT_COUNT) {
            WalkinLog.w(context, "activity set: unknown boot count -> failing closed")
            return
        }
        context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY_BOOT_COUNT, bootCount)
            .putInt(KEY_TYPE, activityType)
            .putInt(KEY_TRANSITION, transitionType)
            .putLong(KEY_EVENT_ELAPSED_NANOS, eventElapsedRealtimeNanos)
            .putLong(KEY_AT, atWallMillis)
            .apply()
    }

    fun lastEventElapsedRealtimeNanos(context: Context): Long {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val bootCount = prefs.getInt(KEY_BOOT_COUNT, BootIdentity.UNKNOWN_BOOT_COUNT)
        val currentBoot = BootIdentity.getBootCount(context)
        if (currentBoot == BootIdentity.UNKNOWN_BOOT_COUNT || bootCount != currentBoot) return 0L
        return prefs.getLong(KEY_EVENT_ELAPSED_NANOS, 0L)
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    fun getObservation(
        context: Context,
        nowElapsedNanos: Long = android.os.SystemClock.elapsedRealtimeNanos(),
    ): ActivityObservation? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.contains(KEY_TYPE)) return null
        val bootCount = prefs.getInt(KEY_BOOT_COUNT, BootIdentity.UNKNOWN_BOOT_COUNT)
        val currentBoot = BootIdentity.getBootCount(context)
        if (currentBoot == BootIdentity.UNKNOWN_BOOT_COUNT || bootCount != currentBoot) return null
        val eventNanos = prefs.getLong(KEY_EVENT_ELAPSED_NANOS, 0L)
        if (eventNanos > nowElapsedNanos || eventNanos <= 0L) return null
        val type = prefs.getInt(KEY_TYPE, DetectedActivity.UNKNOWN)
        val transition = prefs.getInt(KEY_TRANSITION, ActivityTransition.ACTIVITY_TRANSITION_ENTER)
        return ActivityObservation(type, transition, eventNanos)
    }

    /// True iff the latest reported activity is IN_VEHICLE ENTER within 2h.
    fun isLikelyDriving(
        context: Context,
        nowElapsedNanos: Long = android.os.SystemClock.elapsedRealtimeNanos(),
    ): Boolean {
        val obs = getObservation(context, nowElapsedNanos) ?: return false
        if (obs.type != DetectedActivity.IN_VEHICLE || obs.transitionType != ActivityTransition.ACTIVITY_TRANSITION_ENTER) return false
        val ageNanos = nowElapsedNanos - obs.elapsedRealtimeNanos
        return ageNanos < 2L * 3600L * 1_000_000_000L
    }

    /// True iff the latest reported activity is WALKING ENTER within 30 min.
    fun isLikelyWalking(
        context: Context,
        nowElapsedNanos: Long = android.os.SystemClock.elapsedRealtimeNanos(),
    ): Boolean {
        val obs = getObservation(context, nowElapsedNanos) ?: return false
        if (obs.type != DetectedActivity.WALKING || obs.transitionType != ActivityTransition.ACTIVITY_TRANSITION_ENTER) return false
        val ageNanos = nowElapsedNanos - obs.elapsedRealtimeNanos
        return ageNanos < 30L * 60L * 1_000_000_000L
    }

    fun isStationary(
        context: Context,
        nowElapsedNanos: Long = android.os.SystemClock.elapsedRealtimeNanos(),
    ): Boolean {
        val obs = getObservation(context, nowElapsedNanos) ?: return false
        if (obs.type != DetectedActivity.STILL || obs.transitionType != ActivityTransition.ACTIVITY_TRANSITION_ENTER) return false
        val ageNanos = nowElapsedNanos - obs.elapsedRealtimeNanos
        return ageNanos < 15L * 60L * 1_000_000_000L
    }

    fun diagnostic(
        context: Context,
        nowElapsedNanos: Long = android.os.SystemClock.elapsedRealtimeNanos(),
    ): String {
        val obs = getObservation(context, nowElapsedNanos) ?: return "activity=UNKNOWN activity_age_ms=null"
        val ageMs = (nowElapsedNanos - obs.elapsedRealtimeNanos) / 1_000_000L
        return "activity=${obs.type} transition=${obs.transitionType} activity_age_ms=$ageMs"
    }
}

/// Subscribes to ActivityRecognition transitions for IN_VEHICLE / STILL /
/// WALKING. The transitions wake `ActivityTransitionReceiver`, which
/// updates [ActivityState]. Cheap — the OS coalesces and we only act on
/// transitions, not continuous polling.
object ActivitySubscriber {
    private const val UNIQUE_REQ = 2001
    @Volatile var requestUpdates: (Context, ActivityTransitionRequest, PendingIntent) -> com.google.android.gms.tasks.Task<Void> =
        { context, request, pi -> ActivityRecognition.getClient(context).requestActivityTransitionUpdates(request, pi) }

    fun start(context: Context, retries: Int = 1) {
        val perm = "android.permission.ACTIVITY_RECOGNITION"
        if (ContextCompat.checkSelfPermission(context, perm) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            WalkinLog.w(context, "activity subscription: permission denied")
            return
        }
        val transitions = listOf(
            transition(DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
            transition(DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_EXIT),
            transition(DetectedActivity.STILL, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
            transition(DetectedActivity.WALKING, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
        )
        val request = ActivityTransitionRequest(transitions)
        val pi = pendingIntent(context)
        try {
            requestUpdates(context, request, pi)
                .addOnSuccessListener { WalkinLog.w(context, "activity subscription: active") }
                .addOnFailureListener {
                    val status = (it as? com.google.android.gms.common.api.ApiException)?.statusCode
                    WalkinLog.w(context, "activity subscription: failed ${it.javaClass.simpleName} status=$status")
                    if (retries > 0) {
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            start(context, retries - 1)
                        }, 5_000L)
                    }
                }
        } catch (_: SecurityException) {
            WalkinLog.w(context, "activity subscription: permission revoked")
        }
    }

    private fun transition(activityType: Int, transitionType: Int) =
        ActivityTransition.Builder()
            .setActivityType(activityType)
            .setActivityTransition(transitionType)
            .build()

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, ActivityTransitionReceiver::class.java).apply {
            action = ActivityTransitionReceiver.ACTION
        }
        return PendingIntent.getBroadcast(
            context,
            UNIQUE_REQ,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }
}
