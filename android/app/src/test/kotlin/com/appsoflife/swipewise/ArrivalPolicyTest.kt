package com.appsoflife.swipewise

import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.DetectedActivity
import org.junit.Assert.assertEquals
import org.junit.Test

class ArrivalPolicyTest {

    private val fence = FenceGeometry(lat = 40.5014, lng = -74.8549, radiusM = 100f)
    private val baseNanos = 1_000_000_000_000L

    private fun fix(
        lat: Double = 40.5014,
        lng: Double = -74.8549,
        acc: Float = 15f,
        elapsedNanos: Long = baseNanos,
        speedMps: Float? = null,
        hasAccuracy: Boolean = true,
    ) = FixObservation(
        lat = lat,
        lng = lng,
        accuracyM = acc,
        elapsedRealtimeNanos = elapsedNanos,
        speedMps = speedMps,
        hasAccuracy = hasAccuracy,
    )

    private fun activity(
        type: Int = DetectedActivity.STILL,
        transition: Int = ActivityTransition.ACTIVITY_TRANSITION_ENTER,
        elapsedNanos: Long = baseNanos,
    ) = ActivityObservation(
        type = type,
        transitionType = transition,
        elapsedRealtimeNanos = elapsedNanos,
    )

    @Test
    fun `missing metadata geometry fails closed with NO_META`() {
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(),
            priorFix = null,
            fence = null,
            activity = null,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.NO_META, decision.outcome)
    }

    @Test
    fun `invalid fix parameters fail closed with INVALID_FIX`() {
        // Missing accuracy
        val noAcc = fix(hasAccuracy = false)
        assertEquals(ArrivalVerdict.REJECT, ArrivalPolicy.evaluate(noAcc, null, fence, null, false, false, baseNanos).verdict)
        assertEquals(DwellOutcome.INVALID_FIX, ArrivalPolicy.evaluate(noAcc, null, fence, null, false, false, baseNanos).outcome)

        // NaN coordinates
        val nanCoord = fix(lat = Double.NaN)
        assertEquals(ArrivalVerdict.REJECT, ArrivalPolicy.evaluate(nanCoord, null, fence, null, false, false, baseNanos).verdict)
        assertEquals(DwellOutcome.INVALID_FIX, ArrivalPolicy.evaluate(nanCoord, null, fence, null, false, false, baseNanos).outcome)

        // Negative accuracy
        val negAcc = fix(acc = -5f)
        assertEquals(ArrivalVerdict.REJECT, ArrivalPolicy.evaluate(negAcc, null, fence, null, false, false, baseNanos).verdict)

        // Negative speed
        val negSpeed = fix(speedMps = -1.5f)
        assertEquals(ArrivalVerdict.REJECT, ArrivalPolicy.evaluate(negSpeed, null, fence, null, false, false, baseNanos).verdict)

        // Zero or negative elapsed nanos
        val zeroElapsed = fix(elapsedNanos = 0L)
        assertEquals(ArrivalVerdict.REJECT, ArrivalPolicy.evaluate(zeroElapsed, null, fence, null, false, false, baseNanos).verdict)
    }

    @Test
    fun `stale fix older than 15 seconds fails closed with STALE_FIX`() {
        val staleAgeNanos = 16_000L * 1_000_000L
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(elapsedNanos = baseNanos - staleAgeNanos),
            priorFix = null,
            fence = fence,
            activity = null,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.STALE_FIX, decision.outcome)
    }

    @Test
    fun `future fix fails closed with STALE_FIX`() {
        val futureNanos = baseNanos + 2_000_000_000L // 2 seconds ahead
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(elapsedNanos = futureNanos),
            priorFix = null,
            fence = fence,
            activity = null,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.STALE_FIX, decision.outcome)
    }

    @Test
    fun `coarse fix on initial check rechecks once`() {
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(acc = 55f),
            priorFix = null,
            fence = fence,
            activity = null,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.RECHECK, decision.verdict)
        assertEquals(DwellOutcome.COARSE_RECHECK, decision.outcome)
    }

    @Test
    fun `coarse fix on recheck rejects and does not notify`() {
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(acc = 55f),
            priorFix = fix(acc = 60f, elapsedNanos = baseNanos - 60_000_000_000L),
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.COARSE_RECHECK, decision.outcome)
    }

    @Test
    fun `coarse but under ceiling coordinates do not prove stability without AR`() {
        // Two 45m accuracy fixes at identical coordinates (ceiling is 50m, but stability needs <= 25m each)
        val prior = fix(lat = 40.5014, lng = -74.8549, acc = 45f, elapsedNanos = baseNanos - 60_000_000_000L)
        val current = fix(lat = 40.5014, lng = -74.8549, acc = 45f, elapsedNanos = baseNanos)

        val decision = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = prior,
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        // Two coarse fixes overlapping in uncertainty do NOT prove stability; rejected on recheck
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, decision.outcome)
    }

    @Test
    fun `precise stationary pair proves independent stability without AR`() {
        // Two sharp fixes (12m and 14m <= 25m) with 5m displacement over 60s
        val prior = fix(lat = 40.50140, lng = -74.85490, acc = 12f, elapsedNanos = baseNanos - 60_000_000_000L)
        val current = fix(lat = 40.50143, lng = -74.85492, acc = 14f, elapsedNanos = baseNanos, speedMps = 0.1f)

        val decision = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = prior,
            fence = fence,
            activity = null,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.VERIFIED, decision.verdict)
        assertEquals(DwellOutcome.POSTED, decision.outcome)
    }

    @Test
    fun `two 20m fixes over short 10s interval fail uncertainty rate`() {
        // (0 + 20 + 20)/10 = 4.0 m/s > 0.6 m/s uncertainty rate ceiling
        val prior = fix(lat = 40.50140, lng = -74.85490, acc = 20f, elapsedNanos = baseNanos - 10_000_000_000L)
        val current = fix(lat = 40.50140, lng = -74.85490, acc = 20f, elapsedNanos = baseNanos)

        val decision = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = prior,
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        // Over short interval of 10s, 20m uncertainty is too large to prove stationarity
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, decision.outcome)
    }

    @Test
    fun `invalid fence geometry fails closed with NO_META`() {
        val nanFence = FenceGeometry(lat = Double.NaN, lng = -74.8549, radiusM = 100f)
        assertEquals(ArrivalVerdict.REJECT, ArrivalPolicy.evaluate(fix(), null, nanFence, null, false, false, baseNanos).verdict)
        assertEquals(DwellOutcome.NO_META, ArrivalPolicy.evaluate(fix(), null, nanFence, null, false, false, baseNanos).outcome)

        val negRadius = FenceGeometry(lat = 40.5014, lng = -74.8549, radiusM = -50f)
        assertEquals(ArrivalVerdict.REJECT, ArrivalPolicy.evaluate(fix(), null, negRadius, null, false, false, baseNanos).verdict)
    }

    @Test
    fun `invalid prior fix is ignored for stability proof`() {
        val invalidPrior = fix(acc = -10f, elapsedNanos = baseNanos - 60_000_000_000L)
        val current = fix(acc = 12f, elapsedNanos = baseNanos)

        val decision = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = invalidPrior,
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        // Cannot use invalid prior fix; stability unproven on recheck -> reject
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
    }

    @Test
    fun `too-old baseline does not prove uninterrupted stationarity`() {
        // Prior fix 15 minutes ago (900s > 150s max baseline)
        val prior = fix(lat = 40.50140, lng = -74.85490, acc = 10f, elapsedNanos = baseNanos - 900_000_000_000L)
        val current = fix(lat = 40.50140, lng = -74.85490, acc = 10f, elapsedNanos = baseNanos)

        val decision = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = prior,
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        // Cannot prove uninterrupted stationarity across 15 min without intervening evidence
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
    }

    @Test
    fun `stable coordinates with walking sensor speed fails`() {
        // Stable coordinates across 60s, but sensor speed is 1.4 m/s (walking pace)
        val prior = fix(lat = 40.50140, lng = -74.85490, acc = 10f, elapsedNanos = baseNanos - 60_000_000_000L)
        val current = fix(lat = 40.50140, lng = -74.85490, acc = 10f, elapsedNanos = baseNanos, speedMps = 1.4f)

        val decision = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = prior,
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, decision.outcome)
    }

    @Test
    fun `fix outside fence containment rejects with OUTSIDE_FENCE`() {
        val outsideLat = 40.5045
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(lat = outsideLat, acc = 15f),
            priorFix = null,
            fence = fence,
            activity = null,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, decision.verdict)
        assertEquals(DwellOutcome.OUTSIDE_FENCE, decision.outcome)
    }

    @Test
    fun `high speed on fix is moving and rejected on recheck`() {
        val movingFix = fix(speedMps = 1.5f)
        val initial = ArrivalPolicy.evaluate(
            currentFix = movingFix,
            priorFix = null,
            fence = fence,
            activity = null,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.RECHECK, initial.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, initial.outcome)

        val recheck = ArrivalPolicy.evaluate(
            currentFix = movingFix,
            priorFix = fix(elapsedNanos = baseNanos - 60_000_000_000L),
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, recheck.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, recheck.outcome)
    }

    @Test
    fun `fresh walking AR is moving and rejected on recheck`() {
        val walkingAR = activity(type = DetectedActivity.WALKING, elapsedNanos = baseNanos - 10_000_000_000L)
        val initial = ArrivalPolicy.evaluate(
            currentFix = fix(),
            priorFix = null,
            fence = fence,
            activity = walkingAR,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.RECHECK, initial.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, initial.outcome)

        val recheck = ArrivalPolicy.evaluate(
            currentFix = fix(),
            priorFix = fix(elapsedNanos = baseNanos - 60_000_000_000L),
            fence = fence,
            activity = walkingAR,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, recheck.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, recheck.outcome)
    }

    @Test
    fun `same cached timestamp returned twice is not independent evidence`() {
        val sameTimestamp = baseNanos - 5_000_000_000L
        val prior = fix(elapsedNanos = sameTimestamp)
        val current = fix(elapsedNanos = sameTimestamp)

        val recheck = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = prior,
            fence = fence,
            activity = null,
            isRecheck = true,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.REJECT, recheck.verdict)
        assertEquals(DwellOutcome.MOVING_RECHECK, recheck.outcome)
    }

    @Test
    fun `valid arrival with fresh STILL AR is verified`() {
        val stillAR = activity(type = DetectedActivity.STILL, elapsedNanos = baseNanos - 30_000_000_000L)
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(acc = 15f),
            priorFix = null,
            fence = fence,
            activity = stillAR,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.VERIFIED, decision.verdict)
        assertEquals(DwellOutcome.POSTED, decision.outcome)
    }

    @Test
    fun `stale driving AR is superseded by two independently timed stable fixes`() {
        val staleDriveAR = activity(
            type = DetectedActivity.IN_VEHICLE,
            elapsedNanos = baseNanos - 40L * 60L * 1_000_000_000L,
        )
        val prior = fix(lat = 40.50140, lng = -74.85490, acc = 12f, elapsedNanos = baseNanos - 60_000_000_000L)
        val current = fix(lat = 40.50143, lng = -74.85492, acc = 14f, elapsedNanos = baseNanos, speedMps = 0.0f)

        val decision = ArrivalPolicy.evaluate(
            currentFix = current,
            priorFix = prior,
            fence = fence,
            activity = staleDriveAR,
            isRecheck = false,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.VERIFIED, decision.verdict)
        assertEquals(DwellOutcome.POSTED, decision.outcome)
    }

    @Test
    fun `next-door check verifies arrival even if outside original firing fence`() {
        val stillAR = activity(type = DetectedActivity.STILL, elapsedNanos = baseNanos - 30_000_000_000L)
        val decision = ArrivalPolicy.evaluate(
            currentFix = fix(lat = 40.5030, acc = 15f),
            priorFix = null,
            fence = fence,
            activity = stillAR,
            isRecheck = false,
            isNextDoor = true,
            nowElapsedNanos = baseNanos,
        )
        assertEquals(ArrivalVerdict.VERIFIED, decision.verdict)
        assertEquals(DwellOutcome.POSTED, decision.outcome)
    }
}
