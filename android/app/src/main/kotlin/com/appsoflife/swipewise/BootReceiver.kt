package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy

interface BootWorkScheduler {
    fun scheduleBootReregister(context: Context)
}

object DefaultBootWorkScheduler : BootWorkScheduler {
    override fun scheduleBootReregister(context: Context) {
        val request = OneTimeWorkRequestBuilder<ReregisterWorker>()
            .setConstraints(ReregisterScheduler.networkConstraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        ReregisterScheduler.enqueueUniqueWork(
            context,
            ReregisterScheduler.UNIQUE_WORK,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }
}

/// Android wipes geofences on reboot, so we re-register from the same
/// background path used for boundary EXIT — spawn a Flutter engine, run the
/// reregister entrypoint, and bail.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        WalkinLog.w(context, "boot: restarting activity recognition, enqueueing re-register")
        ArrivalDiagnostics.record(context, ArrivalDiagnostics.Event.BOOT)
        ActivityState.clear(context)
        ActivitySubscriber.start(context)
        DwellAlarms.clearAll(context)
        PendingReregister.request(context, 0L, "boot", force = true)
        workScheduler.scheduleBootReregister(context)
    }

    companion object {
        @Volatile
        var workScheduler: BootWorkScheduler = DefaultBootWorkScheduler
    }
}
