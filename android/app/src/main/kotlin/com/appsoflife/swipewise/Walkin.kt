package com.appsoflife.swipewise

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/// One line per decision in the walk-in pipeline, at WARN so it survives
/// release builds. Before this the receivers logged nothing, so a missed or
/// doubled notification on a real phone could not be explained afterwards.
///
/// Debug builds also append to `files/walkin.log`, because logcat's ring buffer
/// holds only minutes and the phone is rarely plugged in when a walk-in happens.
/// Pull it after a day out:
/// `adb exec-out run-as com.appsoflife.swipewise.dev cat files/walkin.log`
///
/// Never in a store build: the file is a list of stores visited, with times, and
/// the background-location disclosure promises no history of where you've been.
/// A store build deletes any copy an earlier version (1.0.4) left behind.
object WalkinLog {
    private const val TAG = "SW.walkin"
    private const val FILE = "walkin.log"
    private const val MAX_BYTES = 512 * 1024
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    private var staleFileDeleted = false

    @Synchronized
    fun clear(context: Context) {
        try { File(context.applicationContext.filesDir, FILE).delete() } catch (_: Exception) {}
    }

    @Synchronized
    fun w(context: Context, message: String) {
        Log.w(TAG, message)
        // Diagnostics must never cost a notification: every failure is swallowed.
        try {
            val file = File(context.applicationContext.filesDir, FILE)
            val debuggable =
                context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
            if (!debuggable) {
                if (!staleFileDeleted) {
                    file.delete()
                    staleFileDeleted = true
                }
                return
            }
            if (file.length() > MAX_BYTES) {
                // Keep the newest half, from the next line boundary.
                val bytes = file.readBytes()
                var start = bytes.size / 2
                while (start < bytes.size && bytes[start] != '\n'.code.toByte()) start++
                file.writeBytes(bytes.copyOfRange(minOf(start + 1, bytes.size), bytes.size))
            }
            file.appendText("${stamp.format(Date())} $message\n")
        } catch (_: Exception) {
        }
    }
}

/// Which store the user is actually in, decided when a dwell timer fires.
///
/// The fence that fired is only a hint: fences overlap (a strip mall's
/// storefronts sit 20-60 m apart and each fence is 100 m), and a cluster fence
/// lists every store within 50 m. With a fresh fix we can do better — look at
/// every fenced store near the user and name the closest one, falling back to a
/// short "one of these" list only when stores are genuinely too close to tell
/// apart at the fix's accuracy.
object StoreResolver {
    /// A second store this much farther than the closest one is ruled out.
    const val AMBIGUITY_M = 35.0

    /// At most this many stores in a "you may be at one of these" list.
    const val MAX_OPTIONS = 4

    /// A fix worse than this can't order stores 35 m apart; name the fence's
    /// own stores instead (capped, closest first).
    const val MAX_ACCURACY_M = 50f

    /// The closest store must be this close (to its edge, plus the fix's
    /// accuracy) for the user to count as inside it. A red light 93 m from a
    /// nail salon passed the fence check (fence + accuracy + slack) and
    /// posted it (2026-10-17).
    const val AT_STORE_M = 60.0

    data class Candidate(val option: MerchantOption, val distanceM: Double)

    fun atStore(nearestM: Double, accuracyM: Double): Boolean = nearestM <= AT_STORE_M + accuracyM

    /// Stores within [reachM] of the fix, measured to the store's edge rather
    /// than its pin: a big-box store's pin can sit 150 m from where the user
    /// stands inside, while the coffee shop out front is 90 m away.
    fun candidates(options: List<MerchantOption>, lat: Double, lng: Double, reachM: Double): List<Candidate> =
        options.mapNotNull { o ->
            if (!o.walkinEligible || o.lat == null || o.lng == null) {
                null
            } else {
                Candidate(o, maxOf(0.0, distanceM(lat, lng, o.lat, o.lng) - o.footprintM))
            }
        }.filter { it.distanceM <= reachM }

    /// The fallback list when nothing could be resolved: at most [MAX_OPTIONS],
    /// closest to ([lat], [lng]) first; stores without a position go last.
    fun capped(all: List<MerchantOption>, lat: Double?, lng: Double?): List<MerchantOption> {
        val eligible = all.filter { it.walkinEligible }
        val options = eligible.filterNot { it.plaza }.ifEmpty { eligible }
        if (lat == null || lng == null) return foldSameAdvice(options).take(MAX_OPTIONS)
        return foldSameAdvice(
            options.sortedBy { o ->
                if (o.lat == null || o.lng == null) Double.MAX_VALUE else distanceM(lat, lng, o.lat, o.lng)
            },
        ).take(MAX_OPTIONS)
    }

