package com.appsoflife.swipewise

import android.app.Activity
import android.app.AlarmManager
import android.app.Instrumentation
import android.content.Context
import android.location.Location
import android.os.Bundle
import android.os.SystemClock
import com.google.android.gms.tasks.CancellationToken
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/** Observes/delegates real app paths; never manufactures ENTER, a fix or a verdict. */
class GeofenceSmokeInstrumentation : Instrumentation() {
    private lateinit var run: String
    private lateinit var trace: File
    private lateinit var engine: FlutterEngine
    private lateinit var fixture: MethodChannel
    private var sequence = 0
    @Volatile private var ready = false
    @Volatile private var stopped = false
    private var diagnostics = ""
    private var walkin = ""
    private var attempts = ""

    override fun onCreate(arguments: Bundle) {
        run = arguments.getString("run_id") ?: error("run nonce required")
        require(run.matches(Regex("q-[a-f0-9]{32}")))
        super.onCreate(arguments)
        start()
    }

    @Synchronized private fun emit(stage: String, data: Any? = null) {
        trace.appendText(JSONObject().put("schema_version", 1).put("run_id", run)
            .put("seq", sequence++).put("elapsed_ns", SystemClock.elapsedRealtimeNanos())
            .put("unix_ms", System.currentTimeMillis()).put("stage", stage)
            .put("data", data ?: JSONObject()).toString() + "\n")
    }

    private fun fix(location: Location?): JSONObject {
        if (location == null) return JSONObject().put("available", false)
        return JSONObject().put("available", true).put("lat", location.latitude).put("lon", location.longitude)
            .put("provider", location.provider).put("elapsed_realtime_ns", location.elapsedRealtimeNanos)
            .put("observed_elapsed_ns", SystemClock.elapsedRealtimeNanos())
            .put("accuracy_m", if (location.hasAccuracy()) location.accuracy else JSONObject.NULL)
            .put("speed_mps", if (location.hasSpeed()) location.speed else JSONObject.NULL)
            .put("is_mock", location.isMock)
    }

    private fun attempt(): JSONObject {
        val prefs = targetContext.getSharedPreferences("swipewise_dwell_attempts", Context.MODE_PRIVATE)
        return JSONObject(prefs.all.mapValues { JSONObject(it.value as String) })
    }

    @Synchronized private fun observe() {
        val current = attempt().toString()
        if (attempts != current) { attempts = current; emit("attempts", JSONObject(current)) }
        val diag = ArrivalDiagnostics.read(targetContext)
        if (diagnostics != diag) { diagnostics = diag; emit("diagnostics", JSONObject().put("text", diag)) }
        val file = File(targetContext.filesDir, "walkin.log")
        val log = if (file.exists()) file.readText() else ""
        if (walkin != log) { walkin = log; emit("walkin", JSONObject().put("text", log)) }
    }

