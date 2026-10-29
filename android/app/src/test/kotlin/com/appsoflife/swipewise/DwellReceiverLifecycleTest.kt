package com.appsoflife.swipewise

import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.location.Location
import android.os.SystemClock
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionEvent
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.Geofence
import com.google.android.gms.tasks.CancellationToken
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.util.concurrent.TimeUnit

class FakeLocationProvider : LocationProvider {
    var nextFix: Location? = null
    var shouldFail: Boolean = false
    var failureException: Exception = RuntimeException("Location unavailable")
    var callCount: Int = 0

    var lastPriority: Int? = null
    var lastDuration: Long? = null
    var lastMaxUpdateAge: Long? = null
    var lastCancellationToken: CancellationToken? = null
    var holdCallback: Boolean = false
    var heldSuccessCallback: ((Location?) -> Unit)? = null

    override fun getCurrentLocation(
        context: Context,
        priority: Int,
        durationMillis: Long,
        maxUpdateAgeMillis: Long,
        cancellationToken: CancellationToken,
        onSuccess: (Location?) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        callCount++
        lastPriority = priority
        lastDuration = durationMillis
        lastMaxUpdateAge = maxUpdateAgeMillis
        lastCancellationToken = cancellationToken

        if (holdCallback) {
            heldSuccessCallback = onSuccess
            return
        }

        if (shouldFail) {
            onFailure(failureException)
        } else {
            onSuccess(nextFix)
        }
    }
}

class FakeNotificationPoster : NotificationPoster {
    val postedMetas = mutableListOf<MerchantMeta>()
    var shouldSucceed = true

