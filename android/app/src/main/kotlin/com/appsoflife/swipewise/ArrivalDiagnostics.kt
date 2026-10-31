package com.appsoflife.swipewise

import android.content.Context
import java.io.File

// No free-text API: neither store/account identifiers nor coordinates can enter this file.
// Kept outside Android backup. Old entries are pruned on each read/write, including export.
object ArrivalDiagnostics {
    enum class Event {
        BOOT, ACTIVITY_ACTIVE, ACTIVITY_FAILED, REGISTRATION_OK, REGISTRATION_FAILED,
        FRESH_RETRY,
    }

    private const val FILE = "arrival-diagnostics.log"
    private const val MAX_ENTRIES = 500
    private const val MAX_AGE_MS = 48L * 60 * 60 * 1000

    fun record(context: Context, event: Event, value: Long? = null) =
        append(context, event.name, value)

    fun outcome(context: Context, outcome: DwellOutcome) =
        append(context, "OUTCOME_${outcome.name}", null)

    @Synchronized
    private fun append(context: Context, code: String, value: Long?) {
        try {
            val now = System.currentTimeMillis()
            val file = File(context.noBackupFilesDir, FILE)
            val lines = retained(file, now).takeLast(MAX_ENTRIES - 1)
            file.writeText((lines + "$now $code${value?.let { " value=$it" } ?: ""}").joinToString("\n", postfix = "\n"))
        } catch (_: Exception) {
            // Diagnostics must never interfere with an arrival or background recovery.
        }
    }

    @Synchronized
    fun read(context: Context): String = try {
        val file = File(context.noBackupFilesDir, FILE)
        val lines = retained(file, System.currentTimeMillis()).takeLast(MAX_ENTRIES)
        val text = if (lines.isEmpty()) "" else lines.joinToString("\n", postfix = "\n")
        if (file.exists()) file.writeText(text)
        text
    } catch (_: Exception) {
        "Diagnostics unavailable\n"
    }

    private fun retained(file: File, now: Long): List<String> =
        if (!file.exists()) emptyList() else file.readLines().filter { line ->
            val at = line.substringBefore(' ').toLongOrNull()
            at != null && at <= now && now - at <= MAX_AGE_MS
        }

    @Synchronized
    fun clear(context: Context) {
        try { File(context.noBackupFilesDir, FILE).delete() } catch (_: Exception) {}
    }
}
