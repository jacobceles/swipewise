package com.appsoflife.swipewise

import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.DetectedActivity

data class FixObservation(
    val lat: Double,
    val lng: Double,
    val accuracyM: Float,
    val elapsedRealtimeNanos: Long,
    val speedMps: Float? = null,
    val hasAccuracy: Boolean = true,
)

data class FenceGeometry(
    val lat: Double,
    val lng: Double,
    val radiusM: Float,
)

data class ActivityObservation(
    val type: Int,
    val transitionType: Int,
    val elapsedRealtimeNanos: Long,
)

enum class ArrivalVerdict {
    VERIFIED,
    RECHECK,
    REJECT,
}

data class ArrivalDecision(
    val verdict: ArrivalVerdict,
    val outcome: DwellOutcome,
    val distanceM: Float,
    val allowedM: Float,
    val reason: String,
)

object ArrivalPolicy {
    const val MAX_ACCURACY_M = 50.0f
    const val MAX_STABLE_FIX_ACCURACY_M = 25.0f
    const val MAX_COMBINED_STABILITY_UNCERTAINTY_M = 40.0f
    const val MAX_STATIONARY_UNCERTAINTY_RATE_MPS = 0.6f // Heuristic (disp + acc1 + acc2)/dt <= 0.6 m/s
    const val MAX_FIX_AGE_NANOS = 15_000L * 1_000_000L // 15 seconds
    const val FUTURE_SLACK_NANOS = 1_000L * 1_000_000L // 1 second
    const val SLACK_M = 50.0f
    const val MOVING_SPEED_MPS = 1.0f // Walking pace cutoff (~1.0 - 1.2 m/s)
    const val STATIONARY_SPEED_CEILING_MPS = 0.5f
    const val MAX_STABLE_DISPLACEMENT_M = 20.0
    const val MAX_STABLE_IMPLIED_SPEED_MPS = 0.4f
    const val MIN_INDEPENDENT_INTERVAL_NANOS = 10_000L * 1_000_000L // 10 seconds
    const val MAX_BASELINE_INTERVAL_NANOS = 150_000L * 1_000_000L // 150 seconds baseline ceiling
    const val AR_STILL_WINDOW_NANOS = 15L * 60L * 1_000_000_000L // 15 minutes
    const val AR_MOTION_WINDOW_NANOS = 5L * 60L * 1_000_000_000L // 5 minutes
    const val AR_DRIVE_LONG_WINDOW_NANOS = 2L * 3600L * 1_000_000_000L // 2 hours

    private fun isInvalidFix(fix: FixObservation): Boolean =
        fix.lat.isNaN() || fix.lng.isNaN() || !fix.lat.isFinite() || !fix.lng.isFinite() ||
            fix.lat < -90.0 || fix.lat > 90.0 || fix.lng < -180.0 || fix.lng > 180.0 ||
            !fix.hasAccuracy || fix.accuracyM.isNaN() || fix.accuracyM <= 0f || !fix.accuracyM.isFinite() ||
            (fix.speedMps != null && (fix.speedMps.isNaN() || fix.speedMps < 0f || !fix.speedMps.isFinite())) ||
            fix.elapsedRealtimeNanos <= 0L

    private fun isInvalidFence(fence: FenceGeometry): Boolean =
        fence.lat.isNaN() || fence.lng.isNaN() || !fence.lat.isFinite() || !fence.lng.isFinite() ||
            fence.lat < -90.0 || fence.lat > 90.0 || fence.lng < -180.0 || fence.lng > 180.0 ||
            fence.radiusM.isNaN() || !fence.radiusM.isFinite() || fence.radiusM <= 0f

    private fun decision(
        verdict: ArrivalVerdict,
        outcome: DwellOutcome,
        reason: String,
        dist: Float = 0f,
        allowed: Float = 0f,
    ) = ArrivalDecision(verdict, outcome, dist, allowed, reason)

