package com.appsoflife.swipewise

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ReregisterWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {

    override fun doWork(): Result {
        val loader = FlutterInjector.instance().flutterLoader()
        val latch = CountDownLatch(1)
        var ok = false

        // A FlutterEngine must be created and driven on the MAIN thread.
        // doWork() runs on a WorkManager background thread, so post the whole
        // engine lifecycle to the main looper and block here on a latch until
        // Dart calls back. Previously the engine was constructed directly on
        // this background thread, which threw before any Dart ran — that's why
        // the background re-registration never actually executed.
        Handler(Looper.getMainLooper()).post {
            try {
                if (!loader.initialized()) {
                    loader.startInitialization(applicationContext)
                }
                loader.ensureInitializationComplete(applicationContext, null)
                val engine = FlutterEngine(applicationContext)
                try {
                    GeneratedPluginRegistrant.registerWith(engine)
                } catch (_: Throwable) {
                    // Some plugins may fail to register in a background isolate;
                    // the ones we need (sqflite, http, geolocator) are robust.
                }
                // GeofencePlugin is a manual plugin — GeneratedPluginRegistrant
                // doesn't know it, and MainActivity only adds it to the UI
                // engine. Without it here the Dart side's registerSet call has
                // no native handler (MissingPluginException), so add it.
                engine.plugins.add(GeofencePlugin())
                val entrypoint = DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    REREGISTER_ENTRYPOINT,
                )
                engine.dartExecutor.executeDartEntrypoint(entrypoint)
                val channel = MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    REREGISTER_CHANNEL,
                )
                channel.invokeMethod(
                    "run",
                    null,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            // Dart returns false when registration failed (no
                            // fix / Places errored) — map to Result.retry so
                            // WorkManager backs off instead of marking it done.
                            ok = result == true
                            engine.destroy()
                            latch.countDown()
                        }
                        override fun error(code: String, message: String?, details: Any?) {
                            engine.destroy()
                            latch.countDown()
                        }
                        override fun notImplemented() {
                            engine.destroy()
                            latch.countDown()
                        }
                    },
                )
            } catch (_: Throwable) {
                latch.countDown()
            }
        }
        latch.await(2, TimeUnit.MINUTES)
        return if (ok) Result.success() else Result.retry()
    }

    companion object {
        const val REREGISTER_ENTRYPOINT = "geofenceReregisterEntrypoint"
        const val REREGISTER_CHANNEL = "com.appsoflife/geofence-reregister"
    }
}
