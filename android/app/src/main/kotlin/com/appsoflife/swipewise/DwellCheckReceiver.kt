package com.appsoflife.swipewise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.Handler
import android.os.Looper
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource

/// Fires when a dwell timer armed on fence ENTER survives its full delay
/// (no EXIT cancelled it). Before posting, verifies the user is genuinely
/// still at the fence with one fresh location fix + the activity state:
///
///   - fix inside the fence (radius + fix accuracy slack) → post
///   - fix inside but still moving (activity says IN_VEHICLE, or the fix has
///     speed) → a red light beside the store: re-arm once, and the second look
///     posts only if the user is still inside
///   - fix outside → skip (classic false ENTER: red light at a strip mall,
///     or the EXIT event was delivered too late to cancel the timer)
///   - no fix obtainable in time → post unless activity says IN_VEHICLE
///     (fail-open: a missed verification must not eat a legit notification)
///
/// With a fix, the store named is decided across EVERY registered fence
/// ([StoreResolver]), not just the one whose timer fired: fences overlap, so
/// the firing fence is often a neighbour's.
///
/// Suppression, in order: resident fence ([ResidentGuard], before any fix),
/// muted, same visit ([VisitLock] — one walk-in, one notification), 6h per
/// merchant.
class DwellCheckReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val geofenceId = DwellAlarms.geofenceIdFromIntent(intent) ?: return
        val recheck = DwellAlarms.isRecheck(intent)
        val nextDoor = DwellAlarms.isNextDoor(intent)
        DwellAlarms.markFired(context, geofenceId)
        val meta = GeofenceMetadataStore(context).read(geofenceId)
        if (meta == null) {
            // Fence set was replaced while this timer was in flight.
            WalkinLog.w(context, "dwell $geofenceId: no_meta (fence set replaced mid-dwell)")
            return
        }
        if (!recheck && !nextDoor && ResidentGuard.check(context, geofenceId, System.currentTimeMillis())) {
            done(context, meta, DwellOutcome.RESIDENT)
            return
        }

        if (meta.lat == null || meta.lng == null || meta.radiusM == null) {
            // Meta written by an older build — can't geo-verify.
            maybePost(context, meta.copy(options = StoreResolver.capped(meta.options, null, null)))
            return
        }

        // Single fresh fix, bounded to fit inside the broadcast window.
        // BALANCED (wifi/cell) first: indoors GPS is weakest, and ~30 m is
        // plenty to verify against a 100 m fence. The second look (taken only
        // after a coarse or moving first one) asks for HIGH_ACCURACY, which
        // blends GPS with wifi: a few seconds of GPS, a handful of times a day,
        // to tell stores 25 m apart.
        val pending = goAsync()
        val cts = CancellationTokenSource()
        val handler = Handler(Looper.getMainLooper())
        var finished = false
        fun finishOnce(block: () -> Unit) {
            if (finished) return
            finished = true
            try {
                block()
            } finally {
                pending.finish()
            }
        }
        handler.postDelayed({
            cts.cancel()
            finishOnce { verdictWithoutFix(context, meta) }
        }, FIX_TIMEOUT_MS)

        try {
            val client = LocationServices.getFusedLocationProviderClient(context)
            val request = CurrentLocationRequest.Builder()
                .setPriority(
                    if (recheck) Priority.PRIORITY_HIGH_ACCURACY else Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                )
                .setDurationMillis(FIX_TIMEOUT_MS)
                .build()
            client.getCurrentLocation(request, cts.token)
                .addOnSuccessListener { fix ->
                    finishOnce {
                        if (fix == null) {
                            verdictWithoutFix(context, meta)
                        } else {
                            verdictWithFix(context, meta, fix, recheck)
                        }
                    }
                }
                .addOnFailureListener {
                    finishOnce { verdictWithoutFix(context, meta) }
                }
        } catch (e: SecurityException) {
            finishOnce { verdictWithoutFix(context, meta) }
        }
    }

    private fun verdictWithFix(context: Context, meta: MerchantMeta, fix: Location, recheck: Boolean) {
        val dist = FloatArray(1)
        Location.distanceBetween(fix.latitude, fix.longitude, meta.lat!!, meta.lng!!, dist)
        val allowed = meta.radiusM!! + fix.accuracy + SLACK_M
        val measured = DwellFix(dist[0], fix.accuracy, allowed)
        if (dist[0] > allowed) {
            done(context, meta, DwellOutcome.OUTSIDE_FENCE, measured)
            return
        }
        // Inside, but a car at a red light is inside too, and so is someone
        // walking past (a 1-min wait is shorter than walking through a 100 m
        // fence). Look once more after another dwell period instead of
        // skipping: activity state can lag, and the second look trusts the fix
        // alone. An EXIT in between cancels the recheck. A coarse fix gets the
        // same second look: the next one is usually 10x sharper indoors.
        if (!recheck) {
            val again = when {
                ActivityState.isLikelyDriving(context) ||
                    ActivityState.isLikelyWalking(context) ||
                    (fix.hasSpeed() && fix.speed > MOVING_SPEED_MPS) -> DwellOutcome.MOVING_RECHECK
                fix.accuracy > StoreResolver.MAX_ACCURACY_M -> DwellOutcome.COARSE_RECHECK
                else -> null
            }
            if (again != null) {
                DwellAlarms.arm(context, meta.geofenceId, meta.dwellSeconds, recheck = true)
                done(context, meta, again, measured)
                return
            }
        }
        val resolved = resolveAtFix(context, meta, fix, allowed.toDouble())
        if (resolved == null) {
            done(context, meta, DwellOutcome.NOT_AT_STORE, measured)
            return
        }
        val (found, byFix) = resolved
        maybePost(context, found, measured, fix.latitude, fix.longitude, byFix)
    }

    /// The store(s) to name, judged from the fix against every registered
    /// fence, within the same reach that just verified the visit. Falls back
    /// to the firing fence's own options (capped, closest first) when the fix
    /// is too coarse to order stores or no store with a known position is in
    /// reach (fences from older builds carry none). Muted stores are dropped
    /// first, so a muted store next door can't silence the one the user is in.
    /// Null when the closest store is too far for the user to be inside it.
    /// The flag says the fix named the store(s), rather than the fallback.
    private fun resolveAtFix(
        context: Context,
        meta: MerchantMeta,
        fix: Location,
        reach: Double,
    ): Pair<MerchantMeta, Boolean>? {
        val fallback = meta.copy(options = StoreResolver.capped(meta.options, fix.latitude, fix.longitude)) to false
        if (fix.accuracy > StoreResolver.MAX_ACCURACY_M) {
            WalkinLog.w(context, "dwell ${meta.geofenceId}: fix acc=${fix.accuracy.toInt()} too coarse -> fence options")
            return fallback
        }
        val muted = MutedStore(context)
        val candidates = StoreResolver.candidates(
            GeofenceMetadataStore(context).readAll().flatMap { it.options },
            fix.latitude,
            fix.longitude,
            reach,
        ).filterNot { muted.isMuted(it.option.merchantId) }
        val picked = StoreResolver.resolve(candidates)
        WalkinLog.w(
            context,
            "dwell ${meta.geofenceId}: fix acc=${fix.accuracy.toInt()} candidates=" +
                candidates.sortedBy { it.distanceM }.take(6)
                    .joinToString(",") { "${it.option.name}@${it.distanceM.toInt()}m" } +
                " -> ${if (picked.isEmpty()) "fence options" else picked.joinToString("|") { it.name }}",
        )
        if (picked.isEmpty()) return fallback
        val nearest = candidates.minOf { it.distanceM }
        return if (StoreResolver.atStore(nearest, fix.accuracy.toDouble())) meta.copy(options = picked) to true else null
    }

    private fun verdictWithoutFix(context: Context, meta: MerchantMeta) {
        // Fail-open EXCEPT while driving: a missed fix + IN_VEHICLE is almost
        // always a red-light / drive-by false ENTER, so skip (fail-closed)
        // there. Known edge: activity recognition can lag the actual park by up
        // to its ~30-min staleness window (see ActivityState.isLikelyDriving).
        // If a dwell timer fires inside that gap — user has parked, but the last
        // AR reading is still a recent IN_VEHICLE — this skips one otherwise-
        // legit notification. Accepted: eating a rare single dwell beats posting
        // a drive-by at every red light. Cooldowns aren't marked on a skip, so
        // the next genuine dwell at this merchant still fires normally.
        if (ActivityState.isLikelyDriving(context)) {
            done(context, meta, DwellOutcome.NO_FIX_DRIVING)
            return
        }
        WalkinLog.w(context, "dwell ${meta.geofenceId}: no fix, not driving -> fence options")
        maybePost(context, meta.copy(options = StoreResolver.capped(meta.options, meta.lat, meta.lng)))
    }

    /// [fix] is null on the no-fix path, so a `posted` line with no distance is
    /// itself the signal that verification failed open.
    private fun maybePost(
        context: Context,
        found: MerchantMeta,
        fix: DwellFix? = null,
        atLat: Double? = null,
        atLng: Double? = null,
        byFix: Boolean = false,
    ) {
        val (ordered, usualFirst) = StoreResolver.preferPicked(
            found.options,
            PickStore(context).picks(found.options.map { it.merchantId }),
        )
        val meta = found.copy(options = ordered, usualFirst = usualFirst)
        val cooldown = CooldownStore(context)
        val now = System.currentTimeMillis()
        val primary = meta.primary
        // Belt-and-braces mute check: Dart drops muted stores at re-register
        // time, but a fence registered *before* the mute is still in flight.
        // A cluster ("you may be at one of these") is only suppressed when
        // every option is muted — one live option still earns a post.
        val muted = MutedStore(context)
        val suppressed = if (meta.isCluster) {
            meta.options.all { muted.isMuted(it.merchantId) }
        } else {
            muted.isMuted(primary.merchantId)
        }
        if (suppressed) {
            done(context, meta, DwellOutcome.MUTED, fix)
            return
        }
        // Where the user is: the fix when there is one, else the fence centre.
        val visitLat = atLat ?: meta.lat
        val visitLng = atLng ?: meta.lng
        val lastVisit = VisitLock.read(context)
        val resolved = if (byFix) meta.options else null
        if (visitLat != null && visitLng != null &&
            VisitLock.isSameVisit(lastVisit, visitLat, visitLng, now, resolved)
        ) {
            // Still here: the window restarts, so it lasts as long as the stay.
            VisitLock.write(context, lastVisit!!.copy(atMillis = now))
            done(context, meta, DwellOutcome.SAME_VISIT, fix)
            return
        }
        val lastMerchant = cooldown.lastMerchantNotified(primary.merchantId)
        if (lastMerchant != null && now - lastMerchant < MERCHANT_COOLDOWN_MS) {
            done(context, meta, DwellOutcome.MERCHANT_COOLDOWN, fix)
            return
        }
        if (!NotificationHelper(context).postDwell(meta)) {
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
        done(context, meta, DwellOutcome.POSTED, fix)
    }

    /// Every exit of the dwell check ends here: one log line (release builds
    /// too).
    private fun done(context: Context, meta: MerchantMeta, outcome: DwellOutcome, fix: DwellFix? = null) {
        WalkinLog.w(
            context,
            "dwell ${meta.geofenceId}: ${outcome.wire} " +
                meta.options.joinToString("|") { it.name } +
                (fix?.let { " dist=${it.distanceM.toInt()}m acc=${it.accuracyM.toInt()}m" } ?: ""),
        )
    }

    companion object {
        private const val FIX_TIMEOUT_MS = 8_000L
        private const val SLACK_M = 50f
        // Per-merchant: same Kohl's stays quiet for 6h after firing.
        private const val MERCHANT_COOLDOWN_MS = 6L * 60L * 60L * 1000L
        // Faster than a brisk walk (~1.5 m/s).
        private const val MOVING_SPEED_MPS = 2f
    }
}
