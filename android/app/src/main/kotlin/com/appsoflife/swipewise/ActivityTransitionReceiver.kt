package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

class ActivityTransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        // Latest event wins.
        val latest = result.transitionEvents.lastOrNull() ?: return
        val wasWalking = ActivityState.isLikelyWalking(context)
        // An IN_VEHICLE *EXIT* means the drive ended; storing its bare
        // activity type read as "still driving".
        val leftVehicle = latest.activityType == DetectedActivity.IN_VEHICLE &&
            latest.transitionType == ActivityTransition.ACTIVITY_TRANSITION_EXIT
        ActivityState.set(
            context,
            if (leftVehicle) DetectedActivity.UNKNOWN else latest.activityType,
            System.currentTimeMillis(),
        )
        WalkinLog.w(
            context,
            "activity type=${latest.activityType} transition=${latest.transitionType} " +
                "pending_reregister=${PendingReregister.isPending(context)}",
        )

        // The user just settled (parked / on foot). If a boundary crossing was
        // deferred while driving, this is when we run it — geofences catch up to
        // the destination without any mid-drive churn.
        val settled = latest.transitionType ==
            ActivityTransition.ACTIVITY_TRANSITION_ENTER &&
            (latest.activityType == DetectedActivity.STILL ||
                latest.activityType == DetectedActivity.WALKING)
        if (settled && PendingReregister.isPending(context)) {
            PendingReregister.set(context, false)
            ReregisterScheduler.enqueue(context)
        }

        // Stopped after walking, during a visit: maybe the shop next door,
        // whose fence was entered (and its alert held back) on arrival, so no
        // new ENTER will come. One dwell check from the visit's fence; it
        // posts only if the fix names a store this visit hasn't alerted for.
        val stopped = latest.activityType == DetectedActivity.STILL &&
            latest.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
        if (stopped && wasWalking) armNextDoorCheck(context)
    }

    private fun armNextDoorCheck(context: Context) {
        val visit = VisitLock.read(context)
        if (!VisitLock.isActive(visit, System.currentTimeMillis())) return
        val fenceId = visit!!.fenceId ?: return
        val meta = GeofenceMetadataStore(context).read(fenceId) ?: return
        if (DwellAlarms.isArmed(context, fenceId)) return
        DwellAlarms.arm(context, fenceId, meta.dwellSeconds, nextDoor = true)
        WalkinLog.w(context, "visit: still after walking -> next-door check $fenceId in ${meta.dwellSeconds}s")
    }

    companion object {
        const val ACTION = "com.appsoflife.swipewise.ACTIVITY"
    }
}
