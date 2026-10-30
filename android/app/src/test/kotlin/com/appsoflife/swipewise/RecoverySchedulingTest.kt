package com.appsoflife.swipewise

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RecoverySchedulingTest {
    private lateinit var context: Context
    private var enqueued = 0
    private val originalSubscription = ActivitySubscriber.requestUpdates
    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        SystemClock.sleep(1_000_000L)
        BootIdentity.testBootCount = 1
        context.getSharedPreferences("swipewise_reregister", Context.MODE_PRIVATE).edit().clear().commit()
        ActivityState.clear(context)
        ReregisterScheduler.enqueueOverride = { enqueued++ }
    }
    @After fun cleanup() {
        ReregisterScheduler.enqueueOverride = null
        ActivitySubscriber.requestUpdates = originalSubscription
        BootIdentity.testBootCount = null
    }
    @Test fun `remaining cooldown and repeated crossings preserve earliest deadline`() {
        FootReregister.mark(context, SystemClock.elapsedRealtime())
        SystemClock.sleep(299_000L)
        val now = SystemClock.elapsedRealtime()
        assertEquals(1000L, FootReregister.remaining(context, now))
        PendingReregister.request(context, FootReregister.remaining(context), "boundary")
        val deadline = PendingReregister.due(context)
        PendingReregister.request(context, FootReregister.COOLDOWN_MS, "boundary")
        assertEquals(now + 1000L, deadline)
        assertEquals(deadline, PendingReregister.due(context))
    }
    @Test fun `older registration cannot clear newer recovery generation`() {
        val old = PendingReregister.request(context, 1000L, "boundary")
        val newer = PendingReregister.request(context, 2000L, "coverage")
        assertFalse(PendingReregister.complete(context, old))
        assertTrue(PendingReregister.isPending(context))
        assertTrue(PendingReregister.complete(context, newer))
        assertFalse(PendingReregister.isPending(context))
    }
    @Test fun `due fallback enqueues without AR and remains owed until success`() {
        val generation = PendingReregister.request(context, 1000L, "coverage")
        ReregisterFallbackReceiver().onReceive(context, Intent())
        assertEquals(0, enqueued)
        SystemClock.sleep(1000L)
        ReregisterFallbackReceiver().onReceive(context, Intent())
        assertEquals(1, enqueued)
        assertTrue(PendingReregister.isPending(context))
        assertEquals(generation, PendingReregister.generation(context))
        assertTrue(PendingReregister.due(context) > SystemClock.elapsedRealtime())
    }
    @Test fun `OS recovery stays forced until its own successful registration`() {
        val old = PendingReregister.request(context, 0L, "boundary")
        val forced = PendingReregister.request(context, 0L, "os_recovery", force = true)
        assertFalse(PendingReregister.complete(context, old))
        assertTrue(PendingReregister.forceRecovery(context))
        assertTrue(PendingReregister.complete(context, forced))
        assertFalse(PendingReregister.forceRecovery(context))
    }
    @Test fun `activity subscription failure retries once rather than polling forever`() {
        org.robolectric.Shadows.shadowOf(context as android.app.Application)
            .grantPermissions("android.permission.ACTIVITY_RECOGNITION")
        var calls = 0
        ActivitySubscriber.requestUpdates = { _, _, _ ->
            calls++
            com.google.android.gms.tasks.Tasks.forException<Void>(IllegalStateException("Unavailable"))
        }
        ActivitySubscriber.start(context)
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
        assertEquals(1, calls)
        org.robolectric.shadows.ShadowLooper.idleMainLooper(5_001L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(2, calls)
        org.robolectric.shadows.ShadowLooper.idleMainLooper(20_000L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(2, calls)
    }

    @Test fun `denied activity permission never calls the SDK`() {
        org.robolectric.Shadows.shadowOf(context as android.app.Application)
            .denyPermissions("android.permission.ACTIVITY_RECOGNITION")
        var calls = 0
        ActivitySubscriber.requestUpdates = { _, _, _ ->
            calls++
            com.google.android.gms.tasks.Tasks.forResult<Void>(null)
        }
        ActivitySubscriber.start(context)
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
        assertEquals(0, calls)
    }

    @Test fun `permission revoked at the activity SDK call is caught without retrying`() {
        org.robolectric.Shadows.shadowOf(context as android.app.Application)
            .grantPermissions("android.permission.ACTIVITY_RECOGNITION")
        var calls = 0
        ActivitySubscriber.requestUpdates = { _, _, _ ->
            calls++
            throw SecurityException("Permission revoked")
        }
        ActivitySubscriber.start(context)
        org.robolectric.shadows.ShadowLooper.idleMainLooper(10_000L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(1, calls)
    }
}