    fun evaluate(
        currentFix: FixObservation,
        priorFix: FixObservation?,
        fence: FenceGeometry?,
        activity: ActivityObservation?,
        isRecheck: Boolean,
        isNextDoor: Boolean = false,
        nowElapsedNanos: Long,
    ): ArrivalDecision {
        if (fence == null || isInvalidFence(fence)) {
            return decision(ArrivalVerdict.REJECT, DwellOutcome.NO_META, "missing_or_invalid_fence_geometry")
        }

        if (isInvalidFix(currentFix)) {
            return decision(ArrivalVerdict.REJECT, DwellOutcome.INVALID_FIX, "invalid_current_fix")
        }

        val ageNanos = nowElapsedNanos - currentFix.elapsedRealtimeNanos
        if (ageNanos > MAX_FIX_AGE_NANOS || ageNanos < -FUTURE_SLACK_NANOS) {
            val reason = if (ageNanos > MAX_FIX_AGE_NANOS) "stale_fix_age_${ageNanos / 1_000_000}ms" else "future_fix"
            return decision(ArrivalVerdict.REJECT, DwellOutcome.STALE_FIX, reason)
        }

        if (currentFix.accuracyM > MAX_ACCURACY_M) {
            val (verdict, reason) = if (!isRecheck) ArrivalVerdict.RECHECK to "coarse_fix_initial"
            else ArrivalVerdict.REJECT to "coarse_fix_recheck_rejected"
            return decision(verdict, DwellOutcome.COARSE_RECHECK, reason)
        }

        val distance = distanceM(currentFix.lat, currentFix.lng, fence.lat, fence.lng).toFloat()
        val allowed = fence.radiusM + currentFix.accuracyM + SLACK_M

        if (!isNextDoor && distance > allowed) {
            return decision(ArrivalVerdict.REJECT, DwellOutcome.OUTSIDE_FENCE, "outside_fence", distance, allowed)
        }

        val hasDefiniteHighSpeed = currentFix.speedMps != null && currentFix.speedMps > MOVING_SPEED_MPS
        val isFreshWalking = activity != null &&
            activity.type == DetectedActivity.WALKING &&
            activity.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER &&
            (nowElapsedNanos - activity.elapsedRealtimeNanos) < AR_MOTION_WINDOW_NANOS
        val isFreshDriving = activity != null &&
            activity.type == DetectedActivity.IN_VEHICLE &&
            activity.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER &&
            (nowElapsedNanos - activity.elapsedRealtimeNanos) < AR_MOTION_WINDOW_NANOS

        var hasDisplacementMotion = false
        var isIndependentlyStable = false

        if (priorFix != null && !isInvalidFix(priorFix) && priorFix.elapsedRealtimeNanos != currentFix.elapsedRealtimeNanos) {
            val dtNanos = currentFix.elapsedRealtimeNanos - priorFix.elapsedRealtimeNanos
            if (dtNanos >= MIN_INDEPENDENT_INTERVAL_NANOS) {
                val dtSec = dtNanos / 1_000_000_000.0
                val disp = distanceM(priorFix.lat, priorFix.lng, currentFix.lat, currentFix.lng)
                val impliedSpeed = disp / dtSec
                val uncertaintyRate = (disp + priorFix.accuracyM + currentFix.accuracyM) / dtSec

                if (impliedSpeed > 1.0 || disp > 40.0) {
                    hasDisplacementMotion = true
                } else if (dtNanos <= MAX_BASELINE_INTERVAL_NANOS &&
                    priorFix.accuracyM <= MAX_STABLE_FIX_ACCURACY_M &&
                    currentFix.accuracyM <= MAX_STABLE_FIX_ACCURACY_M &&
                    (priorFix.accuracyM + currentFix.accuracyM) <= MAX_COMBINED_STABILITY_UNCERTAINTY_M &&
                    disp <= MAX_STABLE_DISPLACEMENT_M &&
                    impliedSpeed <= MAX_STABLE_IMPLIED_SPEED_MPS &&
                    uncertaintyRate <= MAX_STATIONARY_UNCERTAINTY_RATE_MPS &&
                    (currentFix.speedMps == null || currentFix.speedMps <= STATIONARY_SPEED_CEILING_MPS)
                ) {
                    isIndependentlyStable = true
                }
            }
        }

        val hasDefiniteMotion = hasDefiniteHighSpeed || isFreshWalking || isFreshDriving || hasDisplacementMotion

        if (hasDefiniteMotion) {
            val (verdict, reason) = if (!isRecheck) ArrivalVerdict.RECHECK to "definite_motion_initial"
            else ArrivalVerdict.REJECT to "definite_motion_recheck_rejected"
            return decision(verdict, DwellOutcome.MOVING_RECHECK, reason, distance, allowed)
        }

        val hasWalkingSpeed = currentFix.speedMps != null && currentFix.speedMps > STATIONARY_SPEED_CEILING_MPS

        val isRecentStill = activity != null &&
            activity.type == DetectedActivity.STILL &&
            activity.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER &&
            (nowElapsedNanos - activity.elapsedRealtimeNanos) < AR_STILL_WINDOW_NANOS &&
            !hasWalkingSpeed

        val isStaleDriving = activity != null &&
            activity.type == DetectedActivity.IN_VEHICLE &&
            activity.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER &&
            (nowElapsedNanos - activity.elapsedRealtimeNanos) < AR_DRIVE_LONG_WINDOW_NANOS

        if (isIndependentlyStable) {
            return decision(ArrivalVerdict.VERIFIED, DwellOutcome.POSTED, "verified_independently_stable", distance, allowed)
        }

        if (isStaleDriving) {
            val (verdict, reason) = if (!isRecheck) ArrivalVerdict.RECHECK to "stale_driving_recheck"
            else ArrivalVerdict.REJECT to "stale_driving_rejected"
            return decision(verdict, DwellOutcome.MOVING_RECHECK, reason, distance, allowed)
        }

        if (isRecentStill) {
            return decision(ArrivalVerdict.VERIFIED, DwellOutcome.POSTED, "verified_ar_still", distance, allowed)
        }

        val (verdict, reason) = if (!isRecheck) ArrivalVerdict.RECHECK to "awaiting_stability_recheck"
        else ArrivalVerdict.REJECT to "unresolved_stability_on_recheck"
        return decision(verdict, DwellOutcome.MOVING_RECHECK, reason, distance, allowed)
    }
}