    override fun postDwell(context: Context, meta: MerchantMeta): Boolean {
        if (shouldSucceed) {
            postedMetas.add(meta)
            return true
        }
        return false
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DwellReceiverLifecycleTest {

    private lateinit var context: Context
    private val fakeLocationProvider = FakeLocationProvider()
    private val fakeNotificationPoster = FakeNotificationPoster()
    private var bootReregisterEnqueued = false

    private val testGid = "test_fence_1"
    private val otherGid = "test_fence_2"
    private val testLat = 40.5014
    private val testLng = -74.8549
    private val testRadius = 100f

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        SystemClock.sleep(1_000_000L) // Advance monotonic clock past boot
        BootIdentity.testBootCount = 1

        DwellCheckReceiver.locationProvider = fakeLocationProvider
        DwellCheckReceiver.notificationPoster = fakeNotificationPoster
        bootReregisterEnqueued = false
        BootReceiver.workScheduler = object : BootWorkScheduler {
            override fun scheduleBootReregister(context: Context) {
                bootReregisterEnqueued = true
            }
        }

        GeofencePlugin.accountEpoch = 1
        DwellAlarms.clearAll(context)
        GeofenceMetadataStore(context).clear()
        ActivityState.clear(context)
        context.getSharedPreferences("swipewise_visit_lock", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("swipewise_resident", Context.MODE_PRIVATE).edit().clear().commit()

        val dbPath = context.getDatabasePath("swipewise.db")
        dbPath.parentFile?.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(dbPath, null).use { db ->
            db.execSQL("CREATE TABLE IF NOT EXISTS merchant_notification_cooldown (merchant_id TEXT PRIMARY KEY, last_notified_at INTEGER)")
            db.execSQL("DELETE FROM merchant_notification_cooldown")
        }

        val options = listOf(
            MerchantOption(
                merchantId = "store_1",
                name = "Best Coffee",
                category = "Dining",
                bestCardName = "Gold Card",
                bestRate = 4.0,
                lat = testLat,
                lng = testLng,
            ),
        )
        val meta = MerchantMeta(
            geofenceId = testGid,
            options = options,
            lat = testLat,
            lng = testLng,
            radiusM = testRadius,
            dwellSeconds = 60,
        )
        GeofenceMetadataStore(context).write(meta)
    }

    @After
    fun tearDown() {
        BootIdentity.testBootCount = null
        DwellAlarms.clearAll(context)
        DwellCheckReceiver.locationProvider = DefaultLocationProvider
        DwellCheckReceiver.notificationPoster = DefaultNotificationPoster
        BootReceiver.workScheduler = DefaultBootWorkScheduler
    }

    private fun mockLocation(
        lat: Double = testLat,
        lng: Double = testLng,
        accuracy: Float = 10f,
        speedMps: Float? = null,
        elapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ): Location {
        val loc = Location("fused")
        loc.latitude = lat
        loc.longitude = lng
        loc.accuracy = accuracy
        loc.elapsedRealtimeNanos = elapsedNanos
        loc.time = System.currentTimeMillis()
        if (speedMps != null) {
            loc.speed = speedMps
        }
        return loc
    }

    private fun dwellIntent(token: Long, recheck: Boolean = false, nextDoor: Boolean = false): Intent =
        Intent(context, DwellCheckReceiver::class.java).apply {
            action = "com.appsoflife.swipewise.DWELL_CHECK:$testGid"
            putExtra("token", token)
            putExtra("recheck", recheck)
            putExtra("next_door", nextDoor)
        }

    @Test
    fun `boot count zero is valid rather than an unavailable setting`() {
        BootIdentity.testBootCount = null
        android.provider.Settings.Global.putInt(
            context.contentResolver,
            android.provider.Settings.Global.BOOT_COUNT,
            0,
        )
        assertEquals(0, BootIdentity.getBootCount(context))
    }

    @Test
    fun `migration clears legacy bans and stale guessed visit without touching user choices`() {
        val legacy = context.getSharedPreferences("swipewise_visit_lock", Context.MODE_PRIVATE)
        legacy.edit().putLong("at", System.currentTimeMillis() - 2 * 3600_000L)
            .putLong("lat", testLat.toRawBits()).putLong("lng", testLng.toRawBits())
            .putString("fence", testGid).commit()
        context.getSharedPreferences("swipewise_resident", Context.MODE_PRIVATE).edit()
            .putLong("$testGid.until", System.currentTimeMillis() + 7 * 86400_000L).commit()
        context.getSharedPreferences("swipewise_walkin_state", Context.MODE_PRIVATE).edit().clear().commit()
        SQLiteDatabase.openDatabase(context.getDatabasePath("swipewise.db").path, null, 0).use { db ->
            db.execSQL("CREATE TABLE IF NOT EXISTS muted_merchants (merchant_id TEXT PRIMARY KEY)")
            db.execSQL("INSERT OR REPLACE INTO muted_merchants VALUES ('user-mute')")
            WalkinState.migrate(context)
            assertNull(VisitLock.read(context))
            assertTrue(context.getSharedPreferences("swipewise_resident", Context.MODE_PRIVATE).all.isEmpty())
            db.rawQuery("SELECT COUNT(*) FROM muted_merchants", null).use { c ->
                c.moveToFirst()
                assertEquals(1, c.getInt(0))
            }
        }
    }

    @Test
    fun `unavailable boot identity cannot validate saved activity`() {
        ActivityState.set(
            context,
            DetectedActivity.STILL,
            ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos(),
            System.currentTimeMillis(),
        )
        BootIdentity.testBootCount = BootIdentity.UNKNOWN_BOOT_COUNT
        assertNull(ActivityState.getObservation(context))
        assertEquals(0L, ActivityState.lastEventElapsedRealtimeNanos(context))
    }

    @Test
    fun `removing metadata increments only the fence revision`() {
        val store = GeofenceMetadataStore(context)
        val before = store.generation(testGid)
        store.remove(testGid)
        assertNull(store.read(testGid))
        assertEquals(before + 1L, store.generation(testGid))
    }

    @Test
    fun `null fix on dwell check fails closed and asserts request parameters`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = null

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertFalse(DwellAlarms.isArmed(context, testGid))
        assertEquals(15_000L, fakeLocationProvider.lastMaxUpdateAge)
        assertEquals(8_000L, fakeLocationProvider.lastDuration)
    }

    @Test
    fun `real looper timeout on held callback fails closed without side effects`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.holdCallback = true

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        // Request is in-flight; advance main looper past 8s timeout
        ShadowLooper.idleMainLooper(8001, TimeUnit.MILLISECONDS)

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertFalse(DwellAlarms.isArmed(context, testGid))

        // If held callback returns after timeout, it must abort without side effects
        fakeLocationProvider.heldSuccessCallback?.invoke(mockLocation())
        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertNull(VisitLock.read(context))
    }

