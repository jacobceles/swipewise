package com.appsoflife.swipewise

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

class GeofencePlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var client: GeofencingClient
    private lateinit var store: GeofenceMetadataStore

    private val merchantPendingIntent: PendingIntent by lazy {
        val intent = Intent(context, MerchantGeofenceReceiver::class.java).apply {
            action = MerchantGeofenceReceiver.ACTION
        }
        PendingIntent.getBroadcast(
            context,
            REQ_MERCHANT,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }

    private val boundaryPendingIntent: PendingIntent by lazy {
        val intent = Intent(context, BoundaryGeofenceReceiver::class.java).apply {
            action = BoundaryGeofenceReceiver.ACTION
        }
        PendingIntent.getBroadcast(
            context,
            REQ_BOUNDARY,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        client = LocationServices.getGeofencingClient(context)
        store = GeofenceMetadataStore(context)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "registerSet" -> registerSet(call, result)
            "unregisterAll" -> unregisterAll(result)
            "getRegisteredCount" -> result.success(store.count())
            "consumePendingMerchant" -> result.success(PendingMerchantStore.consume())
            "fireTestNotification" -> fireTestNotification(call, result)
            else -> result.notImplemented()
        }
    }

    private fun registerSet(call: MethodCall, result: MethodChannel.Result) {
        // Without Google Play services the GeofencingClient silently no-ops:
        // addGeofences never fires and no error surfaces. Fail loudly with a
        // dedicated error code so the Dart side records the geofence_degraded
        // non-fatal instead of the miss being invisible.
        val gmsStatus = GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(context)
        if (gmsStatus != ConnectionResult.SUCCESS) {
            result.error(
                "GMS_UNAVAILABLE",
                "Google Play services unavailable (status=$gmsStatus)",
                gmsStatus,
            )
            return
        }

        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val zones = (args["zones"] as List<Map<String, Any?>>?) ?: emptyList()
        @Suppress("UNCHECKED_CAST")
        val boundary = args["boundary"] as Map<String, Any?>?

        store.clear()
        val merchantGeofences = mutableListOf<Geofence>()
        for (z in zones) {
            val gid = z["geofence_id"] as String
            @Suppress("UNCHECKED_CAST")
            val rawOptions = (z["options"] as List<Map<String, Any?>>?) ?: emptyList()
            if (rawOptions.isEmpty()) continue
            val options = rawOptions.map { opt ->
                MerchantOption(
                    merchantId = opt["merchant_id"] as String,
                    name = opt["name"] as String,
                    category = opt["category"] as String?,
                    bestCardName = opt["best_card_name"] as String?,
                    bestRate = (opt["best_rate"] as? Number)?.toDouble(),
                )
            }

            val lat = (z["lat"] as Number).toDouble()
            val lng = (z["lng"] as Number).toDouble()
            val radius = (z["radius_m"] as Number).toFloat()
            val dwellSeconds = (z["dwell_seconds"] as Number).toInt()
            store.write(
                MerchantMeta(
                    geofenceId = gid,
                    options = options,
                    lat = lat,
                    lng = lng,
                    radiusM = radius,
                    dwellSeconds = dwellSeconds,
                ),
            )

            // ENTER/EXIT instead of the OS DWELL transition: the OS evaluates
            // loitering lazily on its own location cadence, so DWELL can fire
            // minutes late. Instead the receiver arms an exact alarm on ENTER
            // (cancelled on EXIT); DwellCheckReceiver then verifies with a
            // fresh fix before posting. Deterministic dwell timing.
            merchantGeofences.add(
                Geofence.Builder()
                    .setRequestId(gid)
                    .setCircularRegion(lat, lng, radius)
                    .setExpirationDuration(Geofence.NEVER_EXPIRE)
                    .setNotificationResponsiveness(60_000)
                    .setTransitionTypes(
                        Geofence.GEOFENCE_TRANSITION_ENTER or
                            Geofence.GEOFENCE_TRANSITION_EXIT,
                    )
                    .build(),
            )
        }

        Tasks.whenAllComplete(
            client.removeGeofences(merchantPendingIntent),
            client.removeGeofences(boundaryPendingIntent),
        ).addOnCompleteListener {
            val adds = mutableListOf<Task<Void>>()
            try {
                if (merchantGeofences.isNotEmpty()) {
                    // INITIAL_TRIGGER_ENTER: if the device is already inside a
                    // geofence when it's registered (e.g. the user is standing
                    // in the store when the re-register lands), deliver an
                    // ENTER right away so the dwell alarm gets armed. Without
                    // this, an already-inside geofence only fires after an
                    // explicit boundary crossing, so on-arrival registrations
                    // would never notify.
                    val req = GeofencingRequest.Builder()
                        .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
                        .addGeofences(merchantGeofences)
                        .build()
                    adds.add(client.addGeofences(req, merchantPendingIntent))
                }
                if (boundary != null) {
                    val blat = (boundary["lat"] as Number).toDouble()
                    val blng = (boundary["lng"] as Number).toDouble()
                    val brad = (boundary["radius_m"] as Number).toFloat()
                    val bgid = boundary["geofence_id"] as String
                    val bGeofence = Geofence.Builder()
                        .setRequestId(bgid)
                        .setCircularRegion(blat, blng, brad)
                        .setExpirationDuration(Geofence.NEVER_EXPIRE)
                        .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_EXIT)
                        .setNotificationResponsiveness(60_000)
                        .build()
                    val bReq = GeofencingRequest.Builder()
                        .setInitialTrigger(0)
                        .addGeofences(listOf(bGeofence))
                        .build()
                    adds.add(client.addGeofences(bReq, boundaryPendingIntent))
                }
            } catch (e: SecurityException) {
                result.error("PERMISSION_DENIED", e.message, null)
                return@addOnCompleteListener
            } catch (e: Exception) {
                result.error("ADD_FAILED", e.message, null)
                return@addOnCompleteListener
            }
            if (adds.isEmpty()) {
                result.success(0)
                return@addOnCompleteListener
            }
            // addGeofences() is asynchronous: returning normally only means the
            // request was accepted for delivery, not that the OS took the fences.
            // Reporting success here (as this did) hands Dart a count for a
            // registration Play services may still reject — GEOFENCE_NOT_AVAILABLE
            // when location is off, GEOFENCE_TOO_MANY_GEOFENCES at the per-app cap.
            // Dart would then log "registered N", stamp `geofence_last_register`
            // and never retry, leaving the device with no fences and no signal:
            // the same silent-miss class the Play-services check above exists to
            // prevent, one branch later. Await the tasks and report what happened.
            Tasks.whenAllComplete(adds).addOnCompleteListener { done ->
                val failed = done.result.firstOrNull { !it.isSuccessful }
                if (failed == null) {
                    result.success(merchantGeofences.size)
                } else {
                    result.error("ADD_FAILED", failed.exception?.message, null)
                }
            }
        }
    }

    private fun unregisterAll(result: MethodChannel.Result) {
        Tasks.whenAllComplete(
            client.removeGeofences(merchantPendingIntent),
            client.removeGeofences(boundaryPendingIntent),
        ).addOnCompleteListener {
            store.clear()
            result.success(null)
        }
    }

    private fun fireTestNotification(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        val args = (call.arguments as? Map<String, Any?>) ?: emptyMap()
        @Suppress("UNCHECKED_CAST")
        val rawOptions = (args["options"] as List<Map<String, Any?>>?) ?: emptyList()
        val options = if (rawOptions.isEmpty()) {
            // Fall back to a single-option default so callers can fire
            // without a payload.
            listOf(
                MerchantOption(
                    merchantId = args["merchant_id"] as? String ?: "test-merchant",
                    name = args["name"] as? String ?: "Five Guys",
                    category = args["category"] as? String ?: "Dining",
                    bestCardName = args["best_card_name"] as? String
                        ?: "Chase Sapphire Preferred",
                    bestRate = (args["best_rate"] as? Number)?.toDouble() ?: 3.0,
                ),
            )
        } else {
            rawOptions.map { opt ->
                MerchantOption(
                    merchantId = opt["merchant_id"] as String,
                    name = opt["name"] as String,
                    category = opt["category"] as String?,
                    bestCardName = opt["best_card_name"] as String?,
                    bestRate = (opt["best_rate"] as? Number)?.toDouble(),
                )
            }
        }
        NotificationHelper(context).postDwell(
            MerchantMeta(geofenceId = "test", options = options),
        )
        result.success(null)
    }

    companion object {
        const val CHANNEL = "com.appsoflife/geofence"
        private const val REQ_MERCHANT = 1001
        private const val REQ_BOUNDARY = 1002
    }
}
