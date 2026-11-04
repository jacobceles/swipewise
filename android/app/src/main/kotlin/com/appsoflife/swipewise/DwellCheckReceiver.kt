package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.RequiresPermission
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationToken
import com.google.android.gms.tasks.CancellationTokenSource

interface LocationProvider {
    fun getCurrentLocation(
        context: Context,
        priority: Int,
        durationMillis: Long,
        maxUpdateAgeMillis: Long,
        cancellationToken: CancellationToken,
        onSuccess: (Location?) -> Unit,
        onFailure: (Exception) -> Unit,
    )
}

object DefaultLocationProvider : LocationProvider {
    @Volatile var requestLocation: (Context, CurrentLocationRequest, CancellationToken) -> com.google.android.gms.tasks.Task<Location> =
        ::requestCurrentLocation

    @RequiresPermission(anyOf = ["android.permission.ACCESS_COARSE_LOCATION", "android.permission.ACCESS_FINE_LOCATION"])
    private fun requestCurrentLocation(context: Context, request: CurrentLocationRequest, token: CancellationToken): com.google.android.gms.tasks.Task<Location> =
        LocationServices.getFusedLocationProviderClient(context).getCurrentLocation(request, token)

    private class SharedFix(val task: com.google.android.gms.tasks.Task<Location>, val cancellation: CancellationTokenSource) {
        var consumers = 0
    }
    // Receivers and task listeners run on the main thread. Share only requests
    // with identical bounds; one fence EXIT must not cancel another's verifier.
    private val inFlight = mutableMapOf<Triple<Int, Long, Long>, SharedFix>()

    override fun getCurrentLocation(
        context: Context,
        priority: Int,
        durationMillis: Long,
        maxUpdateAgeMillis: Long,
        cancellationToken: CancellationToken,
        onSuccess: (Location?) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        val key = Triple(priority, durationMillis, maxUpdateAgeMillis)
        val shared = inFlight[key]?.takeUnless { it.task.isComplete || it.cancellation.token.isCancellationRequested } ?: run {
            val cancellation = CancellationTokenSource()
            val request = CurrentLocationRequest.Builder().setPriority(priority)
                .setDurationMillis(durationMillis).setMaxUpdateAgeMillis(maxUpdateAgeMillis).build()
            val task = requestLocation(context, request, cancellation.token)
            SharedFix(task, cancellation).also { job ->
                inFlight[key] = job
                job.task.addOnCompleteListener { if (inFlight[key] === job) inFlight.remove(key) }
            }
        }
        shared.consumers++
        cancellationToken.onCanceledRequested {
            shared.consumers--
            if (shared.consumers == 0) {
                shared.cancellation.cancel()
                if (inFlight[key] === shared) inFlight.remove(key)
            }
        }
        shared.task.addOnSuccessListener { fix -> if (!cancellationToken.isCancellationRequested) onSuccess(fix) }
            .addOnFailureListener { e -> if (!cancellationToken.isCancellationRequested) onFailure(e) }
    }
}

interface NotificationPoster {
    fun postDwell(context: Context, meta: MerchantMeta, verifiedAtMillis: Long): Boolean
}

object DefaultNotificationPoster : NotificationPoster {
    override fun postDwell(context: Context, meta: MerchantMeta, verifiedAtMillis: Long): Boolean =
        NotificationHelper(context).postDwell(meta, verifiedAtMillis)
}

