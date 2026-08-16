package com.appsoflife.swipewise

import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.database.sqlite.SQLiteDatabase

/// Why a fired dwell timer did or didn't post.
///
/// [DwellCheckReceiver] has seven exits and six of them are a bare `return`, so
/// from the outside a correctly-suppressed drive-by and an eaten real visit look
/// identical — both are simply silence. On a device measured 2026-08-16, 12 dwell
/// checks fired over two days and only 5 produced a notification; nothing on the
/// device could say which of the six paths ate the other 7.
enum class DwellOutcome(val wire: String) {
    POSTED("posted"),

    /// Fence set was replaced while this timer was in flight, so the metadata it
    /// needed is gone. Expected occasionally (a re-register lands mid-dwell);
    /// frequent means the AR-settle re-register is racing arrivals.
    NO_META("no_meta"),

    /// The verification fix put the user outside the fence. The prime suspect for
    /// eaten visits: the fix is BALANCED-power and taken indoors, and rural fences
    /// often sit on a business's registered address rather than its storefront.
    OUTSIDE_FENCE("outside_fence"),

    /// No fix in time AND activity recognition still says driving, so this is
    /// treated as a drive-by rather than an arrival.
    NO_FIX_DRIVING("no_fix_driving"),

    MUTED("muted"),
    MERCHANT_COOLDOWN("merchant_cooldown"),
    CATEGORY_COOLDOWN("category_cooldown"),
}

/// The verification fix, kept together so an [DwellOutcome.OUTSIDE_FENCE] row can
/// be re-judged after the fact: `distanceM <= allowedM` is the exact comparison
/// the receiver made, and `accuracyM` says how much of `allowedM` was slack the
/// fix itself bought.
data class DwellFix(
    val distanceM: Float,
    val accuracyM: Float,
    val allowedM: Float,
)

/// Disposable diagnostic trail: one row per fired dwell timer, in the same SQLite
/// file sqflite manages (`swipewise.db`). Read it with
/// `adb exec-out run-as com.appsoflife.swipewise.dev cat databases/swipewise.db`.
///
/// **This is a rig, not a feature.** Its ancestor (`debug_trail`) went in at DB v6
/// and was dropped at v8 once it had proven the pipeline; this one earns the same
/// ending. Delete the table, this file, and the call sites in [DwellCheckReceiver]
/// once the silent drops are attributed.
///
/// Debug builds only, and every write is best-effort — diagnostics must never cost
/// a notification.
class DwellOutcomeStore(private val context: Context) {

    fun record(
        geofenceId: String,
        merchantName: String?,
        outcome: DwellOutcome,
        fix: DwellFix? = null,
    ) {
        if (!isDebuggable()) return
        try {
            openDb().use { db ->
                // The native receiver can fire before Dart has opened the database
                // and run the v15 migration, so don't depend on that ordering.
                db.execSQL(CREATE_SQL)
                db.insert(TABLE, null, row(geofenceId, merchantName, outcome, fix))
                db.execSQL(TRIM_SQL)
            }
        } catch (_: Exception) {
            // Best-effort by design.
        }
    }

    private fun row(
        geofenceId: String,
        merchantName: String?,
        outcome: DwellOutcome,
        fix: DwellFix?,
    ) = ContentValues().apply {
        put("at", System.currentTimeMillis())
        put("geofence_id", geofenceId)
        put("merchant_name", merchantName)
        put("outcome", outcome.wire)
        put("distance_m", fix?.distanceM)
        put("accuracy_m", fix?.accuracyM)
        put("allowed_m", fix?.allowedM)
    }

    private fun isDebuggable(): Boolean =
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun openDb(): SQLiteDatabase {
        val path = context.getDatabasePath(DB_NAME).absolutePath
        return SQLiteDatabase.openDatabase(path, null, SQLiteDatabase.OPEN_READWRITE)
    }

    companion object {
        private const val DB_NAME = "swipewise.db"
        private const val TABLE = "dwell_outcomes"
        private const val CAP = 500

        /// Kept identical to `_createDwellOutcomesSql` in `database_helper.dart`.
        const val CREATE_SQL = """
            CREATE TABLE IF NOT EXISTS dwell_outcomes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              at INTEGER NOT NULL,
              geofence_id TEXT NOT NULL,
              merchant_name TEXT,
              outcome TEXT NOT NULL,
              distance_m REAL,
              accuracy_m REAL,
              allowed_m REAL
            )
        """

        private const val TRIM_SQL =
            "DELETE FROM $TABLE WHERE id NOT IN " +
                "(SELECT id FROM $TABLE ORDER BY id DESC LIMIT $CAP)"
    }
}
