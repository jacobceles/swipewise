package com.appsoflife.swipewise.qualification.observer;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import com.google.android.gms.common.GoogleApiAvailabilityLight;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.location.CurrentLocationRequest;
import com.google.android.gms.location.Geofence;
import com.google.android.gms.location.GeofencingRequest;
import com.google.android.gms.location.LocationServices;
import com.google.android.gms.location.Priority;
import com.google.android.gms.tasks.CancellationTokenSource;

public final class ProbeActivity extends Activity {
    static final double LAT = 39.237148;
    static final double LON = -123.176090;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final CancellationTokenSource cancellation = new CancellationTokenSource();
    private LocationManager locations;
    private LocationListener gps;
    private boolean gpsReceived;
    private boolean flpReceived;
    private boolean finished;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String run = getIntent().getStringExtra("run_id");
        Trace.begin(this, run);
        boolean fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        boolean background = checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED;
        Trace.emit(this, "prerequisites", Trace.object("fine_permission", fine,
            "background_permission", background, "gms_status",
            GoogleApiAvailabilityLight.getInstance().isGooglePlayServicesAvailable(this)));
        String mode = getIntent().getStringExtra("mode");
        if ("init".equals(mode)) {
            ArrivalListener.snapshot(this);
            finish();
        } else if ("observe".equals(mode) && fine) {
            observe();
        } else if ("gms-add".equals(mode) && fine && background) {
            register(run);
        } else if ("snapshot".equals(mode)) {
            ArrivalListener.snapshot(this);
            finish();
        } else {
            Trace.emit(this, "unsupported_or_denied", Trace.object());
            finish();
        }
    }

    @SuppressLint("MissingPermission")
    private void observe() {
        Trace.emit(this, "location_probe_start", Trace.object("flp_priority", "BALANCED_POWER_ACCURACY",
            "max_update_age_ms", 0, "budget_ms", 20_000));
        locations = getSystemService(LocationManager.class);
        gps = new LocationListener() {
            @Override public void onLocationChanged(Location fix) {
                if (finished) return;
                gpsReceived = true;
                Trace.emit(ProbeActivity.this, "gps_sample", Trace.fix(fix));
                locations.removeUpdates(this);
                maybeFinish();
            }
            @Override public void onProviderDisabled(String provider) {
                Trace.emit(ProbeActivity.this, "gps_disabled", Trace.object());
            }
        };
        locations.requestSingleUpdate(LocationManager.GPS_PROVIDER, gps, Looper.getMainLooper());
        CurrentLocationRequest request = new CurrentLocationRequest.Builder()
            .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
            .setMaxUpdateAgeMillis(0).setDurationMillis(20_000).build();
        LocationServices.getFusedLocationProviderClient(this).getCurrentLocation(request, cancellation.getToken())
            .addOnSuccessListener(fix -> {
                if (finished) return;
                flpReceived = fix != null;
                Trace.emit(this, "flp_sample", Trace.fix(fix));
                maybeFinish();
            }).addOnFailureListener(error -> {
                if (!finished) Trace.emit(this, "flp_failure", Trace.object("error_class", error.getClass().getSimpleName()));
            });
        handler.postDelayed(this::stopObservation, 20_000);
    }

    private void maybeFinish() {
        if (gpsReceived && flpReceived) stopObservation();
    }

    private void stopObservation() {
        if (finished) return;
        finished = true;
        handler.removeCallbacksAndMessages(null);
        if (locations != null && gps != null) locations.removeUpdates(gps);
        cancellation.cancel();
        Trace.emit(this, "location_observers_stopped", Trace.object("gps_received", gpsReceived,
            "flp_received", flpReceived));
        finish();
    }

    @SuppressLint("MissingPermission")
    private void register(String run) {
        Geofence fence = new Geofence.Builder().setRequestId(run).setCircularRegion(LAT, LON, 100)
            .setExpirationDuration(600_000).setNotificationResponsiveness(1_000)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER | Geofence.GEOFENCE_TRANSITION_EXIT).build();
        GeofencingRequest request = new GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER).addGeofence(fence).build();
        Intent intent = new Intent(this, GeofenceReceiver.class).putExtra("run_id", run);
        PendingIntent pending = PendingIntent.getBroadcast(this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
        Trace.emit(this, "gms_add_requested", Trace.object("request_id", run, "lat", LAT, "lon", LON, "radius_m", 100));
        LocationServices.getGeofencingClient(this).addGeofences(request, pending)
            .addOnSuccessListener(ignored -> {
                Trace.emit(this, "gms_add_success", Trace.object("request_id", run));
                finish();
            }).addOnFailureListener(error -> {
                Trace.emit(this, "gms_add_failure", Trace.object("error_class", error.getClass().getSimpleName(),
                    "status_code", error instanceof ApiException ? ((ApiException) error).getStatusCode() : null));
                finish();
            });
        handler.postDelayed(() -> {
            Trace.emit(this, "gms_add_wait_ended", Trace.object());
            finish();
        }, 30_000);
    }

    @Override public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (locations != null && !finished) stopObservation();
        super.onDestroy();
    }
}
