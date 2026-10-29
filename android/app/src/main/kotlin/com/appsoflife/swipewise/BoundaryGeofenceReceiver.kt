package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingEvent

class BoundaryGeofenceReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            WalkinLog.w(context, "boundary: error code=${event.errorCode}")
            if (event.errorCode == GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE) {
                PendingReregister.request(context, 0L, "os_recovery", force = true)
                ReregisterScheduler.enqueue(context)
            }
            return
        }
        if (event.geofenceTransition != Geofence.GEOFENCE_TRANSITION_EXIT) return
        VisitLock.observeDeparture(context, event.triggeringLocation)

        // Don't re-register mid-drive — you'd cross each new boundary again and
        // again on a long trip. Instead defer: remember a re-registration is
        // owed, and let [ActivityTransitionReceiver] run it the moment the user
        // goes STILL/WALKING (i.e. parks / arrives). No churn during the drive,
        // geofences land at the destination.
        val driving = ActivityState.isLikelyDriving(context)
        WalkinLog.w(context, "boundary EXIT driving=$driving${if (driving) " -> defer" else ""}")
        if (driving) {
            PendingReregister.request(context, FootReregister.COOLDOWN_MS, "driving")
            // Safety net: if activity recognition never delivers the settle
            // event, this alarm consumes the pending flag on its own.
            ReregisterFallbackReceiver.arm(context)
            return
        }

        // On foot: at most one search per FootReregister.COOLDOWN_MS. A later
        // crossing leaves it owed; the fallback alarm runs it.
        val now = android.os.SystemClock.elapsedRealtime()
        if (FootReregister.tooSoon(context, now)) {
            WalkinLog.w(context, "boundary EXIT on foot within 5 min of last search -> defer")
            PendingReregister.request(context, FootReregister.remaining(context, now), "boundary")
            return
        }
        FootReregister.mark(context, now)
        PendingReregister.request(context, FootReregister.COOLDOWN_MS, "boundary")
        ReregisterScheduler.enqueue(context)
    }

    companion object {
        const val ACTION = "com.appsoflife.swipewise.BOUNDARY"
    }
}
