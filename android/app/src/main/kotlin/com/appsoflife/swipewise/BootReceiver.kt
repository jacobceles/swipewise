package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager

/// Android wipes geofences on reboot, so we re-register from the same
/// background path used for boundary EXIT — spawn a Flutter engine, run the
/// reregister entrypoint, and bail.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val request = OneTimeWorkRequestBuilder<ReregisterWorker>()
            .setConstraints(ReregisterScheduler.networkConstraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            ReregisterScheduler.UNIQUE_WORK,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }
}
