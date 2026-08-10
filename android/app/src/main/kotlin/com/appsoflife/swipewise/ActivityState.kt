package com.appsoflife.swipewise

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity

/// In-memory cache of the user's latest activity. Updated by
/// `ActivityTransitionReceiver` whenever the OS reports a transition.
/// Defaults to STILL if we've never received a transition (don't punish
/// users for a fresh install).
object ActivityState {
    private const val PREFS = "swipewise_activity_state"
    private const val KEY_TYPE = "type"
    private const val KEY_AT = "at"

    fun set(context: Context, activityType: Int, atMillis: Long) {
        context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY_TYPE, activityType)
            .putLong(KEY_AT, atMillis)
            .apply()
    }

    /// True iff the latest reported activity is IN_VEHICLE and recent
    /// (older readings are ignored — drivers may have parked).
    fun isLikelyDriving(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val type = prefs.getInt(KEY_TYPE, DetectedActivity.STILL)
        val at = prefs.getLong(KEY_AT, 0L)
        if (type != DetectedActivity.IN_VEHICLE) return false
        // Ignore if we haven't seen an update in 30+ min — could be stale.
        return System.currentTimeMillis() - at < 30L * 60L * 1000L
    }
}

/// Subscribes to ActivityRecognition transitions for IN_VEHICLE / STILL /
/// WALKING. The transitions wake `ActivityTransitionReceiver`, which
/// updates [ActivityState]. Cheap — the OS coalesces and we only act on
/// transitions, not continuous polling.
object ActivitySubscriber {
    private const val UNIQUE_REQ = 2001

    fun start(context: Context) {
        val perm = "android.permission.ACTIVITY_RECOGNITION"
        if (ContextCompat.checkSelfPermission(context, perm) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
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
            ActivityRecognition.getClient(context)
                .requestActivityTransitionUpdates(request, pi)
        } catch (_: SecurityException) {
            // permission was revoked between the check and the call; skip
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