    /// [candidates] are stores within reach of the fix (any order). Returns the
    /// ones to offer, closest first: one store when it is clearly the closest,
    /// else the few that are all about as close.
    ///
    /// A plaza's own pin is dropped whenever a real store is in reach: it sits
    /// mid-lot with a big-box footprint, so it always measured closest and led
    /// the list ahead of the store the user was in (2026-10-19: "JPA Plaza ·
    /// Desi Halal Meat & Fish"). It stays only when it is all there is.
    fun resolve(all: List<Candidate>): List<MerchantOption> {
        val eligible = all.filter { it.option.walkinEligible }
        if (eligible.isEmpty()) return emptyList()
        val candidates = eligible.filterNot { it.option.plaza }.ifEmpty { eligible }
        val sorted = candidates.sortedBy { it.distanceM }
        val nearest = sorted.first().distanceM
        return foldSameAdvice(
            sorted
                .takeWhile { it.distanceM <= nearest + AMBIGUITY_M }
                .map { it.option },
        ).take(MAX_OPTIONS)
    }

    /// Resolves [all] and verifies the closest non-plaza candidate is within
    /// [atStore] distance for [accuracyM]. Returns `emptyList()` when [all] is
    /// empty (caller falls back to fence options), `null` when the nearest
    /// non-plaza store is too far (`not_at_store`), or the resolved list.
    fun resolveAtStore(all: List<Candidate>, accuracyM: Double): List<MerchantOption>? {
        val picked = resolve(all)
        if (picked.isEmpty()) return emptyList()
        val eligible = all.filter { it.option.walkinEligible }
        val nearest = eligible.filterNot { it.option.plaza }.ifEmpty { eligible }.minOf { it.distanceM }
        return if (atStore(nearest, accuracyM)) picked else null
    }

    /// Drops any store whose card advice equals a nearer one's: telling them
    /// apart changes nothing about which card to use. Costco's bakery, food
    /// court and kiosk fold into Costco; Starbucks inside a Target stays,
    /// because coffee earns differently. Keeps order (nearest first), but a
    /// group is named by its brand's main store when the nearest is a counter
    /// inside it: ShopRite's pharmacy shares the supermarket's pin, and only
    /// list order picked between them (2026-10-22).
    fun foldSameAdvice(options: List<MerchantOption>): List<MerchantOption> =
        options.distinctBy { it.merchantId }
            .groupBy { it.bestCardName to it.bestRate }
            .values
            .map { same ->
                val nearest = same.first()
                same.firstOrNull { it.mainStore && nearest.brandId != null && it.brandId == nearest.brandId } ?: nearest
            }

    /// [options] with the one the user last picked from a "one of these" list
    /// moved to the front ([picks]: merchant id -> when picked; most recent
    /// wins). Nothing is dropped, so visiting the other store is one tap.
    /// Returns whether a pick reordered the list.
    fun preferPicked(options: List<MerchantOption>, picks: Map<String, Long>): Pair<List<MerchantOption>, Boolean> {
        if (options.size < 2) return options to false
        val usual = options.filter { picks.containsKey(it.merchantId) }
            .maxByOrNull { picks.getValue(it.merchantId) } ?: return options to false
        return (listOf(usual) + options.filter { it !== usual }) to true
    }
}

/// "One walk-in, one notification": after a store alert posts, any other alert
/// within [RADIUS_M] of it for [WINDOW_MS] is the same visit — overlapping
/// fences entered a few seconds apart, or a neighbour's timer firing while the
/// user is still inside. The per-category cooldown never caught these because
/// neighbouring stores have different categories.
///
/// The window slides: every alert it holds back restarts it, so it lasts as
/// long as the user stays. A fixed 20 minutes let a 36-minute Costco trip post
/// twice (2026-10-17).
///
/// Walking to the shop next door is a new visit: when a sharp fix names the
/// store(s) the user is in ([resolved]) and none of them is a store this
/// visit already alerted for, the lock doesn't hold. Indoor drift can't fake
/// it: the store the user is really in stays within [StoreResolver.AMBIGUITY_M]
/// of the closest, so it stays in [resolved]. Only a visit whose own alert was
/// named by a sharp fix remembers its stores: a coarse first alert is a guess,
/// and the sharper look minutes later is a correction, not a new store (Costco
/// Tire Service, then Costco Wholesale, 2026-10-17). A store with the same card
/// advice as one already named stays held back too, as in [StoreResolver.foldSameAdvice].
object VisitLock {
    const val WINDOW_MS = 20L * 60L * 1000L
    const val RADIUS_M = 250.0

