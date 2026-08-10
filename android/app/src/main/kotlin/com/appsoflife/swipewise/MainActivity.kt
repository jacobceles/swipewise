package com.appsoflife.swipewise

import android.content.Intent
import android.os.Bundle
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureMerchantFromIntent(intent)
        scheduleGeofenceValidation()
        ActivitySubscriber.start(applicationContext)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureMerchantFromIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(GeofencePlugin())
        flutterEngine.plugins.add(LinkProgressPlugin())
    }

    private fun captureMerchantFromIntent(intent: Intent?) {
        val json = intent?.getStringExtra(NotificationHelper.EXTRA_OPTIONS_JSON)
        PendingMerchantStore.set(json)
    }

    /// Periodic safety net: re-runs the registration flow every 12h so a
    /// silent OS drop (memory pressure, throttling) doesn't leave the user
    /// without geofences. Idempotent — the flow uses the tile cache when
    /// fresh, so the Places API quota isn't burned.
    private fun scheduleGeofenceValidation() {
        val req = PeriodicWorkRequestBuilder<ReregisterWorker>(
            12, TimeUnit.HOURS,
        ).setConstraints(ReregisterScheduler.networkConstraints).build()
        WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
            VALIDATION_WORK,
            ExistingPeriodicWorkPolicy.KEEP,
            req,
        )
    }

    companion object {
        private const val VALIDATION_WORK = "swipewise.geofence.validate"
    }
}
