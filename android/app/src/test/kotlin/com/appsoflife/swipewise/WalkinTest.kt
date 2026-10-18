package com.appsoflife.swipewise

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WalkinTest {
    private fun store(id: String) = MerchantOption(id, id, null, null, null)

    private fun c(id: String, m: Double) = StoreResolver.Candidate(store(id), m)

    @Test
    fun `clearly closest store is named alone`() {
        // Kyoto 12 m away, the ATM and Lenny's next door well beyond the ambiguity band.
        val picked = StoreResolver.resolve(listOf(c("atm", 60.0), c("kyoto", 12.0), c("lennys", 75.0)))
        assertEquals(listOf("kyoto"), picked.map { it.merchantId })
    }

    @Test
    fun `stores too close to tell apart become a short list, closest first`() {
        val picked = StoreResolver.resolve(
            listOf(c("b", 30.0), c("a", 20.0), c("c", 50.0), c("far", 90.0)),
        )
        assertEquals(listOf("a", "b", "c"), picked.map { it.merchantId })
    }

    @Test
    fun `the list is capped and de-duplicated across overlapping fences`() {
        val picked = StoreResolver.resolve(
            listOf(c("a", 1.0), c("a", 2.0), c("b", 3.0), c("c", 4.0), c("d", 5.0), c("e", 6.0)),
        )
        assertEquals(listOf("a", "b", "c", "d"), picked.map { it.merchantId })
    }

    @Test
    fun `nothing within reach resolves to nothing`() {
        assertTrue(StoreResolver.resolve(emptyList()).isEmpty())
    }

    @Test
    fun `a second alert nearby within the window is the same visit`() {
        val last = VisitLock.Visit(40.5014, -74.8549, 1_000_000L)
        // ~60 m away, 2 minutes later: the neighbour's overlapping fence.
        assertTrue(VisitLock.isSameVisit(last, 40.5019, -74.8549, 1_000_000L + 120_000L))
    }

    @Test
    fun `far away or after the window is a new visit`() {
        val last = VisitLock.Visit(40.5014, -74.8549, 1_000_000L)
        // ~2.7 km away (Buffalo Wild Wings vs Chick-fil-A), minutes later.
        assertFalse(VisitLock.isSameVisit(last, 40.5262, -74.8543, 1_000_000L + 300_000L))
        // Same spot, but after the window.
        assertFalse(VisitLock.isSameVisit(last, 40.5014, -74.8549, 1_000_000L + VisitLock.WINDOW_MS))
        assertFalse(VisitLock.isSameVisit(null, 40.5014, -74.8549, 0L))
    }

    private fun at(id: String, lat: Double, footprint: Double = 0.0) =
        MerchantOption(id, id, null, null, null, lat, -74.8549, footprint)

    @Test
    fun `inside a big-box store, the store beats the pad site out front`() {
        // User at 40.5014. Target's pin ~150 m north, Starbucks ~90 m south.
        val opts = listOf(at("target", 40.50275, footprint = 80.0), at("starbucks", 40.50059))
        val picked = StoreResolver.resolve(StoreResolver.candidates(opts, 40.5014, -74.8549, 200.0))
        assertEquals("target", picked.first().merchantId)
    }

    @Test
    fun `candidates outside reach are dropped`() {
        val opts = listOf(at("near", 40.5015), at("far", 40.5050))
        val c = StoreResolver.candidates(opts, 40.5014, -74.8549, 150.0)
        assertEquals(listOf("near"), c.map { it.option.merchantId })
    }

    @Test
    fun `the fallback list is capped to the closest four`() {
        val opts = (1..7).map { at("s$it", 40.5014 + it * 0.0001) }.reversed()
        val capped = StoreResolver.capped(opts, 40.5014, -74.8549)
        assertEquals(listOf("s1", "s2", "s3", "s4"), capped.map { it.merchantId })
    }

    @Test
    fun `a fence firing three times in an hour is resident, a visit is not`() {
        val now = 10_000_000L
        assertFalse(ResidentGuard.tripped(emptyList(), now))
        assertFalse(ResidentGuard.tripped(listOf(now - 60_000L), now))
        assertTrue(ResidentGuard.tripped(listOf(now - 60_000L, now - 1_200_000L), now))
        // Checks older than the window don't count.
        assertFalse(ResidentGuard.tripped(listOf(now - 60_000L, now - ResidentGuard.WINDOW_MS), now))
    }

    @Test
    fun `a store 93 m away is not one the user is in`() {
        // The 2026-10-17 red light: nearest store 93 m, fix accuracy 12 m.
        assertFalse(StoreResolver.atStore(93.0, 12.0))
        // Inside Costco: 2 m from its pin at 18 m accuracy.
        assertTrue(StoreResolver.atStore(2.0, 18.0))
    }

    @Test
    fun `a stay that keeps being held back keeps the lock`() {
        // Alert at 17:08, held back at 17:25 (lock restarted), next check 17:33.
        val start = VisitLock.Visit(40.362, -74.303, 0L)
        val refreshed = start.copy(atMillis = 17L * 60_000L)
        val at1733 = 25L * 60_000L
        assertFalse(VisitLock.isSameVisit(start, 40.362, -74.303, at1733))
        assertTrue(VisitLock.isSameVisit(refreshed, 40.362, -74.303, at1733))
    }

    @Test
    fun `distance is roughly right`() {
        val d = distanceM(40.5014, -74.8549, 40.5262, -74.8543)
        assertTrue("got $d", d in 2700.0..2800.0)
    }
}
