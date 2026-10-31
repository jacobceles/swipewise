package com.appsoflife.swipewise

import android.content.Context
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ArrivalDiagnosticsTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val file: File get() = File(context.noBackupFilesDir, "arrival-diagnostics.log")

    @Before fun setUp() { ArrivalDiagnostics.clear(context) }
    @After fun tearDown() { ArrivalDiagnostics.clear(context) }

    @Test fun `records only typed codes and numeric fields outside backup`() {
        ArrivalDiagnostics.record(context, ArrivalDiagnostics.Event.FRESH_RETRY, 60_000L)
        ArrivalDiagnostics.outcome(context, DwellOutcome.STALE_FIX)
        val lines = ArrivalDiagnostics.read(context).lines().filter { it.isNotEmpty() }
        assertEquals(2, lines.size)
        assertTrue(lines[0].matches(Regex("\\d+ FRESH_RETRY value=60000")))
        assertTrue(lines[1].matches(Regex("\\d+ OUTCOME_STALE_FIX")))
        assertTrue(file.exists())
        assertFalse(File(context.filesDir, "arrival-diagnostics.log").exists())
        ArrivalDiagnostics.clear(context)
        assertEquals("", ArrivalDiagnostics.read(context))
    }

    @Test fun `keeps only newest 500 events`() {
        repeat(510) { ArrivalDiagnostics.record(context, ArrivalDiagnostics.Event.FRESH_RETRY, it.toLong()) }
        val lines = ArrivalDiagnostics.read(context).trim().lines()
        assertEquals(500, lines.size)
        assertTrue(lines.first().endsWith("value=10"))
        assertTrue(lines.last().endsWith("value=509"))
    }

    @Test fun `prunes expired future and malformed timestamps on read and write`() {
        // Relative to now so the retention fixture cannot expire with calendar time.
        val now = System.currentTimeMillis()
        val expired = now - 49L * 60 * 60 * 1000
        file.writeText("$expired BOOT\n${now + 60_000} BOOT\ninvalid\n$now ACTIVITY_ACTIVE\n")
        val retained = ArrivalDiagnostics.read(context)
        assertEquals("$now ACTIVITY_ACTIVE\n", retained)
        assertEquals(retained, file.readText())
        file.writeText("$expired BOOT\n")
        ArrivalDiagnostics.record(context, ArrivalDiagnostics.Event.REGISTRATION_OK, 3)
        assertFalse(file.readText().contains("BOOT"))
        assertTrue(file.readText().contains("REGISTRATION_OK value=3"))
    }
}