    @Test
    fun `repeated ENTER while location callback is held preserves attempt token and deadline`() {
        val attempt1 = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.holdCallback = true

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt1.token))

        assertEquals(1, fakeLocationProvider.callCount)
        assertTrue(DwellAlarms.isArmed(context, testGid))

        // Repeated geofence ENTER arrives while callback is in-flight
        val geofenceReceiver = MerchantGeofenceReceiver()
        geofenceReceiver.handleTransition(
            context = context,
            transition = Geofence.GEOFENCE_TRANSITION_ENTER,
            triggeredGeofenceIds = listOf(testGid),
            triggeringLocation = mockLocation(),
        )

        // Must preserve the existing attempt token and deadline without replacing it
        val attemptAfterEnter = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(attemptAfterEnter)
        assertEquals(attempt1.token, attemptAfterEnter!!.token)
        assertEquals(attempt1.deadlineElapsedNanos, attemptAfterEnter.deadlineElapsedNanos)

        // In-flight callback resolves and can still verify successfully!
        ActivityState.set(
            context,
            DetectedActivity.STILL,
            ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos() - 10_000_000_000L,
            System.currentTimeMillis(),
        )
        fakeLocationProvider.heldSuccessCallback!!.invoke(mockLocation())

        assertEquals(1, fakeNotificationPoster.postedMetas.size)
        assertEquals("store_1", fakeNotificationPoster.postedMetas.first().primary.merchantId)
    }

    @Test
    fun `replay of old initial intent while waiting for recheck delay is ignored`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(accuracy = 12f, speedMps = null)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token, recheck = false))

        // Initial check evaluated and scheduled recheck delay
        val recheckAttempt = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(recheckAttempt)
        assertEquals(AttemptPhase.RECHECK_ARMED, recheckAttempt!!.phase)
        assertEquals(1, fakeLocationProvider.callCount)

        // Replay of old initial intent (recheck=false) arrives prematurely
        receiver.onReceive(context, dwellIntent(attempt.token, recheck = false))

        // Must be rejected as phase mismatch; no second location request launched
        assertEquals(1, fakeLocationProvider.callCount)
        assertEquals(AttemptPhase.RECHECK_ARMED, DwellAlarms.getAttempt(context, testGid)!!.phase)

        // Advance looper and clock by 60s recheck delay: real recheck intent verified!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(
            lat = testLat + 0.00001,
            lng = testLng + 0.00001,
            accuracy = 12f,
            speedMps = null,
        )
        receiver.onReceive(context, dwellIntent(recheckAttempt.token, recheck = true))

        assertEquals(2, fakeLocationProvider.callCount)
        assertEquals(1, fakeNotificationPoster.postedMetas.size)
    }

    @Test
    fun `overdue alarm receiver delivery is rejected without side effects`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        // Advance clock past total attempt deadline
        SystemClock.sleep(300_000L)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertEquals(0, fakeLocationProvider.callCount)
        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertNull(VisitLock.read(context))
    }

    @Test
    fun `held callback across metadata clear aborts with zero side effects`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.holdCallback = true

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        // Metadata store cleared mid-flight
        GeofenceMetadataStore(context).clear()

        // Callback arrives with valid fix
        fakeLocationProvider.heldSuccessCallback!!.invoke(mockLocation())

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertNull(VisitLock.read(context))
        assertTrue(context.getSharedPreferences("swipewise_resident", Context.MODE_PRIVATE).all.isEmpty())
    }

    @Test
    fun `held callback across epoch change aborts with zero side effects`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.holdCallback = true

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        // Account epoch increments (e.g. logout)
        GeofencePlugin.accountEpoch++

        fakeLocationProvider.heldSuccessCallback!!.invoke(mockLocation())

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertNull(VisitLock.read(context))
    }

    @Test
    fun `held callback across disable or unregisterAll aborts with zero side effects`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.holdCallback = true

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        // UnregisterAll clears metadata and cancels all alarms
        GeofenceMetadataStore(context).clear()
        DwellAlarms.cancelAll(context)

        fakeLocationProvider.heldSuccessCallback!!.invoke(mockLocation())

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertNull(VisitLock.read(context))
        assertNull(DwellAlarms.getAttempt(context, testGid))
    }

    @Test
    fun `stale or future fix fails closed on receiver path with zero side effects`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(
            elapsedNanos = SystemClock.elapsedRealtimeNanos() - 20_000_000_000L,
        )

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertFalse(DwellAlarms.isArmed(context, testGid))
        assertNull(VisitLock.read(context))
        assertTrue(context.getSharedPreferences("swipewise_resident", Context.MODE_PRIVATE).all.isEmpty())
    }

    @Test
    fun `exception on dwell check fails closed with distinct reason`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.shouldFail = true
        fakeLocationProvider.failureException = SecurityException("Permission revoked")

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertFalse(DwellAlarms.isArmed(context, testGid))
    }

    @Test
    fun `missing metadata geometry fails closed without notification`() {
        val metaNoGeo = MerchantMeta(
            geofenceId = testGid,
            options = listOf(MerchantOption("store_1", "Store", null, null, null)),
            lat = null,
            lng = null,
            radiusM = null,
        )
        GeofenceMetadataStore(context).write(metaNoGeo)

        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation()

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertEquals(0, fakeLocationProvider.callCount)
    }

    @Test
    fun `no candidates within reach fails closed without notification`() {
        val farOption = MerchantOption(
            merchantId = "far_store",
            name = "Far Away",
            category = "Dining",
            bestCardName = "Gold Card",
            bestRate = 4.0,
            lat = testLat + 0.05,
            lng = testLng + 0.05,
        )
        GeofenceMetadataStore(context).write(
            MerchantMeta(testGid, listOf(farOption), testLat, testLng, testRadius),
        )
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        ActivityState.set(
            context,
            DetectedActivity.STILL,
            ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos() - 10_000_000_000L,
            System.currentTimeMillis(),
        )
        fakeLocationProvider.nextFix = mockLocation()

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
    }

    @Test
    fun `repeated coarse fix on recheck fails closed without notification`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        DwellAlarms.updatePhase(context, testGid, attempt.token, AttemptPhase.RECHECK_ARMED)
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(accuracy = 65f)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token, recheck = true))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertFalse(DwellAlarms.isArmed(context, testGid))
    }

    @Test
    fun `repeated moving fix on recheck fails closed without notification`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        DwellAlarms.updatePhase(context, testGid, attempt.token, AttemptPhase.RECHECK_ARMED)
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(speedMps = 2.5f)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token, recheck = true))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertFalse(DwellAlarms.isArmed(context, testGid))
    }

    @Test
    fun `duplicate alarm delivery while fetching is ignored`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.holdCallback = true

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertEquals(1, fakeLocationProvider.callCount)

        // Duplicate delivery arrives while initial request is in-flight
        receiver.onReceive(context, dwellIntent(attempt.token))

        // Must not launch a second location request
        assertEquals(1, fakeLocationProvider.callCount)
    }

    @Test
    fun `replacement attempt is preserved when stale callback from previous token arrives`() {
        val attempt1 = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.holdCallback = true

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt1.token))

        val heldCallback1 = fakeLocationProvider.heldSuccessCallback
        assertNotNull(heldCallback1)

        // Previous attempt is cancelled and replaced by fresh attempt2
        DwellAlarms.cancel(context, testGid, attempt1.token)
        val attempt2 = DwellAlarms.arm(context, testGid, 60)!!
        assertEquals(attempt2.token, DwellAlarms.getAttempt(context, testGid)?.token)

        // Old callback for attempt1 finishes with null fix or error
        heldCallback1!!.invoke(null)

        // Replacement attempt2 must NOT be cancelled or clobbered!
        val surviving = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(surviving)
        assertEquals(attempt2.token, surviving!!.token)
    }

    @Test
    fun `identical metadata rewrite keeps in-flight attempt live`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        val initialGen = GeofenceMetadataStore(context).generation(testGid)

        // Unchanged metadata write (e.g. registerSet on launch)
        val existingMeta = GeofenceMetadataStore(context).read(testGid)!!
        GeofenceMetadataStore(context).write(existingMeta)

        assertEquals(initialGen, GeofenceMetadataStore(context).generation(testGid))

        ActivityState.set(
            context,
            DetectedActivity.STILL,
            ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos() - 10_000_000_000L,
            System.currentTimeMillis(),
        )
        fakeLocationProvider.nextFix = mockLocation()
        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertEquals(1, fakeNotificationPoster.postedMetas.size)
    }

    @Test
    fun `relevant geometry change invalidates attempt and new ENTER creates fresh token`() {
        val attempt1 = DwellAlarms.arm(context, testGid, 60)!!

        val existingMeta = GeofenceMetadataStore(context).read(testGid)!!
        GeofenceMetadataStore(context).write(existingMeta.copy(lat = testLat + 0.01))

        assertFalse(DwellAlarms.isArmed(context, testGid))

        val geofenceReceiver = MerchantGeofenceReceiver()
        geofenceReceiver.handleTransition(
            context = context,
            transition = Geofence.GEOFENCE_TRANSITION_ENTER,
            triggeredGeofenceIds = listOf(testGid),
            triggeringLocation = mockLocation(),
        )

        val attempt2 = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(attempt2)
        assertTrue(attempt2!!.token != attempt1.token)
    }

    @Test
    fun `reboot with new boot count rejects old attempt even if new uptime is greater than old created`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        assertTrue(DwellAlarms.isArmed(context, testGid))

        BootIdentity.testBootCount = 2
        SystemClock.sleep(2_000_000L)

        assertNull(DwellAlarms.validateAttempt(context, testGid, attempt.token))
        assertFalse(DwellAlarms.isArmed(context, testGid))

        val bootReceiver = BootReceiver()
        bootReceiver.onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))

        assertNull(DwellAlarms.getAttempt(context, testGid))
        assertTrue(bootReregisterEnqueued)
    }

    @Test
    fun `metadata clear erases stored attempt records and cancels alarms`() {
        val enterLoc = mockLocation(accuracy = 15f)
        val attempt = DwellAlarms.arm(context, testGid, 60, triggeringLocation = enterLoc)!!
        assertNotNull(DwellAlarms.getAttempt(context, testGid))
        assertTrue(DwellAlarms.isArmed(context, testGid))

        // Metadata clear (e.g. unregisterAll)
        GeofenceMetadataStore(context).clear()

        // Attempt and raw location record must be erased from storage!
        assertNull(DwellAlarms.getAttempt(context, testGid))
        assertFalse(DwellAlarms.isArmed(context, testGid))
    }

    @Test
    fun `metadata remove erases stored attempt record for that fence and cancels alarm`() {
        val attempt1 = DwellAlarms.arm(context, testGid, 60, triggeringLocation = mockLocation())!!
        val attempt2 = DwellAlarms.arm(context, otherGid, 60, triggeringLocation = mockLocation())!!
        assertNotNull(DwellAlarms.getAttempt(context, testGid))
        assertNotNull(DwellAlarms.getAttempt(context, otherGid))

        // Remove testGid metadata only
        GeofenceMetadataStore(context).remove(testGid)

        // testGid attempt erased, otherGid attempt preserved!
        assertNull(DwellAlarms.getAttempt(context, testGid))
        assertFalse(DwellAlarms.isArmed(context, testGid))
        assertNotNull(DwellAlarms.getAttempt(context, otherGid))
        assertTrue(DwellAlarms.isArmed(context, otherGid))
    }

    @Test
    fun `metadata geometry replacement erases stored attempt record and cancels alarm`() {
        val enterLoc = mockLocation(accuracy = 15f)
        val attempt1 = DwellAlarms.arm(context, testGid, 60, triggeringLocation = enterLoc)!!
        assertNotNull(DwellAlarms.getAttempt(context, testGid))

        // Metadata geometry replacement
        val existingMeta = GeofenceMetadataStore(context).read(testGid)!!
        GeofenceMetadataStore(context).write(existingMeta.copy(lat = testLat + 0.01))

        // Stored record must be erased so obsolete initial location sample is deleted!
        assertNull(DwellAlarms.getAttempt(context, testGid))
        assertFalse(DwellAlarms.isArmed(context, testGid))
    }

    @Test
    fun `unrelated or no-op metadata write does not erase valid baseline attempt`() {
        val enterLoc = mockLocation(accuracy = 15f)
        val attempt = DwellAlarms.arm(context, testGid, 60, triggeringLocation = enterLoc)!!
        assertNotNull(DwellAlarms.getAttempt(context, testGid)?.initialLat)

        // 1. Identical metadata write
        val existingMeta = GeofenceMetadataStore(context).read(testGid)!!
        GeofenceMetadataStore(context).write(existingMeta)
        val attemptAfterNoop = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(attemptAfterNoop)
        assertEquals(attempt.token, attemptAfterNoop!!.token)
        assertNotNull(attemptAfterNoop.initialLat)

        // 2. Unrelated fence write
        val otherMeta = MerchantMeta(otherGid, listOf(MerchantOption("other", "Other", null, null, null)), testLat, testLng, 100f)
        GeofenceMetadataStore(context).write(otherMeta)
        val attemptAfterOther = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(attemptAfterOther)
        assertEquals(attempt.token, attemptAfterOther!!.token)
        assertNotNull(attemptAfterOther.initialLat)
    }

    @Test
    fun `expiry cleans obsolete record on access`() {
        val enterLoc = mockLocation(accuracy = 15f)
        val attempt = DwellAlarms.arm(context, testGid, 60, triggeringLocation = enterLoc)!!
        assertNotNull(DwellAlarms.getAttempt(context, testGid))

        // Time advances past total deadline
        SystemClock.sleep(300_000L)

        // Accessing getAttempt or validateAttempt cleans the obsolete record
        assertNull(DwellAlarms.getAttempt(context, testGid))
        // Raw preference entry must be removed!
        assertNull(context.getSharedPreferences("swipewise_dwell_attempts", Context.MODE_PRIVATE).getString(testGid, null))
    }

    @Test
    fun `abandoned fetching state in dead process does not block fresh attempt in new process`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        // Simulate in-flight fetch in another process (PID 99999)
        val abandonedAttempt = attempt.copy(
            phase = AttemptPhase.FETCHING_INITIAL,
            fetchingPid = 99999,
        )
        context.getSharedPreferences("swipewise_dwell_attempts", Context.MODE_PRIVATE)
            .edit().putString(testGid, abandonedAttempt.toJson()).commit()

        // Abandoned fetching state must not be considered armed
        assertFalse(DwellAlarms.isArmed(context, testGid))

        // Fresh arm in current process succeeds and creates valid attempt
        val freshAttempt = DwellAlarms.arm(context, testGid, 60)
        assertNotNull(freshAttempt)
        assertTrue(freshAttempt!!.token != attempt.token)
        assertEquals(AttemptPhase.ARMED, freshAttempt.phase)
    }

    @Test
    fun `token mismatch fails validateAttempt`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        val wrongToken = attempt.token + 999L
        assertNull(DwellAlarms.validateAttempt(context, testGid, wrongToken))
    }

    @Test
    fun `unknown boot count fails closed`() {
        BootIdentity.testBootCount = BootIdentity.UNKNOWN_BOOT_COUNT
        assertNull(DwellAlarms.arm(context, testGid, 60))
        assertFalse(DwellAlarms.isArmed(context, testGid))
    }

    @Test
    fun `reboot resets AR monotonic barrier and accepts lower new postboot timestamp`() {
        val receiver = ActivityTransitionReceiver()

        BootIdentity.testBootCount = 1
        val preBootEvents = listOf(
            ActivityTransitionEvent(DetectedActivity.WALKING, ActivityTransition.ACTIVITY_TRANSITION_ENTER, 500_000_000_000L),
        )
        receiver.handleTransitions(context, preBootEvents, 500_000_000_000L)
        assertEquals(500_000_000_000L, ActivityState.lastEventElapsedRealtimeNanos(context))

        BootIdentity.testBootCount = 2
        ActivityState.clear(context)

        val postBootEvents = listOf(
            ActivityTransitionEvent(DetectedActivity.STILL, ActivityTransition.ACTIVITY_TRANSITION_ENTER, 10_000_000_000L),
        )
        receiver.handleTransitions(context, postBootEvents, 10_000_000_000L)

        val obs = ActivityState.getObservation(context, 10_000_000_000L)
        assertNotNull(obs)
        assertEquals(DetectedActivity.STILL, obs!!.type)
        assertEquals(10_000_000_000L, ActivityState.lastEventElapsedRealtimeNanos(context))
    }

    @Test
    fun `full visit lock next door sequence across confirmation checks`() {
        val storeA = MerchantOption("store_a", "Store A", "Dining", "Card 1", 3.0, lat = testLat, lng = testLng)
        val storeB = MerchantOption("store_b", "Store B", "Retail", "Card 2", 2.0, lat = testLat + 0.0006, lng = testLng)
        GeofenceMetadataStore(context).write(
            MerchantMeta(testGid, listOf(storeA, storeB), testLat, testLng, testRadius),
        )

        // 1. Initial post for Store A
        VisitLock.write(
            context,
            VisitLock.Visit(testLat, testLng, System.currentTimeMillis(), testGid, listOf("store_a"), listOf("Card 1|3.0")),
        )

        // 2. User moves to Store B: first check resolves Store B -> held back as SAME_VISIT
        ActivityState.set(
            context,
            DetectedActivity.STILL,
            ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos() - 10_000_000_000L,
            System.currentTimeMillis(),
        )
        val attempt1 = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt1.token))

        assertEquals(0, fakeNotificationPoster.postedMetas.size)
        val confirmationAttempt = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(confirmationAttempt)
        assertTrue(confirmationAttempt!!.isNextDoor)

        // 3. Second check for Store B confirms arrival next door and posts!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng)
        receiver.onReceive(context, dwellIntent(confirmationAttempt.token, nextDoor = true))

        assertEquals(1, fakeNotificationPoster.postedMetas.size)
        assertEquals("store_b", fakeNotificationPoster.postedMetas.first().primary.merchantId)
    }

    @Test
    fun `next door confirmation with different owner fence resolves to new owner fence`() {
        val storeA = MerchantOption("store_a", "Store A", "Dining", "Card 1", 3.0, lat = testLat, lng = testLng)
        val storeB = MerchantOption("store_b", "Store B", "Retail", "Card 2", 2.0, lat = testLat + 0.0006, lng = testLng)
        GeofenceMetadataStore(context).write(MerchantMeta(testGid, listOf(storeA), testLat, testLng, testRadius))
        GeofenceMetadataStore(context).write(MerchantMeta(otherGid, listOf(storeB), testLat + 0.0006, testLng, testRadius))

        VisitLock.write(
            context,
            VisitLock.Visit(testLat, testLng, System.currentTimeMillis(), testGid, listOf("store_a"), listOf("Card 1|3.0")),
        )

        ActivityState.set(
            context,
            DetectedActivity.STILL,
            ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos() - 10_000_000_000L,
            System.currentTimeMillis(),
        )
        val attempt1 = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt1.token))

        val confirmationAttempt = DwellAlarms.getAttempt(context, otherGid)
        assertNotNull(confirmationAttempt)
        assertTrue(confirmationAttempt!!.isNextDoor)

        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng)
        val otherIntent = Intent(context, DwellCheckReceiver::class.java).apply {
            action = "com.appsoflife.swipewise.DWELL_CHECK:$otherGid"
            putExtra("token", confirmationAttempt.token)
            putExtra("recheck", false)
            putExtra("next_door", true)
        }
        receiver.onReceive(context, otherIntent)

        assertEquals(1, fakeNotificationPoster.postedMetas.size)
        assertEquals(otherGid, fakeNotificationPoster.postedMetas.first().geofenceId)
        assertEquals("store_b", fakeNotificationPoster.postedMetas.first().primary.merchantId)
    }

    @Test
    fun `next-door check with no AR first check arms recheck and verifies on stable second check`() {
        val storeA = MerchantOption("store_a", "Store A", "Dining", "Card 1", 3.0, lat = testLat, lng = testLng)
        val storeB = MerchantOption("store_b", "Store B", "Retail", "Card 2", 2.0, lat = testLat + 0.0006, lng = testLng)
        GeofenceMetadataStore(context).write(
            MerchantMeta(testGid, listOf(storeA, storeB), testLat, testLng, testRadius),
        )

        VisitLock.write(
            context,
            VisitLock.Visit(testLat, testLng, System.currentTimeMillis(), testGid, listOf("store_a"), listOf("Card 1|3.0")),
        )

        // 1. Initial check arrives next-door (no AR) -> arms recheck to confirm stability
        val attempt1 = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng, accuracy = 12f)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt1.token))

        val initialRecheck = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(initialRecheck)
        assertEquals(AttemptPhase.RECHECK_ARMED, initialRecheck!!.phase)

        // 2. Recheck fires with stable fix -> verified arrival! Reaches maybePost and arms next-door confirmation
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng, accuracy = 12f)
        receiver.onReceive(context, dwellIntent(initialRecheck.token, recheck = true))

        val confirmationAttempt = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(confirmationAttempt)
        assertTrue(confirmationAttempt!!.isNextDoor)

        // 3. Next-door confirmation check fires with no AR -> arms recheck
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng, accuracy = 12f)
        receiver.onReceive(context, dwellIntent(confirmationAttempt.token, nextDoor = true))

        val nextDoorRecheck = DwellAlarms.getAttempt(context, testGid)
        assertNotNull(nextDoorRecheck)
        assertEquals(AttemptPhase.RECHECK_ARMED, nextDoorRecheck!!.phase)
        assertTrue(nextDoorRecheck.isNextDoor)

        // 4. Second check 60s later with stable fix -> verified and posts!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.0006, lng = testLng, accuracy = 12f)
        receiver.onReceive(context, dwellIntent(nextDoorRecheck.token, recheck = true, nextDoor = true))

        assertEquals(1, fakeNotificationPoster.postedMetas.size)
        assertEquals("store_b", fakeNotificationPoster.postedMetas.first().primary.merchantId)
    }

    @Test
    fun `activity transitions batch WALKING to STILL arms next door but STILL to IN_VEHICLE does not`() {
        val nowNanos = SystemClock.elapsedRealtimeNanos()

        VisitLock.write(
            context,
            VisitLock.Visit(testLat, testLng, System.currentTimeMillis(), testGid, listOf("store_a"), listOf("Card 1|3.0")),
        )

        val receiver = ActivityTransitionReceiver()

        // Batch 1: WALKING -> STILL
        val events1 = listOf(
            ActivityTransitionEvent(DetectedActivity.WALKING, ActivityTransition.ACTIVITY_TRANSITION_ENTER, nowNanos - 20_000_000_000L),
            ActivityTransitionEvent(DetectedActivity.STILL, ActivityTransition.ACTIVITY_TRANSITION_ENTER, nowNanos - 10_000_000_000L),
        )
        receiver.handleTransitions(context, events1, nowNanos)
        assertTrue(DwellAlarms.isArmed(context, testGid))

        DwellAlarms.clearAll(context)

        // Batch 2: STILL -> IN_VEHICLE
        val events2 = listOf(
            ActivityTransitionEvent(DetectedActivity.STILL, ActivityTransition.ACTIVITY_TRANSITION_ENTER, nowNanos + 1_000_000_000L),
            ActivityTransitionEvent(DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_ENTER, nowNanos + 5_000_000_000L),
        )
        receiver.handleTransitions(context, events2, nowNanos + 10_000_000_000L)
        assertFalse(DwellAlarms.isArmed(context, testGid))
    }

    @Test
    fun `rejected checks write zero to visitlock resident prefs and real sqlite cooldown table`() {
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        // Outside fix -> rejected
        fakeLocationProvider.nextFix = mockLocation(lat = testLat + 0.05)

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertTrue(fakeNotificationPoster.postedMetas.isEmpty())
        assertNull(VisitLock.read(context))
        assertTrue(context.getSharedPreferences("swipewise_resident", Context.MODE_PRIVATE).all.isEmpty())

        val cooldown = CooldownStore(context)
        assertNull(cooldown.lastMerchantNotified("store_1"))
    }

    @Test
    fun `verified post writes real sqlite cooldown and visitlock`() {
        ActivityState.set(
            context,
            DetectedActivity.STILL,
            ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos() - 10_000_000_000L,
            System.currentTimeMillis(),
        )
        val attempt = DwellAlarms.arm(context, testGid, 60)!!
        SystemClock.sleep(60_000L)
        fakeLocationProvider.nextFix = mockLocation()

        val receiver = DwellCheckReceiver()
        receiver.onReceive(context, dwellIntent(attempt.token))

        assertEquals(1, fakeNotificationPoster.postedMetas.size)
        assertNotNull(VisitLock.read(context))

        val cooldown = CooldownStore(context)
        assertNotNull(cooldown.lastMerchantNotified("store_1"))
    }
}
