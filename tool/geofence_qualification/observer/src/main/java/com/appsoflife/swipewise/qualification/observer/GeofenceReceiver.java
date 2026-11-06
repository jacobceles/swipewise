package com.appsoflife.swipewise.qualification.observer;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import com.google.android.gms.location.Geofence;
import com.google.android.gms.location.GeofencingEvent;
import org.json.JSONArray;

public final class GeofenceReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        String run = Trace.prefs(context).getString("run_id", null);
        if (run == null || !run.equals(intent.getStringExtra("run_id"))) return;
        GeofencingEvent event = GeofencingEvent.fromIntent(intent);
        if (event == null) {
            Trace.emit(context, "gms_event_unavailable", Trace.object());
            return;
        }
        JSONArray ids = new JSONArray();
        if (event.getTriggeringGeofences() != null) {
            for (Geofence fence : event.getTriggeringGeofences()) ids.put(fence.getRequestId());
        }
        Trace.emit(context, "gms_transition", Trace.object("has_error", event.hasError(),
            "error_code", event.getErrorCode(), "transition", event.getGeofenceTransition(),
            "request_ids", ids, "triggering_location", Trace.fix(event.getTriggeringLocation())));
    }
}
