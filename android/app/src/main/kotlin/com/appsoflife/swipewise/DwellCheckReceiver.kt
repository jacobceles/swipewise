package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
    override fun getCurrentLocation(
        context: Context,
        priority: Int,
        durationMillis: Long,
        maxUpdateAgeMillis: Long,
        cancellationToken: CancellationToken,
        onSuccess: (Location?) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        val client = LocationServices.getFusedLocationProviderClient(context)
        val request = CurrentLocationRequest.Builder()
            .setPriority(priority)
            .setDurationMillis(durationMillis)
            .setMaxUpdateAgeMillis(maxUpdateAgeMillis)
            .build()
        client.getCurrentLocation(request, cancellationToken)
            .addOnSuccessListener { fix -> onSuccess(fix) }
            .addOnFailureListener { e -> onFailure(e) }
    }
}

interface NotificationPoster {
    fun postDwell(context: Context, meta: MerchantMeta): Boolean
}

object DefaultNotificationPoster : NotificationPoster {
    override fun postDwell(context: Context, meta: MerchantMeta): Boolean =
        NotificationHelper(context).postDwell(meta)
}

/// Fires when a dwell timer armed on fence ENTER survives its full delay
/// (no EXIT cancelled it). Before posting, verifies the user is genuinely
/// still at the fence with one shared arrival verification policy on
/// initial check AND recheck.
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
        if (meta.lat == null || meta.lng == null || meta.radiusM == null) {
            WalkinLog.w(context, "dwell $geofenceId: missing geometry -> fail closed")
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
                val outcome = if (ActivityState.isLikelyDriving(context)) {
                    DwellOutcome.NO_FIX_DRIVING
                } else {
                    DwellOutcome.NO_FIX_TIMEOUT
                }
                verdictWithoutFix(context, meta, fetchingAttempt, outcome)
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
                            val outcome = if (ActivityState.isLikelyDriving(context)) {
                                DwellOutcome.NO_FIX_DRIVING
                            } else {
                                DwellOutcome.NO_FIX_NULL
                            }
                            verdictWithoutFix(context, meta, fetchingAttempt, outcome)
                        } else {
                            verdictWithFix(context, meta, fix, fetchingAttempt)
                        }
                    }
                },
                onFailure = {
                    handler.removeCallbacks(timeoutRunnable)
                    finishOnce {
                        val outcome = if (ActivityState.isLikelyDriving(context)) {
                            DwellOutcome.NO_FIX_DRIVING
                        } else {
                            DwellOutcome.NO_FIX_ERROR
                        }
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
            WalkinLog.w(context, "dwell ${meta.geofenceId}: no candidates within reach -> fail closed")
            return null
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
        DwellAlarms.cancel(context, meta.geofenceId, attempt.token)
        done(context, meta, outcome)
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
            if (refreshed.nextDoorCandidateId != null && !DwellAlarms.isArmed(context, meta.geofenceId)) {
                DwellAlarms.arm(context, meta.geofenceId, meta.dwellSeconds, nextDoor = true)
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
        if (!notificationPoster.postDwell(context, meta)) {
            DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
            done(context, meta, DwellOutcome.NOTIFICATIONS_OFF, fix)
            return
        }
        if (visitLat != null && visitLng != null) {
            VisitLock.write(
                context,
                VisitLock.Visit(
                    visitLat,
                    visitLng,
                    now,
                    meta.geofenceId,
                    resolved.orEmpty().map { it.merchantId },
                    resolved.orEmpty().map { VisitLock.adviceOf(it) },
                ),
            )
        }
        cooldown.markNotified(primary, now)
        DwellAlarms.cancel(context, attempt.geofenceId, attempt.token)
        done(context, meta, DwellOutcome.POSTED, fix)
    }

    private fun done(context: Context, meta: MerchantMeta, outcome: DwellOutcome, fix: DwellFix? = null) {
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
