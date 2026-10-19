package com.appsoflife.swipewise

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject

/// One candidate merchant inside a geofence. A registered geofence has at
/// least one option (single merchant) and can have several when nearby
/// merchants were clustered into a shared zone (mall food court, strip mall).
data class MerchantOption(
    val merchantId: String,
    val name: String,
    val category: String?,
    val bestCardName: String?,
    val bestRate: Double?,
    // The store's own position — a cluster fence is centred on one store, so
    // without these the dwell check can't tell which of its stores is closest.
    // Null for fences written by older builds.
    val lat: Double? = null,
    val lng: Double? = null,
    // How far the store's floor reaches past its pin (big-box stores), so
    // the user standing inside is measured as being at the store.
    val footprintM: Double = 0.0,
    // Google's pin for a whole shopping plaza ("JPA Plaza"), not a store.
    val plaza: Boolean = false,
)

data class MerchantMeta(
    val geofenceId: String,
    val options: List<MerchantOption>,
    // Fence geometry + dwell, needed by DwellCheckReceiver to time the
    // app-side dwell alarm and verify a fresh fix against the fence circle.
    // Nullable so metas written by older builds still parse (they get the
    // fail-open verification path until the next registerSet rewrites them).
    val lat: Double? = null,
    val lng: Double? = null,
    val radiusM: Float? = null,
    val dwellSeconds: Int = DEFAULT_DWELL_SECONDS,
    // Not stored: set at post time when the first option is the user's past
    // pick, so the notification says "probably" rather than "one of these".
    val usualFirst: Boolean = false,
) {
    val primary: MerchantOption get() = options.first()
    val isCluster: Boolean get() = options.size > 1

    companion object {
        const val DEFAULT_DWELL_SECONDS = 60
    }
}

class GeofenceMetadataStore(context: Context) {
    private val prefs =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun read(geofenceId: String): MerchantMeta? {
        val raw = prefs.getString(geofenceId, null) ?: return null
        return try {
            val o = JSONObject(raw)
            val options = parseOptions(o)
            if (options.isEmpty()) null
            else MerchantMeta(
                geofenceId = geofenceId,
                options = options,
                lat = if (o.has("lat") && !o.isNull("lat")) o.getDouble("lat") else null,
                lng = if (o.has("lng") && !o.isNull("lng")) o.getDouble("lng") else null,
                radiusM = if (o.has("radius_m") && !o.isNull("radius_m")) {
                    o.getDouble("radius_m").toFloat()
                } else null,
                dwellSeconds = o.optInt(
                    "dwell_seconds",
                    MerchantMeta.DEFAULT_DWELL_SECONDS,
                ),
            )
        } catch (e: Exception) {
            null
        }
    }

    fun write(meta: MerchantMeta) {
        val arr = JSONArray()
        for (opt in meta.options) arr.put(opt.toJson())
        val o = JSONObject().put("options", arr)
        if (meta.lat != null) o.put("lat", meta.lat)
        if (meta.lng != null) o.put("lng", meta.lng)
        if (meta.radiusM != null) o.put("radius_m", meta.radiusM.toDouble())
        o.put("dwell_seconds", meta.dwellSeconds)
        prefs.edit().putString(meta.geofenceId, o.toString()).apply()
    }

    /// Every registered merchant fence.
    fun readAll(): List<MerchantMeta> = prefs.all.keys.mapNotNull { read(it) }

    fun clear() {
        prefs.edit().clear().apply()
    }

    fun count(): Int = prefs.all.size

    companion object {
        private const val PREFS = "swipewise_geofence_meta"

        fun parseOptions(o: JSONObject): List<MerchantOption> {
            val arr = o.optJSONArray("options") ?: return emptyList()
            val out = mutableListOf<MerchantOption>()
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                out.add(item.toMerchantOption())
            }
            return out
        }
    }
}

fun MerchantOption.toJson(): JSONObject = JSONObject().apply {
    put("merchant_id", merchantId)
    put("name", name)
    put("category", category)
    put("best_card_name", bestCardName)
    if (bestRate != null) put("best_rate", bestRate) else put("best_rate", JSONObject.NULL)
    if (lat != null) put("lat", lat)
    if (lng != null) put("lng", lng)
    if (footprintM > 0) put("footprint_m", footprintM)
    if (plaza) put("plaza", true)
}

fun JSONObject.toMerchantOption(): MerchantOption = MerchantOption(
    merchantId = getString("merchant_id"),
    name = getString("name"),
    category = nullableString("category"),
    bestCardName = nullableString("best_card_name"),
    bestRate = if (isNull("best_rate")) null else getDouble("best_rate"),
    lat = if (has("lat") && !isNull("lat")) getDouble("lat") else null,
    lng = if (has("lng") && !isNull("lng")) getDouble("lng") else null,
    footprintM = optDouble("footprint_m", 0.0),
    plaza = optBoolean("plaza", false),
)

private fun JSONObject.nullableString(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return getString(key)
}

