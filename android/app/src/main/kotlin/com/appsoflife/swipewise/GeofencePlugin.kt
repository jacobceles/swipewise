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
            "unregisterAll" -> unregisterAll(result, call.arguments as? Map<*, *>)
            "clearAccountState" -> {
                accountEpoch++
                store.clear()
                DwellAlarms.cancelAll(context)
                PendingMerchantStore.consume()
                WalkinLog.clear(context)
                for (name in listOf("swipewise_visit_lock", "swipewise_resident", "swipewise_reregister")) {
                    context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().apply()
                }
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager).cancelAll()
                unregisterAll(result)
            }
            "getRegisteredCount" -> result.success(store.count())
            "accountEpoch" -> result.success(accountEpoch)
            "recoveryGeneration" -> result.success(PendingReregister.generation(context))
            "requestRefresh" -> {
                val args = call.arguments as Map<*, *>
                val owner = if ((args["account_epoch"] as? Number)?.toLong() == accountEpoch)
                    isCurrentUser(args["user_id"] as? String) else false
                if (owner != true) result.error(if (owner == null) "ACCOUNT_CHECK_FAILED" else "STALE_ACCOUNT", "Recovery owner changed", null)
                else {
                    PendingReregister.request(context, FootReregister.COOLDOWN_MS, "coverage")
                    result.success(null)
                }
            }
            "consumePendingMerchant" -> result.success(PendingMerchantStore.consume())
            "startActivityUpdates" -> {
                ActivitySubscriber.start(context)
                result.success(null)
            }
            "fireTestNotification" -> fireTestNotification(call, result)
            "walkinLog" -> {
                WalkinLog.w(context, call.arguments as? String ?: "")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun registerSet(call: MethodCall, result: MethodChannel.Result) {
        runSerialized { done ->
            registerSetLocked(call, result, done)
        }
    }

    private fun registerSetLocked(
        call: MethodCall,
        result: MethodChannel.Result,
        done: () -> Unit,
    ) {
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
            done()
            return
        }

        @Suppress("UNCHECKED_CAST")
        val args = call.arguments as Map<String, Any?>
        // A background isolate may finish a Places request after logout. Check
        // the owner inside the native registration queue, not just in Dart.
        val currentOwner = if ((args["account_epoch"] as? Number)?.toLong() != accountEpoch) false
            else isCurrentUser(args["user_id"] as? String)
        if (currentOwner != true) {
            result.error(if (currentOwner == null) "ACCOUNT_CHECK_FAILED" else "STALE_ACCOUNT",
                "Could not validate registration owner", null)
            done()
            return
        }
        @Suppress("UNCHECKED_CAST")
        val zones = (args["zones"] as List<Map<String, Any?>>?) ?: emptyList()
        @Suppress("UNCHECKED_CAST")
        val boundary = args["boundary"] as Map<String, Any?>?

        val hash = registrationHash(zones, boundary, RESPONSIVENESS_MS)
        val merchantHash = registrationHash(zones, null, RESPONSIVENESS_MS)
        val recoveryGeneration = (args["recovery_generation"] as? Number)?.toLong() ?: -1L
        val force = PendingReregister.forceRecovery(context)
        val keepMerchants = merchantHash == lastMerchantHash && !force
        val unchanged = hash == lastRegisteredHash &&
            !force && (store.count() > 0 || zones.isEmpty())

        if (!keepMerchants) {
            store.clear()
        }
        val merchantGeofences = mutableListOf<Geofence>()
        for (z in zones) {
            val gid = z["geofence_id"] as String
            @Suppress("UNCHECKED_CAST")
            val rawOptions = (z["options"] as List<Map<String, Any?>>?) ?: emptyList()
            if (rawOptions.isEmpty()) continue
            val options = rawOptions.map(MerchantOption::fromChannelMap).filter { it.walkinEligible }
            if (options.isEmpty()) continue

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
                    .setNotificationResponsiveness(RESPONSIVENESS_MS)
                    .setTransitionTypes(
                        Geofence.GEOFENCE_TRANSITION_ENTER or
                            Geofence.GEOFENCE_TRANSITION_EXIT,
                    )
                    .build(),
            )
        }

        if (unchanged) {
            PendingReregister.complete(context, recoveryGeneration)
            WalkinLog.w(
                context,
                "registerSet unchanged zones=${merchantGeofences.size} -> kept OS fences",
            )
            result.success(merchantGeofences.size)
            done()
            return
        }

        WalkinLog.w(
            context,
            "registerSet zones=${merchantGeofences.size} ids=" +
                merchantGeofences.take(8).joinToString(",") { it.requestId } +
                (if (merchantGeofences.size > 8) ",…" else "") +
                " boundary_m=${(boundary?.get("radius_m") as? Number)?.toInt()}",
        )
        val removals = mutableListOf<Task<Void>>()
        if (!keepMerchants) removals.add(client.removeGeofences(merchantPendingIntent))
        removals.add(client.removeGeofences(boundaryPendingIntent))
        Tasks.whenAllComplete(removals).addOnCompleteListener {
            val adds = mutableListOf<Task<Void>>()
            try {
                if (!keepMerchants && merchantGeofences.isNotEmpty()) {
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
                        .setNotificationResponsiveness(RESPONSIVENESS_MS)
                        .build()
                    val bReq = GeofencingRequest.Builder()
                        .setInitialTrigger(0)
                        .addGeofences(listOf(bGeofence))
                        .build()
                    adds.add(client.addGeofences(bReq, boundaryPendingIntent))
                }
            } catch (e: SecurityException) {
                lastRegisteredHash = null
                result.error("PERMISSION_DENIED", e.message, null)
                done()
                return@addOnCompleteListener
            } catch (e: Exception) {
                lastRegisteredHash = null
                result.error("ADD_FAILED", e.message, null)
                done()
                return@addOnCompleteListener
            }
            if (adds.isEmpty()) {
                lastRegisteredHash = hash
                lastMerchantHash = merchantHash
                PendingReregister.complete(context, recoveryGeneration)
                result.success(0)
                done()
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
            Tasks.whenAllComplete(adds).addOnCompleteListener { completed ->
                val failed = completed.result.firstOrNull { !it.isSuccessful }
                if (failed == null) {
                    lastRegisteredHash = hash
                    lastMerchantHash = merchantHash
                    PendingReregister.complete(context, recoveryGeneration)
                    result.success(merchantGeofences.size)
                } else {
                    lastRegisteredHash = null
                    result.error("ADD_FAILED", failed.exception?.message, null)
                }
                done()
            }
        }
    }

    private fun unregisterAll(result: MethodChannel.Result, owner: Map<*, *>? = null) {
        runSerialized { done ->
            if (owner != null) {
                val currentOwner = if ((owner["account_epoch"] as? Number)?.toLong() != accountEpoch) false
                    else isCurrentUser(owner["user_id"] as? String)
                if (currentOwner != true) {
                    if (currentOwner == null) result.error("ACCOUNT_CHECK_FAILED", "Could not validate fence owner", null)
                    else result.success(null)
                    done()
                    return@runSerialized
                }
            }
            accountEpoch++ // Invalidates an enabled search/fix that finishes after disable.
            PendingReregister.complete(context, PendingReregister.generation(context))
            lastRegisteredHash = null
            lastMerchantHash = null
            store.clear()
            try {
                Tasks.whenAllComplete(
                    client.removeGeofences(merchantPendingIntent),
                    client.removeGeofences(boundaryPendingIntent),
                ).addOnCompleteListener { completed ->
                    val failed = completed.result.firstOrNull { !it.isSuccessful }
                    if (failed == null) result.success(null)
                    else result.error("REMOVE_FAILED", failed.exception?.message, null)
                    done()
                }
            } catch (e: SecurityException) {
                result.error("PERMISSION_DENIED", e.message, null)
                done()
            }
        }
    }

    // null means the check could not run: retry, never report a stale no-op.
    private fun isCurrentUser(userId: String?): Boolean? {
        if (userId == null) return false
        return try {
            android.database.sqlite.SQLiteDatabase.openDatabase(
                context.getDatabasePath("swipewise.db").absolutePath, null,
                android.database.sqlite.SQLiteDatabase.OPEN_READONLY,
            ).use { db ->
                db.rawQuery("SELECT 1 FROM users WHERE id = ?", arrayOf(userId)).use { it.moveToFirst() }
            }
        } catch (_: Exception) { null }
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
                    brandId = args["brand_id"] as? String,
                    mainStore = args["main_store"] == true,
                ),
            )
        } else {
            rawOptions.map(MerchantOption::fromChannelMap)
        }
        NotificationHelper(context).postDwell(
            MerchantMeta(geofenceId = "test", options = options),
        )
        result.success(null)
    }

    companion object {
        @Volatile var accountEpoch: Long = 0
        const val CHANNEL = "com.appsoflife/geofence"
        private const val REQ_MERCHANT = 1001
        private const val REQ_BOUNDARY = 1002
        private const val RESPONSIVENESS_MS = 60_000

        private val registerLock = Any()
        private var registerInFlight = false
        private val registerQueue = ArrayDeque<() -> Unit>()

        @Volatile
        private var lastRegisteredHash: Int? = null
        @Volatile private var lastMerchantHash: Int? = null

        private fun runSerialized(action: (done: () -> Unit) -> Unit) {
            synchronized(registerLock) {
                if (!registerInFlight) {
                    registerInFlight = true
                } else {
                    registerQueue.addLast { action(::advanceQueue) }
                    return
                }
            }
            action(::advanceQueue)
        }

        private fun advanceQueue() {
            val next = synchronized(registerLock) {
                if (registerQueue.isEmpty()) {
                    registerInFlight = false
                    null
                } else {
                    registerQueue.removeFirst()
                }
            }
            next?.invoke()
        }

        fun registrationHash(
            zones: List<Map<String, Any?>>,
            boundary: Map<String, Any?>?,
            responsivenessMs: Int = RESPONSIVENESS_MS,
        ): Int {
            val zoneSig = zones.mapNotNull { z ->
                @Suppress("UNCHECKED_CAST")
                val rawOptions = (z["options"] as List<Map<String, Any?>>?) ?: emptyList()
                if (rawOptions.isEmpty()) return@mapNotNull null
                val gid = z["geofence_id"] as String
                val lat = (z["lat"] as Number).toDouble()
                val lng = (z["lng"] as Number).toDouble()
                val radius = (z["radius_m"] as Number).toFloat()
                val dwell = (z["dwell_seconds"] as Number).toInt()
                "$gid:$lat:$lng:$radius:$dwell"
            }.sorted().joinToString("|")
            val boundarySig = if (boundary == null) {
                ""
            } else {
                val bgid = boundary["geofence_id"] as String
                val blat = (boundary["lat"] as Number).toDouble()
                val blng = (boundary["lng"] as Number).toDouble()
                val brad = (boundary["radius_m"] as Number).toFloat()
                "$bgid:$blat:$blng:$brad"
            }
            return "$responsivenessMs#$zoneSig#$boundarySig".hashCode()
        }
    }
}
