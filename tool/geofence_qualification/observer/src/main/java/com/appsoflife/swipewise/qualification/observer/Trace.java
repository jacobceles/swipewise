package com.appsoflife.swipewise.qualification.observer;

import android.content.Context;
import android.content.SharedPreferences;
import android.location.Location;
import android.os.SystemClock;
import android.util.Log;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONException;
import org.json.JSONObject;

final class Trace {
    private Trace() {}

    static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences("qualification-observer", Context.MODE_PRIVATE);
    }

    static synchronized void begin(Context context, String run) {
        if (run == null || !run.matches("q-[a-f0-9]{32}")) {
            throw new IllegalArgumentException("Invalid run nonce");
        }
        String previous = prefs(context).getString("run_id", null);
        if (previous != null && !previous.equals(run)) {
            throw new IllegalStateException("Observer belongs to another run");
        }
        if (previous == null && !prefs(context).edit().putString("run_id", run).commit()) {
            throw new IllegalStateException("Cannot persist run nonce");
        }
    }

    static JSONObject object(Object... pairs) {
        JSONObject value = new JSONObject();
        try {
            for (int i = 0; i < pairs.length; i += 2) {
                value.put((String) pairs[i], pairs[i + 1] == null ? JSONObject.NULL : pairs[i + 1]);
            }
        } catch (JSONException error) {
            throw new IllegalArgumentException("Invalid typed observation", error);
        }
        return value;
    }

    static JSONObject fix(Location fix) {
        if (fix == null) return object("available", false);
        long now = SystemClock.elapsedRealtimeNanos();
        return object("available", true, "lat", fix.getLatitude(), "lon", fix.getLongitude(),
            "provider", fix.getProvider(), "elapsed_realtime_ns", fix.getElapsedRealtimeNanos(),
            "observed_elapsed_ns", now, "age_ms", (now - fix.getElapsedRealtimeNanos()) / 1_000_000.0,
            "accuracy_m", fix.hasAccuracy() ? fix.getAccuracy() : null,
            "speed_mps", fix.hasSpeed() ? fix.getSpeed() : null,
            "is_mock", fix.isFromMockProvider(), "sample_unix_ms", fix.getTime());
    }

    static synchronized void emit(Context context, String stage, JSONObject data) {
        SharedPreferences prefs = prefs(context);
        String run = prefs.getString("run_id", null);
        if (run == null) return; // Listener can bind before the initial activity.
        long sequence = prefs.getLong("next_seq", 0);
        try {
            if (!prefs.edit().putLong("next_seq", sequence + 1).commit()) {
                throw new IllegalStateException("Cannot persist observer sequence");
            }
            JSONObject event = object("schema_version", 1, "run_id", run, "seq", sequence,
                "stage", stage, "elapsed_ns", SystemClock.elapsedRealtimeNanos(),
                "unix_ms", System.currentTimeMillis(), "data", data);
            try (FileOutputStream stream = context.openFileOutput("observations.jsonl", Context.MODE_APPEND)) {
                stream.write((event.toString() + "\n").getBytes(StandardCharsets.UTF_8));
            }
        } catch (Exception error) {
            // A gap or this explicit error is a failed collection, never an empty success.
            Log.e("QualificationObserver", "RECORDING_FAILED " + error.getClass().getSimpleName());
        }
    }
}
