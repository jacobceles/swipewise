package com.appsoflife.swipewise

import android.content.Context
import android.location.Location
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.android.gms.tasks.TaskCompletionSource
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
