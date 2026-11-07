package com.appsoflife.swipewise

import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.location.Location
import android.os.SystemClock
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.DetectedActivity
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MvpArrivalRegressionTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val store get() = GeofenceMetadataStore(context)
    private val location = FakeLocationProvider()
    private val notifications = FakeNotificationPoster()
    private val meta = MerchantMeta("mvp", listOf(
        MerchantOption("shop", "Shop", "Dining", "Card A", 3.0, lat = 40.0, lng = -74.0),
    ), lat = 40.0, lng = -74.0, radiusM = 100f, dwellSeconds = 60)

    @Before fun setUp() {
        SystemClock.sleep(1_000_000L)
        BootIdentity.testBootCount = 1
        org.robolectric.Shadows.shadowOf(context as android.app.Application)
            .grantPermissions("android.permission.ACCESS_COARSE_LOCATION", "android.permission.ACCESS_FINE_LOCATION")
        GeofencePlugin.accountEpoch = 1
        store.clear()
        store.write(meta)
        ActivityState.clear(context)
        ArrivalDiagnostics.clear(context)
        context.getSharedPreferences("swipewise_visit_lock", Context.MODE_PRIVATE).edit().clear().commit()
        val path = context.getDatabasePath("swipewise.db")
        path.parentFile?.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(path, null).use {
            it.execSQL("CREATE TABLE IF NOT EXISTS merchant_notification_cooldown (merchant_id TEXT PRIMARY KEY, last_notified_at INTEGER)")
        }
        DwellCheckReceiver.locationProvider = location
        DwellCheckReceiver.notificationPoster = notifications
    }

    @After fun tearDown() {
        DwellAlarms.clearAll(context)
        BootIdentity.testBootCount = null
        DwellCheckReceiver.locationProvider = DefaultLocationProvider
        DwellCheckReceiver.notificationPoster = DefaultNotificationPoster
    }

    private fun fix(ageMillis: Long = 0, lat: Double = 40.0) = Location("test").apply {
        latitude = lat
        longitude = -74.0
        accuracy = 12f
        elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos() - ageMillis * 1_000_000L
    }

    private fun intent(token: Long) = Intent(context, DwellCheckReceiver::class.java).apply {
        action = "com.appsoflife.swipewise.DWELL_CHECK:mvp"
        putExtra("token", token)
    }

    private fun arm(): DwellAttempt = DwellAlarms.arm(context, "mvp", 60)!!.also { SystemClock.sleep(60_000L) }

    @Test fun `minute-old SDK fix uses live fence advice not stale coordinates`() {
        val attempt = arm()
        location.nextFix = fix(60_000L, lat = 41.0)
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertEquals("shop", notifications.postedMetas.single().primary.merchantId)
        assertTrue(notifications.postedMetas.single().approximate)
        assertTrue(VisitLock.read(context)!!.confirmed)
        assertTrue(ArrivalDiagnostics.read(context).contains("OUTCOME_POSTED_APPROXIMATE"))
    }

    @Test fun `internal department five minutes later is suppressed as same visit`() {
        val costcoMain = MerchantMeta("costco_main", listOf(
            MerchantOption("costco", "Costco Wholesale", "Shopping", "Costco Visa", 2.0, lat = 40.0, lng = -74.0, brandId = "costco", mainStore = true),
        ), lat = 40.0, lng = -74.0, radiusM = 100f, dwellSeconds = 30)
        val costcoCounters = MerchantMeta("costco_counters", listOf(
            MerchantOption("tmobile", "T-Mobile at Costco", "Shopping", "Ink", 5.0, lat = 40.0004, lng = -74.0),
            MerchantOption("bakery", "Costco Bakery", "Grocery", "Costco Visa", 2.0, lat = 40.0004, lng = -74.0, brandId = "costco"),
        ), lat = 40.0004, lng = -74.0, radiusM = 100f, dwellSeconds = 30)
        store.remove(meta.geofenceId)
        store.write(costcoMain)
        store.write(costcoCounters)

        // 1. Enter Costco Wholesale; alert posts for Costco
        val attempt1 = DwellAlarms.arm(context, "costco_main", 30)!!
        SystemClock.sleep(30_000L)
        location.nextFix = fix(60_000L)
        DwellCheckReceiver().onReceive(context, Intent(context, DwellCheckReceiver::class.java).apply {
            action = "com.appsoflife.swipewise.DWELL_CHECK:costco_main"
            putExtra("token", attempt1.token)
        })
        assertEquals(1, notifications.postedMetas.size)
        assertEquals("costco", notifications.postedMetas.first().primary.merchantId)

        // 2. Walk inside Costco for 5.5 minutes (past old 5-minute provisional timeout), triggering counters fence
        SystemClock.sleep(330_000L)
        val attempt2 = DwellAlarms.arm(context, "costco_counters", 30)!!
        SystemClock.sleep(30_000L)
        location.nextFix = fix(60_000L, lat = 40.0004)
        DwellCheckReceiver().onReceive(context, Intent(context, DwellCheckReceiver::class.java).apply {
            action = "com.appsoflife.swipewise.DWELL_CHECK:costco_counters"
            putExtra("token", attempt2.token)
        })

        // Suppressed as same visit! No second notification inside the warehouse!
        assertEquals(1, notifications.postedMetas.size)
        val visit = VisitLock.read(context)!!
        assertTrue(visit.confirmed)
        assertEquals(listOf("costco"), visit.merchantIds)
    }

    @Test fun `fresh in-fence fix no longer requires STILL or two sharp samples`() {
        val attempt = arm()
        location.nextFix = fix()
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertEquals(1, notifications.postedMetas.size)
    }

    @Test fun `real fallback posting retains the neighbouring chicken restaurant choice`() {
        val thai = meta.primary.copy(merchantId = "thai", name = "Thai Restaurant")
        val chicken = thai.copy(merchantId = "chicken", name = "Chicken Shop", lat = 40.00005)
        store.write(meta.copy(options = listOf(thai, chicken)))
        val attempt = arm()
        location.nextFix = fix(130_000L)
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        val posted = notifications.postedMetas.single()
        assertTrue(posted.approximate)
        assertEquals(listOf("thai", "chicken"), posted.options.map { it.merchantId })
    }

    @Test fun `ten second dwell reaches receiver without a hidden minute minimum`() {
        assertEquals(30, MerchantMeta.DEFAULT_DWELL_SECONDS)
        val started = SystemClock.elapsedRealtimeNanos()
        val attempt = DwellAlarms.arm(context, "mvp", 10)!!
        assertEquals(started + 10_000_000_000L, attempt.scheduledDueElapsedNanos)
        SystemClock.sleep(8_000L)
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertEquals(0, location.callCount)
        SystemClock.sleep(2_000L)
        location.nextFix = fix()
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertEquals(1, notifications.postedMetas.size)
    }

    @Test fun `null location restores fence advice after live dwell`() {
        val attempt = arm()
        location.nextFix = null
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertEquals(1, notifications.postedMetas.size)
    }

    @Test fun `stale location cannot fall back while driving`() {
        val attempt = arm()
        ActivityState.set(context, DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos(), System.currentTimeMillis())
        location.nextFix = fix(60_000L)
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertTrue(notifications.postedMetas.isEmpty())
    }

    @Test fun `null location cannot fall back while driving`() {
        val attempt = arm()
        ActivityState.set(context, DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos(), System.currentTimeMillis())
        location.nextFix = null
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertTrue(notifications.postedMetas.isEmpty())
    }

    @Test fun `non-permission SDK failure restores uncertain fence advice`() {
        val attempt = arm()
        location.shouldFail = true
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertTrue(notifications.postedMetas.single().approximate)
    }

    @Test fun `revoking location while acquisition is held cannot post fallback advice`() {
        val attempt = arm()
        location.holdCallback = true
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        org.robolectric.Shadows.shadowOf(context as android.app.Application)
            .denyPermissions("android.permission.ACCESS_COARSE_LOCATION", "android.permission.ACCESS_FINE_LOCATION")
        location.heldSuccessCallback!!.invoke(null)
        assertTrue(notifications.postedMetas.isEmpty())
        assertNull(DwellAlarms.getAttempt(context, "mvp"))
    }

    @Test fun `advice-only update preserves countdown and posts latest card`() {
        val attempt = DwellAlarms.arm(context, "mvp", 60)!!
        SystemClock.sleep(30_000L)
        store.write(meta.copy(options = meta.options.map { it.copy(bestCardName = "Card B") }))
        val preserved = DwellAlarms.validateAttempt(context, "mvp", attempt.token)
        assertNotNull(preserved)
        assertEquals(attempt.scheduledDueElapsedNanos, preserved!!.scheduledDueElapsedNanos)
        SystemClock.sleep(30_000L)
        location.nextFix = null
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertEquals("Card B", notifications.postedMetas.single().primary.bestCardName)
    }

    @Test fun `advice update during acquisition uses latest metadata`() {
        val attempt = arm()
        location.holdCallback = true
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        store.write(meta.copy(options = meta.options.map { it.copy(bestCardName = "Card B") }))
        location.heldSuccessCallback!!.invoke(null)
        assertEquals("Card B", notifications.postedMetas.single().primary.bestCardName)
    }

    @Test fun `muting while acquisition is held suppresses fallback`() {
        val attempt = arm()
        location.holdCallback = true
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        store.write(meta.copy(options = meta.options.map { it.copy(muted = true) }))
        assertNotNull(DwellAlarms.validateAttempt(context, "mvp", attempt.token))
        location.heldSuccessCallback!!.invoke(null)
        assertTrue(notifications.postedMetas.isEmpty())
    }

    @Test fun `muting resolved primary while precise acquisition is held prevents posting`() {
        var posterCalls = 0
        DwellCheckReceiver.notificationPoster = object : NotificationPoster {
            override fun postDwell(context: Context, meta: MerchantMeta, verifiedAtMillis: Long): Boolean {
                posterCalls++
                return false
            }
        }
        val attempt = arm()
        location.holdCallback = true
        ShadowLog.clear()
        DwellCheckReceiver().onReceive(context, intent(attempt.token))
        assertNotNull(location.heldSuccessCallback)
        store.write(meta.copy(options = meta.options.map { it.copy(muted = true) }))
        assertNotNull(DwellAlarms.validateAttempt(context, "mvp", attempt.token))

        location.heldSuccessCallback!!.invoke(fix())

        assertTrue(ShadowLog.getLogsForTag("SW.walkin").any {
            it.msg.contains("dwell decision ArrivalDecision(verdict=VERIFIED, outcome=POSTED,")
        })
        assertEquals(0, posterCalls)
        assertNull(DwellAlarms.getAttempt(context, "mvp"))
        assertTrue(ArrivalDiagnostics.read(context).contains("OUTCOME_MUTED"))
    }

    @Test fun `geometry changes still invalidate countdown`() {
        val attempt = arm()
        store.write(meta.copy(lat = 41.0))
        assertNull(DwellAlarms.validateAttempt(context, "mvp", attempt.token))
    }

    @Test fun `invalid fence geometry cannot post no-fix fallback`() {
        for (invalid in listOf(meta.copy(lat = 91.0), meta.copy(lng = 181.0), meta.copy(radiusM = 0f))) {
            store.write(invalid)
            val attempt = arm()
            location.nextFix = null
            DwellCheckReceiver().onReceive(context, intent(attempt.token))
            assertTrue(notifications.postedMetas.isEmpty())
            assertEquals(0, location.callCount)
            assertNull(DwellAlarms.getAttempt(context, "mvp"))
        }
    }

    @Test fun `dwell changes still invalidate countdown`() {
        val attempt = arm()
        store.write(meta.copy(dwellSeconds = 120))
        assertNull(DwellAlarms.validateAttempt(context, "mvp", attempt.token))
    }
}
