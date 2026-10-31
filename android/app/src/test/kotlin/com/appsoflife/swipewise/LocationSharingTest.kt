package com.appsoflife.swipewise

import android.content.Context
import android.location.Location
import android.os.SystemClock
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.android.gms.tasks.TaskCompletionSource
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LocationSharingTest {
    @Before fun advanceClock() { SystemClock.sleep(120_000L) }

    private fun fix(ageMillis: Long = 0L) = Location("test").apply {
        elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos() - ageMillis * 1_000_000L
    }

    @Test fun `stale SDK fix gets one shared fresh retry within remaining budget`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        val initial = TaskCompletionSource<Location>()
        val retry = TaskCompletionSource<Location>()
        val requests = mutableListOf<CurrentLocationRequest>()
        val a = CancellationTokenSource()
        val b = CancellationTokenSource()
        val replies = mutableListOf<Location?>()
        DefaultLocationProvider.requestLocation = { _, request, _ ->
            requests.add(request)
            if (requests.size == 1) initial.task else retry.task
        }
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, a.token, { replies.add(it) }, { throw it })
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, b.token, { replies.add(it) }, { throw it })
            SystemClock.sleep(2000L)
            initial.setResult(fix(60_000L))
            ShadowLooper.idleMainLooper()
            assertEquals(2, requests.size)
            assertTrue(replies.isEmpty())
            assertEquals(100, requests[1].priority)
            assertEquals(0L, requests[1].maxUpdateAgeMillis)
            assertTrue(requests[1].durationMillis in 1L..6000L)
            val fresh = fix()
            retry.setResult(fresh)
            ShadowLooper.idleMainLooper()
            assertEquals(listOf(fresh, fresh), replies)
        } finally {
            a.cancel(); b.cancel()
            DefaultLocationProvider.requestLocation = original
            ShadowLooper.idleMainLooper()
        }
    }

    @Test fun `a stale retry result is returned for policy rejection without a third request`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        val initial = TaskCompletionSource<Location>()
        val retry = TaskCompletionSource<Location>()
        val cancellation = CancellationTokenSource()
        var requests = 0
        var reply: Location? = null
        DefaultLocationProvider.requestLocation = { _, _, _ ->
            requests++
            if (requests == 1) initial.task else retry.task
        }
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, cancellation.token, { reply = it }, { throw it })
            initial.setResult(fix(60_000L))
            ShadowLooper.idleMainLooper()
            assertEquals(2, requests)
            val stillStale = fix(60_000L)
            retry.setResult(stillStale)
            ShadowLooper.idleMainLooper()
            assertSame(stillStale, reply)
            assertEquals(2, requests)
        } finally {
            cancellation.cancel()
            DefaultLocationProvider.requestLocation = original
            ShadowLooper.idleMainLooper()
        }
    }

    @Test fun `a late stale SDK result cannot extend the request budget`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        val initial = TaskCompletionSource<Location>()
        val cancellation = CancellationTokenSource()
        var requests = 0
        DefaultLocationProvider.requestLocation = { _, _, _ -> requests++; initial.task }
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, cancellation.token, {}, { throw it })
            SystemClock.sleep(8000L)
            initial.setResult(fix(60_000L))
            ShadowLooper.idleMainLooper()
            assertEquals(1, requests)
        } finally {
            cancellation.cancel()
            DefaultLocationProvider.requestLocation = original
            ShadowLooper.idleMainLooper()
        }
    }

    @Test fun `cancelling all consumers prevents a fresh retry from a late SDK callback`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        val initial = TaskCompletionSource<Location>()
        val cancellation = CancellationTokenSource()
        var requests = 0
        var replies = 0
        DefaultLocationProvider.requestLocation = { _, _, _ -> requests++; initial.task }
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, cancellation.token, { replies++ }, { throw it })
            cancellation.cancel()
            ShadowLooper.idleMainLooper()
            initial.setResult(fix(60_000L))
            ShadowLooper.idleMainLooper()
            assertEquals(1, requests)
            assertEquals(0, replies)
        } finally {
            cancellation.cancel()
            DefaultLocationProvider.requestLocation = original
            ShadowLooper.idleMainLooper()
        }
    }

    @Test fun `cancellation during fresh retry cancels upstream and suppresses delivery`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        val initial = TaskCompletionSource<Location>()
        val retry = TaskCompletionSource<Location>()
        val cancellation = CancellationTokenSource()
        var upstream: com.google.android.gms.tasks.CancellationToken? = null
        var requests = 0
        var replies = 0
        DefaultLocationProvider.requestLocation = { _, _, token ->
            upstream = token
            requests++
            if (requests == 1) initial.task else retry.task
        }
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, cancellation.token, { replies++ }, { throw it })
            initial.setResult(fix(60_000L))
            ShadowLooper.idleMainLooper()
            assertEquals(2, requests)
            cancellation.cancel()
            ShadowLooper.idleMainLooper()
            assertTrue(upstream!!.isCancellationRequested)
            retry.setResult(fix())
            ShadowLooper.idleMainLooper()
            assertEquals(0, replies)
        } finally {
            cancellation.cancel()
            DefaultLocationProvider.requestLocation = original
            ShadowLooper.idleMainLooper()
        }
    }

    @Test fun `synchronous fresh retry error reaches failure callback`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        val initial = TaskCompletionSource<Location>()
        val cancellation = CancellationTokenSource()
        val error = SecurityException("permission revoked")
        var requests = 0
        var failure: Exception? = null
        DefaultLocationProvider.requestLocation = { _, _, _ ->
            requests++
            if (requests == 1) initial.task else throw error
        }
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, cancellation.token, { fail("Unexpected success") }, { failure = it })
            initial.setResult(fix(60_000L))
            ShadowLooper.idleMainLooper()
            assertEquals(2, requests)
            assertSame(error, failure)
        } finally {
            cancellation.cancel()
            DefaultLocationProvider.requestLocation = original
            ShadowLooper.idleMainLooper()
        }
    }

    @Test fun `overlapping requests share a fix without one cancellation affecting another`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        val result = TaskCompletionSource<Location>()
        var requests = 0
        var upstream: com.google.android.gms.tasks.CancellationToken? = null
        DefaultLocationProvider.requestLocation = { _, _, token -> requests++; upstream = token; result.task }
        val a = CancellationTokenSource()
        val b = CancellationTokenSource()
        var repliesA = 0
        var repliesB = 0
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, a.token, { repliesA++ }, { throw it })
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, b.token, { repliesB++ }, { throw it })
            assertEquals(1, requests)
            a.cancel()
            ShadowLooper.idleMainLooper()
            assertFalse(upstream!!.isCancellationRequested)
            result.setResult(Location("test"))
            ShadowLooper.idleMainLooper()
            assertEquals(0, repliesA)
            assertEquals(1, repliesB)
        } finally {
            a.cancel(); b.cancel()
            DefaultLocationProvider.requestLocation = original
        }
    }

    @Test fun `last cancellation releases upstream request and a later request is fresh`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val original = DefaultLocationProvider.requestLocation
        var requests = 0
        val tokens = mutableListOf<com.google.android.gms.tasks.CancellationToken>()
        DefaultLocationProvider.requestLocation = { _, _, token ->
            requests++; tokens.add(token); TaskCompletionSource<Location>(token).task
        }
        val a = CancellationTokenSource()
        val b = CancellationTokenSource()
        try {
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, a.token, {}, { throw it })
            a.cancel()
            ShadowLooper.idleMainLooper()
            assertTrue(tokens.first().isCancellationRequested)
            DefaultLocationProvider.getCurrentLocation(context, 102, 8000, 15000, b.token, {}, { throw it })
            assertEquals(2, requests)
        } finally {
            a.cancel(); b.cancel()
            DefaultLocationProvider.requestLocation = original
            ShadowLooper.idleMainLooper()
        }
    }
}
