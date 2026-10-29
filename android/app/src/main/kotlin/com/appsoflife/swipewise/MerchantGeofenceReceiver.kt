package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
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
            if (event.errorCode == GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE) {
                PendingReregister.set(context, true)
                ReregisterScheduler.enqueue(context)
            }
            return
        }
        handleTransition(
            context = context,
            transition = event.geofenceTransition,
            triggeredGeofenceIds = event.triggeringGeofences?.map { it.requestId } ?: emptyList(),
            triggeringLocation = event.triggeringLocation,
        )
    }

    fun handleTransition(
        context: Context,
        transition: Int,
        triggeredGeofenceIds: List<String>,
        triggeringLocation: Location?,
    ) {
        WalkinState.migrate(context)
        val store = GeofenceMetadataStore(context)
        WalkinLog.w(
            context,
            "fence ${if (transition == Geofence.GEOFENCE_TRANSITION_ENTER) "ENTER" else "EXIT"} " +
                triggeredGeofenceIds.joinToString(",") { id ->
                    id + if (store.read(id) == null) "(no_meta)" else ""
                } + " acc=${triggeringLocation?.accuracy?.toInt()}",
        )

        when (transition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> {
                VisitLock.clearLeft(context, triggeredGeofenceIds)
                for (gid in triggeredGeofenceIds) {
                    val meta = store.read(gid)
                    if (meta == null || DwellAlarms.isArmed(context, gid)) {
                        continue
                    }
                    DwellAlarms.arm(
                        context,
                        gid,
                        meta.dwellSeconds,
                        triggeringLocation = triggeringLocation,
                    )
                }
            }
            Geofence.GEOFENCE_TRANSITION_EXIT -> {
                VisitLock.observeDeparture(context, triggeringLocation)
                for (gid in triggeredGeofenceIds) {
                    DwellAlarms.cancel(context, gid)
                }
                VisitLock.markLeft(context, triggeredGeofenceIds)
            }
        }
    }

    companion object {
        const val ACTION = "com.appsoflife.swipewise.GEOFENCE"
    }
}