/// Cooldown bookkeeping, backed by the same SQLite file sqflite manages
/// (`swipewise.db`): `merchant_notification_cooldown` — same Kohl's stays quiet
/// for 6h. (`category_notification_cooldown` is no longer written: its 30-min
/// strip-mall suppression is [VisitLock]'s job now, and it silenced real
/// second visits such as dinner, then dessert across the road.)
class CooldownStore(private val context: Context) {

    fun lastMerchantNotified(merchantId: String): Long? =
        readTimestamp(MERCHANT_TABLE, MERCHANT_KEY, merchantId)

    /// Smart cooldown re-arm, called on boundary EXIT: leaving the whole
    /// mapped area makes the next visit to any of these merchants a new trip,
    /// so per-merchant cooldowns are cleared and a return re-notifies. In-area
    /// hops (walk to the car and back) never cross the boundary, so the 6h
    /// window still suppresses same-visit repeats.
    fun clearMerchantCooldowns(): Int =
        try {
            openDb().use { db ->
                db.compileStatement("DELETE FROM $MERCHANT_TABLE")
                    .executeUpdateDelete()
            }
        } catch (_: Exception) {
            0
        }

    fun markNotified(option: MerchantOption, atMillis: Long) {
        try {
            openDb().use { db ->
                writeRow(db, MERCHANT_TABLE, MERCHANT_KEY, option.merchantId, atMillis)
            }
        } catch (_: Exception) {
            // DB may not exist yet on a brand-new install (sqflite hasn't
            // run onCreate). Receiver swallows so a notification doesn't
            // get suppressed by a transient open failure.
        }
    }

    private fun readTimestamp(table: String, keyCol: String, key: String): Long? {
        return try {
            openDb().use { db ->
                db.rawQuery(
                    "SELECT last_notified_at FROM $table WHERE $keyCol = ? LIMIT 1",
                    arrayOf(key),
                ).use { c -> if (c.moveToFirst()) c.getLong(0) else null }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun writeRow(
        db: SQLiteDatabase,
        table: String,
        keyCol: String,
        key: String,
        atMillis: Long,
    ) {
        val values = ContentValues().apply {
            put(keyCol, key)
            put("last_notified_at", atMillis)
        }
        db.insertWithOnConflict(table, null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    private fun openDb(): SQLiteDatabase {
        val path = context.getDatabasePath(DB_NAME).absolutePath
        return SQLiteDatabase.openDatabase(
            path,
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )
    }

    companion object {
        private const val DB_NAME = "swipewise.db"
        private const val MERCHANT_TABLE = "merchant_notification_cooldown"
        private const val MERCHANT_KEY = "merchant_id"
    }
}

/// Read-only view of the per-store mute list (`muted_merchants`), backed by the
/// same SQLite file sqflite manages (`swipewise.db`). Mute/unmute writes happen
/// only in Dart; here we just check membership as a belt-and-braces guard so a
/// fence registered *before* the user muted the store still won't post a dwell
/// notification (until the next natural re-register drops the fence). Fail-safe:
/// any open/read failure returns "not muted", so a transient DB miss never eats
/// a legit notification.
class MutedStore(private val context: Context) {

    fun isMuted(merchantId: String): Boolean =
        try {
            openDb().use { db ->
                db.rawQuery(
                    "SELECT 1 FROM $TABLE WHERE $KEY = ? LIMIT 1",
                    arrayOf(merchantId),
                ).use { c -> c.moveToFirst() }
            }
        } catch (_: Exception) {
            false
        }

    private fun openDb(): SQLiteDatabase {
        val path = context.getDatabasePath(DB_NAME).absolutePath
        return SQLiteDatabase.openDatabase(
            path,
            null,
            SQLiteDatabase.OPEN_READONLY,
        )
    }

    companion object {
        private const val DB_NAME = "swipewise.db"
        private const val TABLE = "muted_merchants"
        private const val KEY = "merchant_id"
    }
}

/// Read-only view of `store_picks`: when the user last chose each store from a
/// "you may be at one of these" list (written by Dart's disambiguation sheet).
/// Two pins at one address (Patidar Supermarket and the pharmacy beside it)
/// can't be told apart by location, so the last pick goes first next time.
/// Fail-safe: any DB failure reads as "no picks".
class PickStore(private val context: Context) {

    fun picks(merchantIds: List<String>): Map<String, Long> {
        if (merchantIds.isEmpty()) return emptyMap()
        return try {
            SQLiteDatabase.openDatabase(
                context.getDatabasePath("swipewise.db").absolutePath,
                null,
                SQLiteDatabase.OPEN_READONLY,
            ).use { db ->
                val marks = merchantIds.joinToString(",") { "?" }
                db.rawQuery(
                    "SELECT merchant_id, picked_at FROM store_picks WHERE merchant_id IN ($marks)",
                    merchantIds.toTypedArray(),
                ).use { c ->
                    buildMap { while (c.moveToNext()) put(c.getString(0), c.getLong(1)) }
                }
            }
        } catch (_: Exception) {
            emptyMap()
        }
    }
}
