package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent

/// Handles merchant-fence ENTER/EXIT. The dwell decision itself is app-side:
/// ENTER arms a one-shot [DwellAlarms] timer for the fence's dwell seconds,
/// EXIT cancels it, and when the timer survives to firing, [DwellCheckReceiver]
/// verifies the user is still at the fence and posts. This replaced the OS
/// GEOFENCE_TRANSITION_DWELL, whose lazy loitering evaluation could run
/// minutes late.
class MerchantGeofenceReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent)
        if (event == null) {
            return
        }
        if (event.hasError()) {
            return
        }
        val transition = event.geofenceTransition
        val triggered = event.triggeringGeofences ?: return
        val store = GeofenceMetadataStore(context)

        when (transition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> {
                for (g in triggered) {
                    val meta = store.read(g.requestId)
                    if (meta == null) {
                        continue
                    }
                    DwellAlarms.arm(context, g.requestId, meta.dwellSeconds)
                }
            }
            Geofence.GEOFENCE_TRANSITION_EXIT -> {
                for (g in triggered) {
                    DwellAlarms.cancel(context, g.requestId)
                }
            }
        }
    }

    companion object {
        const val ACTION = "com.appsoflife.swipewise.GEOFENCE"
    }
}
