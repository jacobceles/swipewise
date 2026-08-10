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
///   - fix outside → skip (classic false ENTER: red light at a strip mall,
///     or the EXIT event was delivered too late to cancel the timer)
///   - no fix obtainable in time → post unless activity says IN_VEHICLE
///     (fail-open: a missed verification must not eat a legit notification)
///
/// Cooldowns (same tables/thresholds as always): 6h per merchant, 30min per
/// category.
class DwellCheckReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val geofenceId = DwellAlarms.geofenceIdFromIntent(intent) ?: return
        val meta = GeofenceMetadataStore(context).read(geofenceId)
        if (meta == null) {
            // Fence set was replaced while this timer was in flight.
            return
        }

        if (meta.lat == null || meta.lng == null || meta.radiusM == null) {
            // Meta written by an older build — can't geo-verify.
            maybePost(context, meta)
            return
        }

        // Single fresh fix, bounded to fit inside the broadcast window.
        // BALANCED (wifi/cell) beats HIGH_ACCURACY here: we're indoors where
        // GPS is weakest, and ~30m accuracy is plenty against a 100m fence.
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
                .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
                .setDurationMillis(FIX_TIMEOUT_MS)
                .build()
            client.getCurrentLocation(request, cts.token)
                .addOnSuccessListener { fix ->
                    finishOnce {
                        if (fix == null) {
                            verdictWithoutFix(context, meta)
                        } else {
                            verdictWithFix(context, meta, fix)
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

    private fun verdictWithFix(context: Context, meta: MerchantMeta, fix: Location) {
        val dist = FloatArray(1)
        Location.distanceBetween(fix.latitude, fix.longitude, meta.lat!!, meta.lng!!, dist)
        val allowed = meta.radiusM!! + fix.accuracy + SLACK_M
        if (dist[0] <= allowed) {
            maybePost(context, meta)
        }
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
            return
        }
        maybePost(context, meta)
    }

    private fun maybePost(context: Context, meta: MerchantMeta) {
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
            return
        }
        val lastMerchant = cooldown.lastMerchantNotified(primary.merchantId)
        if (lastMerchant != null && now - lastMerchant < MERCHANT_COOLDOWN_MS) {
            return
        }
        // Composite "<category>@<areaBucket>" key so the 30-min category
        // cooldown only suppresses repeats in roughly the SAME area — the
        // same category across town (a different areaBucket) still posts.
        // areaBucket falls back to the bare category when the fence has no
        // lat/lng (meta written by an older build).
        val categoryKey = compositeCategoryKey(primary.category, meta.lat, meta.lng)
        val lastCategory = cooldown.lastCategoryNotified(categoryKey)
        if (lastCategory != null && now - lastCategory < CATEGORY_COOLDOWN_MS) {
            return
        }
        NotificationHelper(context).postDwell(meta)
        val notifyOption = if (categoryKey != primary.category) {
            primary.copy(category = categoryKey)
        } else {
            primary
        }
        cooldown.markNotified(notifyOption, now)
    }

    /// "<category>@<lat>,<lng>" with lat/lng rounded to 2 decimal degrees
    /// (~1.1km per degree of latitude, so 0.01 degree ≈ 1.1km) — a coarse
    /// grid bucket, not a precise distance check. Points within the same
    /// cell cooldown together; points across a cell edge don't, even if
    /// they're a few hundred meters apart. That's an accepted approximation
    /// for "same area" vs. "across town".
    private fun compositeCategoryKey(category: String?, lat: Double?, lng: Double?): String? {
        if (category.isNullOrEmpty()) return category
        if (lat == null || lng == null) return category
        val latBucket = Math.round(lat * 100.0) / 100.0
        val lngBucket = Math.round(lng * 100.0) / 100.0
        return "$category@$latBucket,$lngBucket"
    }

    companion object {
        private const val FIX_TIMEOUT_MS = 8_000L
        private const val SLACK_M = 50f
        // Per-merchant: same Kohl's stays quiet for 6h after firing.
        private const val MERCHANT_COOLDOWN_MS = 6L * 60L * 60L * 1000L
        // Per-category: walking through a strip mall full of retailers gets
        // one notification, not five. 30 min is short enough that the next
        // real shopping trip still triggers.
        private const val CATEGORY_COOLDOWN_MS = 30L * 60L * 1000L
    }
}