    /// A visit also stays open this long past [WINDOW_MS] while the user hasn't
    /// left its fence. A quiet 20 minutes at the gym closed the visit, and the
    /// walk to the liquor store next door then had nothing to arm its check:
    /// no visit, and no new ENTER from a fence the user never left (2026-10-22).
    /// Capped, because a fence beside home may never see an EXIT.
    const val LINGER_MS = 2L * 60L * 60L * 1000L

    /// [fenceId]: the fence the visit alerted from. [merchantIds] / [advice]:
    /// the store(s) it named and their "card|rate", when a sharp fix named them.
    /// [left]: the user has exited [fenceId] since. [nextDoorCandidateId]: the
    /// different-advice store named by the previous check, awaiting a second
    /// consecutive check before breaking the visit lock (guards against a
    /// single indoor-drift fix).
    data class Visit(
        val lat: Double,
        val lng: Double,
        val atMillis: Long,
        val fenceId: String? = null,
        val merchantIds: List<String> = emptyList(),
        val advice: List<String> = emptyList(),
        val left: Boolean = false,
        val nextDoorCandidateId: String? = null,
    )

    fun adviceOf(o: MerchantOption): String = "${o.bestCardName}|${o.bestRate}"

    fun isActive(last: Visit?, nowMillis: Long): Boolean {
        if (last == null) return false
        val age = nowMillis - last.atMillis
        return age < WINDOW_MS || (last.fenceId != null && !last.left && age < WINDOW_MS + LINGER_MS)
    }

    fun isActive(last: Visit?, nowMillis: Long, lat: Double, lng: Double): Boolean =
        isActive(last, nowMillis) && distanceM(last!!.lat, last.lng, lat, lng) < RADIUS_M

    fun isActive(context: Context, nowMillis: Long, lat: Double, lng: Double): Boolean =
        isActive(read(context), nowMillis, lat, lng)

    /// Returns the merchantId of the new different-advice store if [resolved]
    /// names a store not yet alerted for in [last], or null otherwise.
    fun nextDoorCandidate(last: Visit, resolved: List<MerchantOption>?): String? {
        if (resolved.isNullOrEmpty() || last.merchantIds.isEmpty()) return null
        if (resolved.any { it.merchantId in last.merchantIds }) return null
        val first = resolved.first()
        if (adviceOf(first) in last.advice) return null
        return first.merchantId
    }

    /// [resolved]: the stores a sharp fix put the user in, or null when the
    /// fix couldn't tell (no fix, coarse fix, fence options as a fallback).
    /// Requires two consecutive checks naming the same new different-advice
    /// store before treating it as a next-door move.
    fun isSameVisit(
        last: Visit?,
        lat: Double,
        lng: Double,
        nowMillis: Long,
        resolved: List<MerchantOption>? = null,
    ): Boolean {
        if (last == null || !isActive(last, nowMillis)) return false
        if (distanceM(last.lat, last.lng, lat, lng) >= RADIUS_M) return false
        val candidate = nextDoorCandidate(last, resolved)
        val movedNextDoor = candidate != null && candidate == last.nextDoorCandidateId
        return !movedNextDoor
    }

    /// Updates [last] when a check is held back as the same visit: slides the
    /// window, anchors [fenceId], clears [left] (we just verified the user is
    /// still here), and records any first-seen [nextDoorCandidate].
    fun refresh(
        last: Visit,
        nowMillis: Long,
        resolved: List<MerchantOption>? = null,
        fenceId: String? = last.fenceId,
    ): Visit = last.copy(
        atMillis = nowMillis,
        fenceId = fenceId ?: last.fenceId,
        left = false,
        nextDoorCandidateId = nextDoorCandidate(last, resolved),
    )

    private const val PREFS = "swipewise_visit_lock"