/// Fires when a dwell timer armed on fence ENTER survives its full delay
/// (no EXIT cancelled it). Fresh fixes refine the advice; unavailable/stale
/// fixes use uncertain fence advice unless driving. The live attempt, account
/// and geometry checks still apply on every path.
class DwellCheckReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        WalkinState.migrate(context)
        val geofenceId = DwellAlarms.geofenceIdFromIntent(intent) ?: return
        val token = DwellAlarms.tokenFromIntent(intent)
        val attempt = DwellAlarms.validateAttempt(context, geofenceId, token)
        if (attempt == null) {
            WalkinLog.w(context, "dwell $geofenceId: invalid, overdue, or cancelled attempt (token=$token)")
            return
        }

        val intentIsRecheck = DwellAlarms.isRecheck(intent)
        val expectedPhase = if (intentIsRecheck) AttemptPhase.RECHECK_ARMED else AttemptPhase.ARMED
        if (attempt.phase != expectedPhase) {
            WalkinLog.w(
                context,
                "dwell $geofenceId: phase mismatch (attempt=${attempt.phase}, intentIsRecheck=$intentIsRecheck) token=$token",
            )
            return
        }

        val nowNanos = SystemClock.elapsedRealtimeNanos()
        if (nowNanos < attempt.scheduledDueElapsedNanos - 1_000_000_000L) {
            WalkinLog.w(
                context,
                "dwell $geofenceId: premature delivery (now=$nowNanos < due=${attempt.scheduledDueElapsedNanos}) token=$token",
            )
            return
        }

        val nextPhase = if (intentIsRecheck) AttemptPhase.FETCHING_RECHECK else AttemptPhase.FETCHING_INITIAL
        val fetchingAttempt = DwellAlarms.updatePhase(context, geofenceId, token, nextPhase) ?: return

        DwellAlarms.markFired(context, geofenceId)
        val meta = GeofenceMetadataStore(context).read(geofenceId)
        if (meta == null) {
            WalkinLog.w(context, "dwell $geofenceId: no_meta (fence set replaced mid-dwell)")
            DwellAlarms.cancel(context, geofenceId, token)
            return
        }
        if (meta.lat == null || meta.lng == null || meta.radiusM == null ||
            ArrivalPolicy.isInvalidFence(FenceGeometry(meta.lat, meta.lng, meta.radiusM))) {
            WalkinLog.w(context, "dwell $geofenceId: missing or invalid geometry -> fail closed")
            done(context, meta, DwellOutcome.NO_META)
            DwellAlarms.cancel(context, geofenceId, token)
            return
        }

        val pending = goAsync()
        val cts = CancellationTokenSource()
        val handler = Handler(Looper.getMainLooper())
        var finished = false

        fun finishOnce(block: () -> Unit) {
            if (finished) return
            finished = true
            try {
                val currentAttempt = DwellAlarms.validateAttempt(context, geofenceId, token)
                if (currentAttempt != null && currentAttempt.phase == fetchingAttempt.phase) {
                    block()
                } else {
                    WalkinLog.w(context, "dwell $geofenceId: attempt invalidated or phase mismatch mid-flight (token=$token)")
                }
            } finally {
                cts.cancel()
                pending?.finish()
            }
        }

        val timeoutRunnable = Runnable {
            finishOnce {
                verdictWithoutFix(context, meta, fetchingAttempt, DwellOutcome.NO_FIX_TIMEOUT)
            }
        }
        handler.postDelayed(timeoutRunnable, FIX_TIMEOUT_MS)

        try {
            val priority = if (intentIsRecheck) Priority.PRIORITY_HIGH_ACCURACY else Priority.PRIORITY_BALANCED_POWER_ACCURACY
            locationProvider.getCurrentLocation(
                context = context,
                priority = priority,
                durationMillis = FIX_TIMEOUT_MS,
                maxUpdateAgeMillis = MAX_UPDATE_AGE_MS,
                cancellationToken = cts.token,
                onSuccess = { fix ->
                    handler.removeCallbacks(timeoutRunnable)
                    finishOnce {
                        if (fix == null) {
                            verdictWithoutFix(context, meta, fetchingAttempt, DwellOutcome.NO_FIX_NULL)
                        } else {
                            verdictWithFix(context, meta, fix, fetchingAttempt)
                        }
                    }
                },
                onFailure = { error ->
                    handler.removeCallbacks(timeoutRunnable)
                    finishOnce {
                        val status = (error as? com.google.android.gms.common.api.ApiException)?.statusCode
                        WalkinLog.w(context, "dwell location failed ${error.javaClass.simpleName} status=$status")
                        val outcome = if (error is SecurityException) DwellOutcome.NO_FIX_SECURITY else DwellOutcome.NO_FIX_ERROR
                        verdictWithoutFix(context, meta, fetchingAttempt, outcome)
                    }
                },
            )
        } catch (_: SecurityException) {
            handler.removeCallbacks(timeoutRunnable)
            finishOnce {
                verdictWithoutFix(context, meta, fetchingAttempt, DwellOutcome.NO_FIX_SECURITY)
            }
        }
    }

    private fun verdictWithFix(
        context: Context,
        meta: MerchantMeta,
        fix: Location,
        attempt: DwellAttempt,
    ) {
        val nowElapsedNanos = SystemClock.elapsedRealtimeNanos()
        val currentObs = FixObservation(
            lat = fix.latitude,
            lng = fix.longitude,
            accuracyM = fix.accuracy,
            elapsedRealtimeNanos = fix.elapsedRealtimeNanos,
            speedMps = if (fix.hasSpeed()) fix.speed else null,
            hasAccuracy = fix.hasAccuracy(),
        )
        val priorObs = if (attempt.initialLat != null && attempt.initialLng != null &&
            attempt.initialAccuracyM != null && attempt.initialElapsedNanos != null
        ) {
            FixObservation(
                lat = attempt.initialLat,
                lng = attempt.initialLng,
                accuracyM = attempt.initialAccuracyM,
                elapsedRealtimeNanos = attempt.initialElapsedNanos,
                hasAccuracy = true,
            )
        } else {
            null
        }

        val fence = FenceGeometry(meta.lat!!, meta.lng!!, meta.radiusM!!)
        val activity = ActivityState.getObservation(context, nowElapsedNanos)

        val decision = ArrivalPolicy.evaluate(
            currentFix = currentObs,
            priorFix = priorObs,
            fence = fence,
            activity = activity,
            isRecheck = attempt.isRecheck,
            isNextDoor = attempt.isNextDoor,
            nowElapsedNanos = nowElapsedNanos,
        )

        val measured = DwellFix(decision.distanceM, fix.accuracy, decision.allowedM)
        WalkinLog.w(
            context,
            "dwell decision $decision recheck=${attempt.isRecheck} " +
                "speed=${currentObs.speedMps} ${ActivityState.diagnostic(context, nowElapsedNanos)}",
        )

        when (decision.verdict) {
            ArrivalVerdict.FALLBACK -> fallbackAdvice(context, attempt, decision.outcome)
            ArrivalVerdict.RECHECK -> {
                val rearmed = DwellAlarms.armRecheck(
                    context = context,
                    geofenceId = meta.geofenceId,
                    dwellSeconds = meta.dwellSeconds,
                    attempt = attempt,
                    priorObservation = currentObs,
                    nowElapsedNanos = nowElapsedNanos,
                )
                if (rearmed != null) {
                    done(context, meta, decision.outcome, measured)
                } else {
                    DwellAlarms.cancel(context, meta.geofenceId, attempt.token)
                }
            }
            ArrivalVerdict.REJECT -> {
                DwellAlarms.cancel(context, meta.geofenceId, attempt.token)
                done(context, meta, decision.outcome, measured)
            }
            ArrivalVerdict.VERIFIED -> {
                val resolved = resolveAtFix(context, meta, fix, decision.allowedM.toDouble())
                if (resolved == null) {
                    DwellAlarms.cancel(context, meta.geofenceId, attempt.token)
                    done(context, meta, DwellOutcome.NOT_AT_STORE, measured)
                    return
                }
                val (found, byFix) = resolved
                if (DwellAlarms.validateAttempt(context, meta.geofenceId, attempt.token) == null) {
                    return
                }
                VisitLock.observeDeparture(context, fix)
                maybePost(context, found, measured, fix.latitude, fix.longitude, byFix, attempt, fix.elapsedRealtimeNanos)
            }
        }
    }

    private fun resolveAtFix(
        context: Context,
        meta: MerchantMeta,
        fix: Location,
        reach: Double,
    ): Pair<MerchantMeta, Boolean>? {
        if (!fix.hasAccuracy() || fix.accuracy > StoreResolver.MAX_ACCURACY_M) {
            WalkinLog.w(context, "dwell ${meta.geofenceId}: fix acc=${fix.accuracy.toInt()} too coarse -> fail closed")
            return null
        }
        val allMetas = GeofenceMetadataStore(context).readAll()
        val candidates = StoreResolver.candidates(
            allMetas.flatMap { it.options },
            fix.latitude,
            fix.longitude,
            reach,
        )
        if (candidates.isEmpty()) {
            if (meta.options.any { it.lat != null && it.lng != null } || meta.options.none { it.walkinEligible }) {
                WalkinLog.w(context, "dwell ${meta.geofenceId}: no candidates within reach -> fail closed")
                return null
            }
            return meta.copy(options = StoreResolver.capped(meta.options, fix.latitude, fix.longitude)) to false
        }
        val picked = StoreResolver.resolveAtStore(candidates, fix.accuracy.toDouble())
        if (picked.isNullOrEmpty()) {
            WalkinLog.w(context, "dwell ${meta.geofenceId}: resolution returned empty -> fail closed")
            return null
        }
        val ownerFenceId = allMetas.firstOrNull { m ->
            m.options.any { it.merchantId == picked.first().merchantId }
        }?.geofenceId ?: meta.geofenceId
        return meta.copy(geofenceId = ownerFenceId, options = picked) to true
    }

    private fun verdictWithoutFix(
        context: Context,
        meta: MerchantMeta,
        attempt: DwellAttempt,
        outcome: DwellOutcome,
    ) {
        WalkinLog.w(context, "dwell no fix $outcome ${ActivityState.diagnostic(context)}")
        if (outcome == DwellOutcome.NO_FIX_SECURITY) {
            DwellAlarms.cancel(context, meta.geofenceId, attempt.token)
            done(context, meta, outcome)
        } else {
            fallbackAdvice(context, attempt, outcome)
        }
    }

    private fun fallbackAdvice(context: Context, attempt: DwellAttempt, reason: DwellOutcome) {
        if (DwellAlarms.validateAttempt(context, attempt.geofenceId, attempt.token) == null) return
        val meta = GeofenceMetadataStore(context).read(attempt.geofenceId) ?: return
        if (attempt.isNextDoor) {
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            done(context, meta, reason)
            return
        }
        val granted = android.content.pm.PackageManager.PERMISSION_GRANTED
        if (androidx.core.content.ContextCompat.checkSelfPermission(context, "android.permission.ACCESS_COARSE_LOCATION") != granted &&
            androidx.core.content.ContextCompat.checkSelfPermission(context, "android.permission.ACCESS_FINE_LOCATION") != granted) {
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            done(context, meta, DwellOutcome.NO_FIX_SECURITY)
            return
        }
        if (ActivityState.isLikelyDriving(context)) {
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            done(context, meta, DwellOutcome.MOVING_RECHECK)
            return
        }
        val event = when (reason) {
            DwellOutcome.STALE_FIX -> ArrivalDiagnostics.Event.FALLBACK_STALE
            DwellOutcome.COARSE_RECHECK -> ArrivalDiagnostics.Event.FALLBACK_COARSE
            else -> ArrivalDiagnostics.Event.FALLBACK_NO_FIX
        }
        ArrivalDiagnostics.record(context, event)
        WalkinLog.w(context, "dwell ${attempt.geofenceId}: uncertain fence advice after ${reason.wire}")
        val options = if (meta.lat != null && meta.lng != null && meta.radiusM != null) {
            val metaBrands = meta.options.mapNotNull { it.brandId }.filter { it.isNotBlank() }.toSet()
            val reach = meta.radiusM + StoreResolver.AT_STORE_M
            val sameBrandMainStores = GeofenceMetadataStore(context).readAll()
                .flatMap { it.options }
                .filter { o ->
                    o.mainStore && o.brandId != null && o.brandId in metaBrands &&
                        o.lat != null && o.lng != null &&
                        distanceM(meta.lat, meta.lng, o.lat, o.lng) <= reach
                }
            val folded = meta.options.map { opt ->
                StoreResolver.foldSameAdvice(listOf(opt) + sameBrandMainStores).first()
            }.distinctBy { it.merchantId }
            StoreResolver.capped(folded, meta.lat, meta.lng)
        } else {
            StoreResolver.capped(meta.options, meta.lat, meta.lng)
        }
        maybePost(context, meta.copy(options = options, approximate = true), attempt = attempt,
            sampleNanos = SystemClock.elapsedRealtimeNanos())
    }

    private fun maybePost(
        context: Context,
        found: MerchantMeta,
        fix: DwellFix? = null,
        atLat: Double? = null,
        atLng: Double? = null,
        byFix: Boolean = false,
        attempt: DwellAttempt,
        sampleNanos: Long,
    ) {
        val currentAttempt = DwellAlarms.validateAttempt(context, attempt.geofenceId, attempt.token)
        if (currentAttempt == null) {
            WalkinLog.w(context, "dwell ${attempt.geofenceId}: attempt invalidated before post")
            return
        }

        val muted = MutedStore(context)
        fun isOptionMuted(o: MerchantOption) = o.muted || muted.isMuted(o.merchantId)
        if (found.options.isEmpty() || isOptionMuted(found.primary) || found.options.all(::isOptionMuted)) {
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            done(context, found, DwellOutcome.MUTED, fix)
            return
        }
        val unmutedOptions = found.options.filterNot(::isOptionMuted)
        val (ordered, usualFirst) = StoreResolver.preferPicked(
            unmutedOptions,
            PickStore(context).picks(unmutedOptions.map { it.merchantId }),
        )
        val meta = found.copy(options = ordered, usualFirst = usualFirst)
        val cooldown = CooldownStore(context)
        val now = System.currentTimeMillis()
        val primary = meta.primary
        val visitLat = atLat ?: meta.lat
        val visitLng = atLng ?: meta.lng
        val lastVisit = VisitLock.read(context)
        val resolved = if (byFix) meta.options else null

        if (visitLat != null && visitLng != null &&
            VisitLock.isSameVisit(lastVisit, visitLat, visitLng, now, resolved, sampleNanos)
        ) {
            val refreshed = VisitLock.refresh(lastVisit!!, now, resolved, meta.geofenceId, sampleNanos, visitLat, visitLng)
            VisitLock.write(context, refreshed)
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            if (refreshed.nextDoorCandidateId != null &&
                !attempt.confirmation &&
                !DwellAlarms.isArmed(context, meta.geofenceId)) {
                DwellAlarms.arm(context, meta.geofenceId, meta.dwellSeconds, nextDoor = true, confirmation = true)
            }
            done(context, meta, DwellOutcome.SAME_VISIT, fix)
            return
        }
        val lastMerchant = cooldown.lastMerchantNotified(primary.merchantId)
        if (lastMerchant != null && now - lastMerchant < MERCHANT_COOLDOWN_MS) {
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            done(context, meta, DwellOutcome.MERCHANT_COOLDOWN, fix)
            return
        }
        val verifiedAt = if (meta.approximate) now else
            now - ((SystemClock.elapsedRealtimeNanos() - sampleNanos).coerceAtLeast(0L) / 1_000_000L)
        if (!notificationPoster.postDwell(context, meta, verifiedAt)) {
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            done(context, meta, DwellOutcome.NOTIFICATIONS_OFF, fix)
            return
        }
        if (visitLat != null && visitLng != null) {
            val notifiedOptions = meta.options
            VisitLock.write(
                context,
                VisitLock.Visit(
                    visitLat,
                    visitLng,
                    now,
                    meta.geofenceId,
                    notifiedOptions.map { it.merchantId },
                    notifiedOptions.map { VisitLock.adviceOf(it) },
                    confirmed = true,
                    brandIds = notifiedOptions.mapNotNull { it.brandId },
                ),
            )
        }
        cooldown.markNotified(primary, now)
        DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
        done(context, meta, if (meta.approximate) DwellOutcome.POSTED_APPROXIMATE else DwellOutcome.POSTED, fix)
    }

    private fun done(context: Context, meta: MerchantMeta, outcome: DwellOutcome, fix: DwellFix? = null) {
        ArrivalDiagnostics.outcome(context, outcome)
        WalkinLog.w(
            context,
            "dwell ${meta.geofenceId}: ${outcome.wire} " +
                meta.options.joinToString("|") { it.name } +
                (fix?.let { " dist=${it.distanceM.toInt()}m acc=${it.accuracyM.toInt()}m" } ?: ""),
        )
    }

    companion object {
        const val FIX_TIMEOUT_MS = 8_000L
        const val MAX_UPDATE_AGE_MS = 15_000L
        private const val MERCHANT_COOLDOWN_MS = 6L * 60L * 60L * 1000L

        @Volatile
        var locationProvider: LocationProvider = DefaultLocationProvider

        @Volatile
        var notificationPoster: NotificationPoster = DefaultNotificationPoster
    }
}
