package com.appsoflife.swipewise

import android.app.Application
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.SystemClock
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.api.Api
import com.google.android.gms.common.api.internal.ApiKey
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.TaskCompletionSource
import com.google.android.gms.tasks.Tasks
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class GeofenceRegistrationRecoveryTest {
    private lateinit var context: Context
    private lateinit var client: FakeGeofencingClient
    private lateinit var plugin: GeofencePlugin
    private val dispatches = mutableListOf<Triple<String, ExistingWorkPolicy, OneTimeWorkRequest>>()
    private val originalDispatch = ReregisterScheduler.enqueueUniqueWork
    private val originalBootScheduler = BootReceiver.workScheduler
    private val originalEnqueue = ReregisterScheduler.enqueueOverride

    private val zone = mapOf<String, Any?>(
        "geofence_id" to "synthetic-merchant-fence",
        "lat" to 40.5, "lng" to -74.85, "radius_m" to 100.0, "dwell_seconds" to 60,
        "options" to listOf(mapOf(
            "merchant_id" to "synthetic-merchant", "name" to "Synthetic Cafe",
            "category" to "Dining", "best_card_name" to "Synthetic Card", "best_rate" to 3.0,
        )),
    )
    private val boundary = mapOf<String, Any?>(
        "geofence_id" to "synthetic-boundary", "lat" to 40.5, "lng" to -74.85, "radius_m" to 1000.0,
    )
    private val gid get() = zone["geofence_id"] as String

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        shadowOf(context as Application).denyPermissions("android.permission.ACTIVITY_RECOGNITION")
        SystemClock.sleep(1_000_000L)
        BootIdentity.testBootCount = 1
        for (name in listOf("swipewise_geofence_meta", "swipewise_reregister", "swipewise_dwell_attempts")) {
            context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        }
        GeofencePlugin.accountEpoch = 41L
        GeofencePlugin.currentAccountEpoch(context)
        ActivityState.clear(context)
        val dbPath = context.getDatabasePath("swipewise.db")
        dbPath.parentFile?.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(dbPath, null).use { db ->
            db.execSQL("CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY)")
            db.execSQL("DELETE FROM users")
            db.execSQL("INSERT INTO users VALUES ('synthetic-user')")
        }
        ReregisterScheduler.enqueueOverride = null
        ReregisterScheduler.enqueueUniqueWork = { _, name, policy, request ->
            dispatches.add(Triple(name, policy, request))
        }
        BootReceiver.workScheduler = DefaultBootWorkScheduler
        client = FakeGeofencingClient()
        recreateProcessState()
    }

    @After fun cleanup() {
        // Release held SDK tasks even when the regression assertion failed.
        ShadowLooper.idleMainLooper()
        client.completeAdds()
        ShadowLooper.idleMainLooper()
        DwellAlarms.clearAll(context)
        ReregisterScheduler.enqueueUniqueWork = originalDispatch
        ReregisterScheduler.enqueueOverride = originalEnqueue
        BootReceiver.workScheduler = originalBootScheduler
        BootIdentity.testBootCount = null
        clearHashCache()
        GeofencePlugin.accountEpoch = 0L
    }

    @Test fun `same payload after reboot must readd merchants and boundary and await GMS`() {
        registerInitialSet()
        simulateBoot()
        val generation = PendingReregister.generation(context)

        val result = register()
        ShadowLooper.idleMainLooper()

        assertEquals("Reboot erased OS fences; persisted metadata is not an add acknowledgement; channelCalls=${result.calls} value=${result.value}",
            setOf(gid, "synthetic-boundary"), client.addedIds())
        assertEquals("Boot recovery must not return a stored count before GMS accepts the fences", 0, result.calls)
        assertForcedPending(generation)
        client.adds.first().completion.setResult(null)
        ShadowLooper.idleMainLooper()
        assertEquals("Both GMS adds must finish before success", 0, result.calls)
        assertForcedPending(generation)
        client.completeAdds()
        ShadowLooper.idleMainLooper()
        assertEquals(1, result.value)
        assertEquals(setOf(gid, "synthetic-boundary"), client.activeIds())
        assertFalse(PendingReregister.isPending(context))
        assertFalse(PendingReregister.forceRecovery(context))
        assertEquals(generation, PendingReregister.generation(context))
    }

    @Test fun `boundary change after reboot cannot keep nonexistent merchant fences`() {
        registerInitialSet()
        simulateBoot()

        val result = register(boundary = boundary + ("radius_m" to 1200.0))
        ShadowLooper.idleMainLooper()

        assertTrue("keepMerchants is invalid after reboot even when only boundary geometry changed; added=${client.addedIds()}",
            gid in client.addedIds())
        assertEquals(0, result.calls)
        assertForcedPending(PendingReregister.generation(context))
        client.completeAdds()
        ShadowLooper.idleMainLooper()
        assertEquals(1, result.value)
        assertEquals(setOf(gid, "synthetic-boundary"), client.activeIds())
        assertFalse(PendingReregister.isPending(context))
        assertFalse(PendingReregister.forceRecovery(context))
    }

    @Test fun `same boot process recreation keeps OS fences metadata epoch and live dwell`() {
        registerInitialSet()
        val store = GeofenceMetadataStore(context)
        val generation = store.generation(gid)
        val attempt = DwellAlarms.arm(context, gid, 60)!!
        client.clearCalls()
        recreateProcessState()
        val refreshedZone = zone + ("options" to listOf(mapOf(
            "merchant_id" to "synthetic-merchant", "name" to "Refreshed Synthetic Cafe",
            "category" to "Dining", "best_card_name" to "New Synthetic Card", "best_rate" to 4.0,
        )))

        val result = register(zones = listOf(refreshedZone))
        ShadowLooper.idleMainLooper()

        assertEquals(1, result.value)
        assertTrue(client.adds.isEmpty())
        assertTrue(client.removals.isEmpty())
        assertEquals(setOf(gid, "synthetic-boundary"), client.activeIds())
        assertEquals(41L, GeofencePlugin.currentAccountEpoch(context))
        assertEquals(generation, store.generation(gid))
        assertEquals(attempt, DwellAlarms.getAttempt(context, gid))
        assertEquals("New Synthetic Card", store.read(gid)!!.primary.bestCardName)
    }

    @Test fun `same boot boundary update retains merchant fence and live dwell but awaits boundary add`() {
        registerInitialSet()
        val attempt = DwellAlarms.arm(context, gid, 60)!!
        client.clearCalls()
        recreateProcessState()

        val result = register(boundary = boundary + ("radius_m" to 1200.0))
        ShadowLooper.idleMainLooper()

        assertEquals(setOf("synthetic-boundary"), client.addedIds())
        assertEquals(listOf(BoundaryGeofenceReceiver.ACTION), client.removals.map { shadowOf(it).savedIntent.action })
        assertEquals(0, result.calls)
        assertTrue(gid in client.activeIds())
        client.completeAdds()
        ShadowLooper.idleMainLooper()
        assertEquals(1, result.value)
        assertEquals(attempt, DwellAlarms.getAttempt(context, gid))
    }

    @Test fun `forced recovery waits for add failure and keeps newer generation owed`() {
        registerInitialSet()
        simulateBoot()
        val generation = PendingReregister.generation(context)
        val result = register()
        ShadowLooper.idleMainLooper()
        assertEquals(0, result.calls)
        assertEquals(setOf(gid, "synthetic-boundary"), client.addedIds())
        assertForcedPending(generation)
        val newer = PendingReregister.request(context, 0L, "coverage")

        client.adds.first().completion.setException(IllegalStateException("synthetic GMS rejection"))
        client.completeAdds()
        ShadowLooper.idleMainLooper()

        assertTrue(newer > generation)
        assertEquals("ADD_FAILED", result.errorCode)
        assertEquals(1, result.calls)
        assertTrue(PendingReregister.isPending(context))
        assertTrue(PendingReregister.forceRecovery(context))
        assertEquals(newer, PendingReregister.generation(context))
        assertNull(GeofenceMetadataStore(context).readLastHash())
        assertNull(GeofenceMetadataStore(context).readLastMerchantHash())

        client.clearCalls()
        recreateProcessState()
        val retry = register()
        ShadowLooper.idleMainLooper()
        assertEquals(setOf(gid, "synthetic-boundary"), client.addedIds())
        assertEquals(0, retry.calls)
        assertForcedPending(newer)
        client.completeAdds()
        ShadowLooper.idleMainLooper()
        assertEquals(1, retry.value)
        assertFalse(PendingReregister.isPending(context))
        assertFalse(PendingReregister.forceRecovery(context))
        assertEquals(newer, PendingReregister.generation(context))
    }

    @Test fun `successful older boot registration cannot clear newer forced recovery`() {
        registerInitialSet()
        simulateBoot()
        val generation = PendingReregister.generation(context)
        val older = register()
        ShadowLooper.idleMainLooper()
        val newer = PendingReregister.request(context, 0L, "coverage")

        client.completeAdds()
        ShadowLooper.idleMainLooper()

        assertTrue(newer > generation)
        assertEquals(1, older.value)
        assertForcedPending(newer)
        client.clearCalls()
        val current = register()
        ShadowLooper.idleMainLooper()
        assertEquals(setOf(gid, "synthetic-boundary"), client.addedIds())
        assertEquals(0, current.calls)
        assertForcedPending(newer)
        client.completeAdds()
        ShadowLooper.idleMainLooper()
        assertEquals(1, current.value)
        assertFalse(PendingReregister.isPending(context))
        assertFalse(PendingReregister.forceRecovery(context))
    }

    @Test fun `boot persists immediate forced recovery before normal enqueue`() {
        registerInitialSet()
        val meta = GeofenceMetadataStore(context).read(gid)
        val generation = PendingReregister.generation(context)
        var scheduled = false
        BootReceiver.workScheduler = object : BootWorkScheduler {
            override fun scheduleBootReregister(context: Context) {
                assertTrue(PendingReregister.generation(context) > generation)
                assertForcedPending(PendingReregister.generation(context))
                assertTrue(PendingReregister.due(context) <= SystemClock.elapsedRealtime())
                assertEquals("boot", PendingReregister.reason(context))
                assertEquals(meta, GeofenceMetadataStore(context).read(gid))
                assertEquals(41L, GeofencePlugin.currentAccountEpoch(context))
                DefaultBootWorkScheduler.scheduleBootReregister(context)
                scheduled = true
            }
        }

        BootReceiver().onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))

        assertTrue(scheduled)
        assertEquals(1, dispatches.size)
    }

    @Test fun `recreated plugin rejects old account before metadata or GMS work`() {
        registerInitialSet()
        val meta = GeofenceMetadataStore(context).read(gid)
        val epoch = GeofencePlugin.incrementAccountEpoch(context)
        client.clearCalls()
        recreateProcessState()

        val result = register()

        assertEquals("STALE_ACCOUNT", result.errorCode)
        assertEquals(1, result.calls)
        assertTrue(client.adds.isEmpty())
        assertTrue(client.removals.isEmpty())
        assertEquals(meta, GeofenceMetadataStore(context).read(gid))
        assertEquals(epoch, GeofencePlugin.currentAccountEpoch(context))
    }

    @Test fun `boot and ordinary recovery keep unique connected expedited work contract`() {
        BootReceiver().onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))
        ReregisterScheduler.enqueue(context)
        ReregisterScheduler.enqueue(context)

        assertEquals(3, dispatches.size)
        for ((name, policy, request) in dispatches) {
            assertEquals(ReregisterScheduler.UNIQUE_WORK, name)
            assertEquals(ExistingWorkPolicy.KEEP, policy)
            assertEquals(ReregisterWorker::class.java.name, request.workSpec.workerClassName)
            assertEquals(NetworkType.CONNECTED, request.workSpec.constraints.requiredNetworkType)
            assertTrue(request.workSpec.expedited)
            assertEquals(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST, request.workSpec.outOfQuotaPolicy)
        }
        assertEquals(3, dispatches.map { it.third.id }.toSet().size)
    }

    private fun registerInitialSet() {
        val result = register()
        ShadowLooper.idleMainLooper()
        assertEquals(setOf(gid, "synthetic-boundary"), client.addedIds())
        assertEquals(0, result.calls)
        client.completeAdds()
        ShadowLooper.idleMainLooper()
        assertEquals(1, result.value)
        assertEquals(1, result.calls)
        assertNotNull(GeofenceMetadataStore(context).readLastHash())
        assertNotNull(GeofenceMetadataStore(context).readLastMerchantHash())
        assertFalse(PendingReregister.forceRecovery(context))
    }

    private fun simulateBoot() {
        val epoch = GeofencePlugin.currentAccountEpoch(context)
        val meta = GeofenceMetadataStore(context).read(gid)
        val generation = PendingReregister.generation(context)
        DwellAlarms.arm(context, gid, 60)
        client.active.clear() // Android discards the OS registrations on reboot, not app preferences.
        client.clearCalls()
        BootIdentity.testBootCount = 2
        recreateProcessState()
        BootReceiver().onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertEquals(1, dispatches.size)
        assertEquals(ExistingWorkPolicy.KEEP, dispatches.single().second)
        assertNull(DwellAlarms.getAttempt(context, gid))
        assertEquals(epoch, GeofencePlugin.currentAccountEpoch(context))
        assertEquals(meta, GeofenceMetadataStore(context).read(gid))
        assertTrue(PendingReregister.generation(context) > generation)
        assertForcedPending(PendingReregister.generation(context))
    }

    private fun assertForcedPending(generation: Long) {
        assertTrue(PendingReregister.isPending(context))
        assertTrue(PendingReregister.forceRecovery(context))
        assertEquals(generation, PendingReregister.generation(context))
    }

    private fun recreateProcessState() {
        clearHashCache()
        GeofencePlugin.accountEpoch = 0L
        plugin = GeofencePlugin().apply {
            initialize(context, client)
            playServicesStatus = { ConnectionResult.SUCCESS }
        }
    }

    private fun clearHashCache() {
        ReflectionHelpers.setStaticField(GeofencePlugin::class.java, "lastRegisteredHash", null)
        ReflectionHelpers.setStaticField(GeofencePlugin::class.java, "lastMerchantHash", null)
    }

    private fun register(
        zones: List<Map<String, Any?>> = listOf(zone),
        boundary: Map<String, Any?> = this.boundary,
    ): ChannelResult = ChannelResult().also { result ->
        plugin.onMethodCall(MethodCall("registerSet", mapOf(
            "zones" to zones, "boundary" to boundary, "user_id" to "synthetic-user",
            "account_epoch" to 41L, "recovery_generation" to PendingReregister.generation(context),
        )), result)
    }

    private class ChannelResult : MethodChannel.Result {
        var calls = 0
        var value: Any? = null
        var errorCode: String? = null
        override fun success(result: Any?) { calls++; value = result }
        override fun error(code: String, message: String?, details: Any?) { calls++; errorCode = code }
        override fun notImplemented() { error("Unexpected channel method") }
    }

    private class FakeGeofencingClient : GeofencingClient {
        data class Add(val request: GeofencingRequest, val completion: TaskCompletionSource<Void>)
        val adds = mutableListOf<Add>()
        val removals = mutableListOf<PendingIntent>()
        val active = mutableMapOf<PendingIntent, Set<String>>()
        override fun getApiKey(): ApiKey<Api.ApiOptions.NoOptions> = error("No real GMS client in offline tests")
        override fun addGeofences(request: GeofencingRequest, pi: PendingIntent): Task<Void> {
            val completion = TaskCompletionSource<Void>()
            adds.add(Add(request, completion))
            completion.task.addOnSuccessListener { active[pi] = request.geofences.map { it.requestId }.toSet() }
            return completion.task
        }
        override fun removeGeofences(pi: PendingIntent): Task<Void> {
            removals.add(pi)
            active.remove(pi)
            return Tasks.forResult(null)
        }
        override fun removeGeofences(ids: List<String>): Task<Void> = error("Unexpected ID removal")
        fun completeAdds() { adds.forEach { it.completion.trySetResult(null) } }
        fun addedIds(): Set<String> = adds.flatMap { it.request.geofences }.map { it.requestId }.toSet()
        fun activeIds(): Set<String> = active.values.flatten().toSet()
        fun clearCalls() { adds.clear(); removals.clear() }
    }
}