    fun read(context: Context): Visit? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!p.contains("at")) return null
        return Visit(
            Double.fromBits(p.getLong("lat", 0L)),
            Double.fromBits(p.getLong("lng", 0L)),
            p.getLong("at", 0L),
            p.getString("fence", null),
            p.getString("ids", "")!!.split(',').filter { it.isNotEmpty() },
            p.getString("advice", "")!!.split('\n').filter { it.isNotEmpty() },
            p.getBoolean("left", false),
            p.getString("candidate", null),
        )
    }

    /// The user exited [fenceIds]; if the visit's fence is among them, the
    /// visit no longer lingers past [WINDOW_MS].
    fun markLeft(context: Context, fenceIds: List<String>) {
        val visit = read(context) ?: return
        if (visit.fenceId == null || visit.fenceId !in fenceIds || visit.left) return
        write(context, visit.copy(left = true))
    }

    /// The user re-entered [fenceIds]; if the visit's fence is among them, an
    /// earlier indoor-drift EXIT was a flap and the visit can linger again.
    fun clearLeft(context: Context, fenceIds: List<String>) {
        val visit = read(context) ?: return
        if (visit.fenceId == null || visit.fenceId !in fenceIds || !visit.left) return
        write(context, visit.copy(left = false))
    }

    fun clearLeft(context: Context, fenceId: String) = clearLeft(context, listOf(fenceId))

    /// commit(), not apply(): two timers can fire back to back, and the second
    /// must see the first one's visit.
    fun write(context: Context, visit: Visit) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong("lat", visit.lat.toRawBits())
            .putLong("lng", visit.lng.toRawBits())
            .putLong("at", visit.atMillis)
            .putString("fence", visit.fenceId)
            .putString("ids", visit.merchantIds.joinToString(","))
            .putString("advice", visit.advice.joinToString("\n"))
            .putBoolean("left", visit.left)
            .putString("candidate", visit.nextDoorCandidateId)
            .commit()
    }
}

/// A fence the user is living next to, not visiting: a store pinned at (or
/// beside) home or work wakes its dwell timer over and over as indoor fixes
/// drift across the fence edge, or posts on arrival after arrival. [THRESHOLD]
/// checks within [WINDOW_MS] — or [POST_THRESHOLD] actual posts within
/// [POST_WINDOW_MS] — marks the fence resident for [SUPPRESS_MS]; while
/// resident its timers post nothing and take no fix. A real visit is one check
/// (two when the first one was taken while still moving), so it never trips this.
object ResidentGuard {
    const val THRESHOLD = 3
    const val WINDOW_MS = 60L * 60L * 1000L
    const val SUPPRESS_MS = 7L * 24L * 60L * 60L * 1000L
    const val POST_THRESHOLD = 3
    const val POST_WINDOW_MS = 7L * 24L * 60L * 60L * 1000L

    /// [recent] are earlier check times for one fence (any order).
    fun tripped(recent: List<Long>, nowMillis: Long, windowMs: Long = WINDOW_MS): Boolean =
        recent.count { nowMillis - it < windowMs } + 1 >= THRESHOLD

    fun postsTripped(recentPosts: List<Long>, nowMillis: Long): Boolean =
        recentPosts.count { nowMillis - it < POST_WINDOW_MS } + 1 >= POST_THRESHOLD

    private const val PREFS = "swipewise_resident"

    fun isResident(context: Context, geofenceId: String, nowMillis: Long): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong("$geofenceId.until", 0L) > nowMillis

    /// Records this check and says whether the fence is (now) resident.
    fun check(context: Context, geofenceId: String, nowMillis: Long): Boolean {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (p.getLong("$geofenceId.until", 0L) > nowMillis) return true
        val recent = p.getString("$geofenceId.checks", "")!!
            .split(',').mapNotNull { it.toLongOrNull() }
            .filter { nowMillis - it < WINDOW_MS }
        val edit = p.edit()
        val tripped = tripped(recent, nowMillis)
        if (tripped) {
            edit.putLong("$geofenceId.until", nowMillis + SUPPRESS_MS).remove("$geofenceId.checks")
        } else {
            edit.putString("$geofenceId.checks", (recent + nowMillis).joinToString(","))
        }
        edit.commit()
        return tripped
    }

    /// Records an actual notification post and silences the fence for
    /// [SUPPRESS_MS] once it reaches [POST_THRESHOLD] posts within [POST_WINDOW_MS].
    fun recordPost(context: Context, geofenceId: String, nowMillis: Long): Boolean {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val recent = p.getString("$geofenceId.posts", "")!!
            .split(',').mapNotNull { it.toLongOrNull() }
            .filter { nowMillis - it < POST_WINDOW_MS }
        val edit = p.edit()
        val tripped = postsTripped(recent, nowMillis)
        if (tripped) {
            edit.putLong("$geofenceId.until", nowMillis + SUPPRESS_MS).remove("$geofenceId.posts")
        } else {
            edit.putString("$geofenceId.posts", (recent + nowMillis).joinToString(","))
        }
        edit.commit()
        return tripped
    }
}

/// Great-circle distance in metres. Pure Kotlin (not android.location) so the
/// decisions above are unit-testable on the JVM.
fun distanceM(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
    val r = 6_371_000.0
    val dLat = Math.toRadians(lat2 - lat1)
    val dLng = Math.toRadians(lng2 - lng1)
    val a = sin(dLat / 2) * sin(dLat / 2) +
        cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLng / 2) * sin(dLng / 2)
    return r * 2 * atan2(sqrt(a), sqrt(1 - a))
}
