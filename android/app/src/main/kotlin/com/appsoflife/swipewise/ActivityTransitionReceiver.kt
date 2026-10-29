package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionEvent
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

class ActivityTransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        handleTransitions(context, result.transitionEvents)
    }

    fun handleTransitions(
        context: Context,
        rawEvents: List<ActivityTransitionEvent>,
        nowElapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ) {
        if (rawEvents.isEmpty()) return

        // Filter future-invalid events BEFORE updating lastEvent
        val validTimeEvents = rawEvents.filter { it.elapsedRealTimeNanos in 1..(nowElapsedNanos + 1_000_000_000L) }
        if (validTimeEvents.isEmpty()) return

        val ordered = validTimeEvents.sortedBy { it.elapsedRealTimeNanos }
        val lastNanos = ActivityState.lastEventElapsedRealtimeNanos(context)
        val freshEvents = ordered.filter { it.elapsedRealTimeNanos > lastNanos }
        if (freshEvents.isEmpty()) return

        val initialObs = ActivityState.getObservation(context, nowElapsedNanos)
        var currentActivity = initialObs?.type ?: DetectedActivity.UNKNOWN
        var currentTransition = initialObs?.transitionType ?: ActivityTransition.ACTIVITY_TRANSITION_EXIT

        var sawWalkingToStill = false
        var pendingReregisterNeeded = false

        for (event in freshEvents) {
            val prevActivity = currentActivity

            val leftVehicle = event.activityType == DetectedActivity.IN_VEHICLE &&
                event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_EXIT
            currentActivity = if (leftVehicle) DetectedActivity.UNKNOWN else event.activityType
            currentTransition = event.transitionType

            // Latch walking-to-still; unlatch if user begins walking or driving again
            if (prevActivity == DetectedActivity.WALKING &&
                currentActivity == DetectedActivity.STILL &&
                currentTransition == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            ) {
                sawWalkingToStill = true
            } else if (currentActivity == DetectedActivity.IN_VEHICLE || currentActivity == DetectedActivity.WALKING) {
                sawWalkingToStill = false
            }

            val settled = currentTransition == ActivityTransition.ACTIVITY_TRANSITION_ENTER &&
                (currentActivity == DetectedActivity.STILL || currentActivity == DetectedActivity.WALKING)
            if (settled && PendingReregister.isPending(context)) {
                pendingReregisterNeeded = true
            }

            ActivityState.set(
                context,
                currentActivity,
                event.transitionType,
                event.elapsedRealTimeNanos,
                System.currentTimeMillis(),
            )

            WalkinLog.w(
                context,
                "activity type=${event.activityType} transition=${event.transitionType} " +
                    "nanos=${event.elapsedRealTimeNanos} pending_reregister=${PendingReregister.isPending(context)}",
            )
        }

        if (pendingReregisterNeeded) {
            PendingReregister.set(context, false)
            ReregisterScheduler.enqueue(context)
        }
        if (sawWalkingToStill && currentActivity == DetectedActivity.STILL) {
            armNextDoorCheck(context)
        }
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
