package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent

class BoundaryGeofenceReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            return
        }
        if (event.geofenceTransition != Geofence.GEOFENCE_TRANSITION_EXIT) return

        // Smart cooldown re-arm: crossing the boundary means the user left
        // the mapped area, so a later return to any of these merchants is a
        // new trip — clear per-merchant cooldowns so it re-notifies. If the
        // user never leaves the area, the normal 6h window applies.
        CooldownStore(context).clearMerchantCooldowns()

        // Don't re-register mid-drive — you'd cross each new boundary again and
        // again on a long trip. Instead defer: remember a re-registration is
        // owed, and let [ActivityTransitionReceiver] run it the moment the user
        // goes STILL/WALKING (i.e. parks / arrives). No churn during the drive,
        // geofences land at the destination.
        val driving = ActivityState.isLikelyDriving(context)
        WalkinLog.w(context, "boundary EXIT driving=$driving${if (driving) " -> defer" else ""}")
        if (driving) {
            PendingReregister.set(context, true)
            // Safety net: if activity recognition never delivers the settle
            // event, this alarm consumes the pending flag on its own.
            ReregisterFallbackReceiver.arm(context)
            return
        }

        // On foot: at most one search per FootReregister.COOLDOWN_MS. A later
        // crossing leaves it owed; the fallback alarm runs it.
        val now = System.currentTimeMillis()
        if (FootReregister.tooSoon(context, now)) {
            WalkinLog.w(context, "boundary EXIT on foot within 5 min of last search -> defer")
            PendingReregister.set(context, true)
            ReregisterFallbackReceiver.arm(context)
            return
        }
        FootReregister.mark(context, now)
        PendingReregister.set(context, false)
        ReregisterScheduler.enqueue(context)
    }

    companion object {
        const val ACTION = "com.appsoflife.swipewise.BOUNDARY"
    }
}
