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
import java.util.concurrent.atomic.AtomicReference

internal interface ReregisterEngine {
    fun run(result: MethodChannel.Result)
    fun destroy()
}

open class ReregisterWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {

    @Volatile private var stopRun: (() -> Unit)? = null

    override fun doWork(): Result {
        if (isStopped) return Result.retry()
        // Idempotent; re-asserts the activity subscription on every background
        // re-register, so an app update or a missed boot can't leave it off.
        ActivitySubscriber.start(applicationContext)
        // Never fence the road: the 12-hour validation run (or a boot) mid-drive
        // registered fences around a highway (2026-10-17). Leave it owed; the
        // settle transition or the fallback alarm runs it on arrival.
        if (ActivityState.isLikelyDriving(applicationContext)) {
            WalkinLog.w(applicationContext, "worker: driving -> defer until settled")
            PendingReregister.set(applicationContext, true)
            ReregisterFallbackReceiver.arm(applicationContext)
            return if (isStopped) Result.retry() else Result.success()
        }
        val latch = completionLatch()
        val outcome = AtomicReference<Result?>(null)
        val main = Handler(Looper.getMainLooper())
        // Only the main thread reads or replaces the owned engine.
        var engine: ReregisterEngine? = null

        fun destroyEngine() {
            val owned = engine
            engine = null
            try { owned?.destroy() } catch (_: Throwable) { }
        }

        fun finish(success: Boolean) {
            val result = if (success && !isStopped) Result.success() else Result.retry()
            if (!outcome.compareAndSet(null, result)) return
            val cleanup = Runnable {
                try { destroyEngine() } finally { latch.countDown() }
            }
            if (Looper.myLooper() == Looper.getMainLooper()) cleanup.run()
            else main.post(cleanup)
        }

        stopRun = { finish(false) }

        // A FlutterEngine must be created and driven on the MAIN thread.
        // doWork() runs on a WorkManager background thread, so post the whole
        // engine lifecycle to the main looper and block here on a latch until
        // Dart calls back. Previously the engine was constructed directly on
        // this background thread, which threw before any Dart ran — that's why
        // the background re-registration never actually executed.
        if (isStopped) finish(false)
        else main.post {
            if (outcome.get() != null || isStopped) {
                finish(false)
                return@post
            }
            try {
                val createEngine = prepareEngine()
                // Loader initialization may have outlived cancellation.
                if (outcome.get() != null || isStopped) {
                    finish(false)
                    return@post
                }
                val created = createEngine()
                engine = created
                // Cancellation can win while construction is in flight,
                // including reentrant stop before createEngine returns.
                if (outcome.get() != null || isStopped) {
                    destroyEngine()
                    finish(false)
                    return@post
                }
                created.run(object : MethodChannel.Result {
                    // Failed registration stays retryable in WorkManager.
                    override fun success(result: Any?) { finish(result == true) }
                    override fun error(code: String, message: String?, details: Any?) { finish(false) }
                    override fun notImplemented() { finish(false) }
                })
            } catch (_: Throwable) {
                finish(false)
            }
        }
        try {
            awaitCompletion(latch)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            finish(false)
        }
        return if (isStopped) Result.retry() else outcome.get() ?: Result.retry()
    }

    override fun onStopped() { stopRun?.invoke() }

    internal open fun completionLatch(): CountDownLatch = CountDownLatch(1)

    internal open fun awaitCompletion(latch: CountDownLatch) {
        latch.await(2, TimeUnit.MINUTES)
    }

    internal open fun prepareEngine(): () -> ReregisterEngine {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
        }
        loader.ensureInitializationComplete(applicationContext, null)
        return {
            val engine = FlutterEngine(applicationContext)
            object : ReregisterEngine {
                override fun run(result: MethodChannel.Result) {
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
                    channel.invokeMethod("run", mapOf("uiAlive" to MainActivity.uiAlive), result)
                }

                override fun destroy() { engine.destroy() }
            }
        }
    }

    companion object {
        const val REREGISTER_ENTRYPOINT = "geofenceReregisterEntrypoint"
        const val REREGISTER_CHANNEL = "com.appsoflife/geofence-reregister"
    }
}
