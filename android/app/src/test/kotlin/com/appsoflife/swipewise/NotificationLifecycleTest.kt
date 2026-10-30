package com.appsoflife.swipewise

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.location.Location
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NotificationLifecycleTest {
    private fun meta(id: String) = MerchantMeta("m_$id", listOf(
        MerchantOption(id, id, "Dining", "Card", 3.0),
    ))

    @Test
    @Config(sdk = [24, 25, 34])
    fun `one current arrival replaces old advice and disable cleanup preserves other notifications`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel("other", "Other", NotificationManager.IMPORTANCE_DEFAULT))
        }
        nm.notify("other", 17, NotificationCompat.Builder(context, "other").setSmallIcon(android.R.drawable.ic_dialog_info).build())
        val helper = NotificationHelper(context)
        assertTrue(helper.postDwell(meta("A")))
        assertTrue(helper.postDwell(meta("B")))
        val arrivals = nm.activeNotifications.filter { it.tag == "swipewise.arrival" }
        assertEquals(1, arrivals.size)
        assertEquals("You're near B", arrivals.single().notification.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(2, nm.activeNotifications.size)
        NotificationHelper.cancelDwell(context)
        assertEquals("other", nm.activeNotifications.single().tag)
    }

    @Test fun `expiry is anchored to original verification not a later post`() {
        val context = RuntimeEnvironment.getApplication() as Context
        val helper = NotificationHelper(context)
        val verified = System.currentTimeMillis() - 5 * 60_000L
        assertTrue(helper.postDwell(meta("A"), verified))
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = nm.activeNotifications.single().notification
        assertEquals(verified, notification.`when`)
        assertTrue(notification.timeoutAfter in (25 * 60_000L - 1000L)..(25 * 60_000L))
        assertFalse(helper.postDwell(meta("old"), System.currentTimeMillis() - NotificationHelper.ARRIVAL_TTL_MS - 1))
        assertEquals(verified, nm.activeNotifications.single().notification.`when`)
    }

    @Test
    @Config(sdk = [24, 25, 34])
    fun `confirmed departure cancels advice but a noisy nearby exit does not`() {
        val context = RuntimeEnvironment.getApplication() as Context
        SystemClock.sleep(1_000_000L)
        NotificationHelper(context).postDwell(meta("A"))
        VisitLock.write(context, VisitLock.Visit(40.0, -100.0, System.currentTimeMillis(), "m_A", listOf("A")))
        fun fix(lat: Double) = Location("test").apply {
            latitude = lat; longitude = -100.0; accuracy = 10f
            elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        VisitLock.observeDeparture(context, fix(40.0001))
        assertEquals(1, nm.activeNotifications.size)
        VisitLock.observeDeparture(context, fix(40.01))
        assertTrue(nm.activeNotifications.isEmpty())
        assertTrue(VisitLock.read(context)!!.departed)
    }

    @Test fun `channel cleanup also removes old per merchant arrival IDs`() {
        val context = RuntimeEnvironment.getApplication() as Context
        NotificationHelper(context)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(123, NotificationCompat.Builder(context, NotificationHelper.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_map).build())
        NotificationHelper.cancelDwell(context)
        assertTrue(nm.activeNotifications.isEmpty())
    }
}
