package com.appsoflife.swipewise

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WalkinTest {
    // Each test store gets its own card, so folding by card advice leaves it alone.
    private fun store(id: String) = MerchantOption(id, id, null, "card-$id", null)

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

    @Test
    fun `walking next door, a sharp fix naming a new store is a new visit`() {
        val last = VisitLock.Visit(
            40.5014, -74.8549, 1_000_000L, "m_a",
            listOf("a"), listOf(VisitLock.adviceOf(store("a"))),
        )
        val later = 1_000_000L + 300_000L
        // ~40 m on, in the shop next door, with its own card advice.
        assertFalse(VisitLock.isSameVisit(last, 40.50176, -74.8549, later, listOf(store("b"))))
        // Still in store a, or a fix too close to tell a from b: same visit.
        assertTrue(VisitLock.isSameVisit(last, 40.5014, -74.8549, later, listOf(store("a"))))
        assertTrue(VisitLock.isSameVisit(last, 40.5014, -74.8549, later, listOf(store("b"), store("a"))))
        // No sharp fix: nothing says the store changed.
        assertTrue(VisitLock.isSameVisit(last, 40.50176, -74.8549, later, null))
    }

    @Test
    fun `a next-door store with the same card advice stays held back`() {
        val coffee = MerchantOption("starbucks", "Starbucks", null, "Gold", 4.0)
        val other = MerchantOption("dunkin", "Dunkin", null, "Gold", 4.0)
        val last = VisitLock.Visit(
            40.5014, -74.8549, 1_000_000L, "m_s",
            listOf("starbucks"), listOf(VisitLock.adviceOf(coffee)),
        )
        assertTrue(VisitLock.isSameVisit(last, 40.5016, -74.8549, 1_100_000L, listOf(other)))
    }

    @Test
    fun `a visit first named by a coarse fix is corrected, not alerted twice`() {
        // Costco 2026-10-17: the first alert came from a 244 m fix, so the visit
        // remembers no store, and the sharp look at Costco Wholesale is held back.
        val last = VisitLock.Visit(40.5014, -74.8549, 1_000_000L, "m_tire")
        assertTrue(VisitLock.isSameVisit(last, 40.5016, -74.8549, 1_200_000L, listOf(store("costco"))))
    }

    private fun at(id: String, lat: Double, footprint: Double = 0.0) =
        MerchantOption(id, id, null, "card-$id", null, lat, -74.8549, footprint)

    @Test
    fun `inside a big-box store, the store beats the pad site out front`() {
        // User at 40.5014. Target's pin ~150 m north, Starbucks ~90 m south.
        val opts = listOf(at("target", 40.50275, footprint = 80.0), at("starbucks", 40.50059))
        val picked = StoreResolver.resolve(StoreResolver.candidates(opts, 40.5014, -74.8549, 200.0))
        assertEquals("target", picked.first().merchantId)
    }

    @Test
    fun `a plaza's own pin never leads when a store is in reach`() {
        // 2026-10-19: JPA Plaza (pin mid-lot, big-box footprint) at 0 m beat
        // Desi Halal Meat & Fish at 9 m, the store the user was in.
        val plaza = at("jpa-plaza", 40.5014, footprint = 80.0).copy(plaza = true)
        val opts = listOf(plaza, at("desi-halal", 40.50148))
        val picked = StoreResolver.resolve(StoreResolver.candidates(opts, 40.5014, -74.8549, 200.0))
        assertEquals(listOf("desi-halal"), picked.map { it.merchantId })
        assertEquals(listOf("desi-halal"), StoreResolver.capped(opts, 40.5014, -74.8549).map { it.merchantId })
        // Alone, it is still offered.
        assertEquals(listOf("jpa-plaza"), StoreResolver.capped(listOf(plaza), null, null).map { it.merchantId })
    }

    @Test
    fun `alert rates say x for points and miles, percent for cash back`() {
        assertEquals("3%", NotificationHelper.formatRate(3.0, "USD"))
        assertEquals("1.5%", NotificationHelper.formatRate(1.5, null))
        assertEquals("4x points", NotificationHelper.formatRate(4.0, "POINTS"))
        assertEquals("2x miles", NotificationHelper.formatRate(2.0, "MILES"))
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

    private fun advised(id: String, card: String?, rate: Double?) = MerchantOption(id, id, null, card, rate)

    @Test
    fun `places with the same card advice fold into the nearest`() {
        // Costco's bakery and kiosk get the Costco card; Starbucks inside a
        // Target earns differently, so it stays.
        val picked = StoreResolver.resolve(
            listOf(
                StoreResolver.Candidate(advised("costco", "Costco Visa", 2.0), 0.0),
                StoreResolver.Candidate(advised("bakery", "Costco Visa", 2.0), 29.0),
                StoreResolver.Candidate(advised("starbucks", "Gold", 4.0), 20.0),
            ),
        )
        assertEquals(listOf("costco", "starbucks"), picked.map { it.merchantId })
    }

    @Test
    fun `a counter sharing the main store's pin folds into the main store`() {
        // ShopRite's pharmacy and supermarket share one pin and one card; list
        // order used to name the pharmacy (2026-10-22).
        fun shoprite(id: String, main: Boolean) =
            MerchantOption(id, id, null, "Gold", 3.0, brandId = "shoprite", mainStore = main)
        val picked = StoreResolver.resolve(
            listOf(
                StoreResolver.Candidate(shoprite("pharmacy", false), 14.0),
                StoreResolver.Candidate(shoprite("supermarket", true), 14.0),
            ),
        )
        assertEquals(listOf("supermarket"), picked.map { it.merchantId })
        // Another brand's main store with the same card never takes the place
        // of the nearer store.
        val acme = MerchantOption("acme", "acme", null, "Gold", 3.0, brandId = "acme", mainStore = true)
        val other = StoreResolver.resolve(
            listOf(
                StoreResolver.Candidate(shoprite("pharmacy", false), 10.0),
                StoreResolver.Candidate(acme, 20.0),
            ),
        )
        assertEquals(listOf("pharmacy"), other.map { it.merchantId })
    }

    @Test
    fun `a visit lingers past its window until the user leaves its fence`() {
        // Last held back at 15:32; the walk next door came at 15:56.
        val visit = VisitLock.Visit(40.50, -74.85, 0L, "m_gym", listOf("gym"))
        val at1556 = 24L * 60_000L
        assertTrue(VisitLock.isActive(visit, at1556))
        assertFalse(VisitLock.isActive(visit.copy(left = true), at1556))
        assertFalse(VisitLock.isActive(visit.copy(fenceId = null), at1556))
        assertFalse(VisitLock.isActive(visit, VisitLock.WINDOW_MS + VisitLock.LINGER_MS))
    }

    @Test
    fun `the last pick goes first, nothing is dropped, most recent wins`() {
        val opts = listOf(store("pharmacy"), store("patidar"))
        val (none, noneReordered) = StoreResolver.preferPicked(opts, emptyMap())
        assertEquals(listOf("pharmacy", "patidar"), none.map { it.merchantId })
        assertFalse(noneReordered)
        val (once, reordered) = StoreResolver.preferPicked(opts, mapOf("patidar" to 100L))
        assertEquals(listOf("patidar", "pharmacy"), once.map { it.merchantId })
        assertTrue(reordered)
        val (later, _) = StoreResolver.preferPicked(opts, mapOf("patidar" to 100L, "pharmacy" to 200L))
        assertEquals(listOf("pharmacy", "patidar"), later.map { it.merchantId })
    }

    @Test
    fun `distance is roughly right`() {
        val d = distanceM(40.5014, -74.8549, 40.5262, -74.8543)
        assertTrue("got $d", d in 2700.0..2800.0)
    }
}