    override fun onStart() {
        trace = File(targetContext.filesDir, "qualification.jsonl")
        require(!trace.exists()) { "fresh fixture process required" }
        emit("instrumentation_started", JSONObject()
            .put("exact_alarm_capable", targetContext.getSystemService(AlarmManager::class.java).canScheduleExactAlarms())
            .put("firebase_initialized", (Class.forName("com.google.firebase.FirebaseApp")
                .getMethod("getApps", Context::class.java).invoke(null, targetContext) as List<*>).isNotEmpty()))
        runOnMainSync {
            DwellCheckReceiver.locationProvider = object : LocationProvider {
                override fun getCurrentLocation(context: Context, priority: Int, durationMillis: Long,
                    maxUpdateAgeMillis: Long, cancellationToken: CancellationToken,
                    onSuccess: (Location?) -> Unit, onFailure: (Exception) -> Unit) {
                    emit("verification_request", JSONObject().put("priority", priority).put("duration_ms", durationMillis)
                        .put("max_age_ms", maxUpdateAgeMillis).put("attempts", attempt()).put("delegate", "DefaultLocationProvider"))
                    DefaultLocationProvider.getCurrentLocation(context, priority, durationMillis, maxUpdateAgeMillis,
                        cancellationToken, { location ->
                            emit("verification_sample", JSONObject().put("sample", fix(location)).put("attempts", attempt()))
                            onSuccess(location)
                            observe()
                        }, { error ->
                            emit("verification_failure", JSONObject().put("class", error.javaClass.simpleName))
                            onFailure(error)
                            observe()
                        })
                }
            }
            DwellCheckReceiver.notificationPoster = object : NotificationPoster {
                override fun postDwell(context: Context, meta: MerchantMeta, verifiedAtMillis: Long): Boolean {
                    emit("poster_call", JSONObject().put("fence", meta.geofenceId).put("approximate", meta.approximate)
                        .put("card", meta.primary.bestCardName).put("attempts", attempt()))
                    val submitted = DefaultNotificationPoster.postDwell(context, meta, verifiedAtMillis)
                    emit("poster_result", JSONObject().put("submitted", submitted))
                    return submitted
                }
            }
            engine = FlutterEngine(targetContext)
            val plugin = GeofencePlugin()
            engine.plugins.add(plugin)
            MethodChannel(engine.dartExecutor.binaryMessenger, GeofencePlugin.CHANNEL).setMethodCallHandler { call, reply ->
                if (call.method == "registerSet") emit("ranking_payload", JSONObject(call.arguments as Map<*, *>))
                plugin.onMethodCall(call, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (call.method == "registerSet") {
                            emit("register_result", JSONObject().put("count", result).put("diagnostics", ArrivalDiagnostics.read(targetContext)))
                        }
                        reply.success(result)
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        emit("native_error", JSONObject().put("method", call.method).put("code", code))
                        reply.error(code, message, details)
                    }
                    override fun notImplemented() = reply.notImplemented()
                })
            }
            fixture = MethodChannel(engine.dartExecutor.binaryMessenger, "swipewise/qualification-fixture")
            fixture.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> { ready = true; emit("fixture_ready"); result.success(null) }
                    "record" -> { emit("seed_readback", JSONObject(call.arguments as Map<*, *>)); result.success(null) }
                    else -> result.notImplemented()
                }
            }
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
        var commandSequence = 0
        var lastHeartbeat = 0L
        val deadline = SystemClock.elapsedRealtime() + 1_500_000L
        try {
            while (!stopped && SystemClock.elapsedRealtime() < deadline) {
                observe()
                if (SystemClock.elapsedRealtime() - lastHeartbeat >= 10_000L) {
                    emit("heartbeat")
                    lastHeartbeat = SystemClock.elapsedRealtime()
                }
                val command = File(targetContext.filesDir, "qualification-command.json")
                if (ready && command.exists()) {
                    val data = JSONObject(command.readText())
                    require(data.getString("run_id") == run)
                    val seq = data.getInt("seq")
                    if (seq == commandSequence) {
                        commandSequence++
                        val action = data.getString("action")
                        emit("command", data)
                        if (action == "stop") stopped = true else runOnMainSync {
                            fixture.invokeMethod("run", action, object : MethodChannel.Result {
                                override fun success(result: Any?) { emit("command_done", data) }
                                override fun error(code: String, message: String?, details: Any?) {
                                    emit("fixture_error", JSONObject().put("code", code).put("message", message))
                                }
                                override fun notImplemented() { emit("fixture_error") }
                            })
                        }
                    }
                }
                SystemClock.sleep(100)
            }
            observe()
            emit(if (stopped) "instrumentation_finished" else "instrumentation_timeout")
        } finally {
            runOnMainSync {
                DwellCheckReceiver.locationProvider = DefaultLocationProvider
                DwellCheckReceiver.notificationPoster = DefaultNotificationPoster
                engine.destroy()
            }
            finish(if (stopped) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle())
        }
    }
}
