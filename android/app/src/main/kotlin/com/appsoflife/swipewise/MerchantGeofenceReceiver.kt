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
            WalkinLog.w(context, "fence: no event")
            return
        }
        if (event.hasError()) {
            WalkinLog.w(context, "fence: error code=${event.errorCode}")
            return
        }
        val transition = event.geofenceTransition
        val triggered = event.triggeringGeofences ?: return
        val store = GeofenceMetadataStore(context)
        WalkinLog.w(
            context,
            "fence ${if (transition == Geofence.GEOFENCE_TRANSITION_ENTER) "ENTER" else "EXIT"} " +
                triggered.joinToString(",") { g ->
                    g.requestId + if (store.read(g.requestId) == null) "(no_meta)" else ""
                } + " acc=${event.triggeringLocation?.accuracy?.toInt()}",
        )

        when (transition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> {
                for (g in triggered) {
                    val meta = store.read(g.requestId)
                    if (meta == null || DwellAlarms.isArmed(context, g.requestId)) {
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
