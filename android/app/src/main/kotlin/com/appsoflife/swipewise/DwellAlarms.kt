package com.appsoflife.swipewise

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.Build
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.util.Random

enum class AttemptPhase {
    ARMED,
    FETCHING_INITIAL,
    RECHECK_ARMED,
    FETCHING_RECHECK,
    COMPLETED,
}

data class DwellAttempt(
    val token: Long,
    val geofenceId: String,
    val accountEpoch: Long,
    val metadataGeneration: Long,
    val bootCount: Int,
    val createdAtElapsedNanos: Long,
    val scheduledDueElapsedNanos: Long,
    val deadlineElapsedNanos: Long,
    val phase: AttemptPhase = AttemptPhase.ARMED,
    val isNextDoor: Boolean = false,
    val fetchingPid: Int? = null,
    val initialLat: Double? = null,
    val initialLng: Double? = null,
    val initialAccuracyM: Float? = null,
    val initialElapsedNanos: Long? = null,
) {
    val isRecheck: Boolean get() = phase == AttemptPhase.RECHECK_ARMED || phase == AttemptPhase.FETCHING_RECHECK

    fun toJson(): String = JSONObject().apply {
        put("token", token)
        put("geofenceId", geofenceId)
        put("accountEpoch", accountEpoch)
        put("metadataGeneration", metadataGeneration)
        put("bootCount", bootCount)
        put("createdAtElapsedNanos", createdAtElapsedNanos)
        put("scheduledDueElapsedNanos", scheduledDueElapsedNanos)
        put("deadlineElapsedNanos", deadlineElapsedNanos)
        put("phase", phase.name)
        put("isNextDoor", isNextDoor)
        if (fetchingPid != null) put("fetchingPid", fetchingPid)
        if (initialLat != null) put("initialLat", initialLat)
        if (initialLng != null) put("initialLng", initialLng)
        if (initialAccuracyM != null) put("initialAccuracyM", initialAccuracyM.toDouble())
        if (initialElapsedNanos != null) put("initialElapsedNanos", initialElapsedNanos)
    }.toString()

    companion object {
        fun fromJson(json: String): DwellAttempt? = try {
            val o = JSONObject(json)
            val createdAt = o.getLong("createdAtElapsedNanos")
            val scheduledDue = if (o.has("scheduledDueElapsedNanos")) o.getLong("scheduledDueElapsedNanos") else createdAt + 60_000_000_000L
            DwellAttempt(
                token = o.getLong("token"),
                geofenceId = o.getString("geofenceId"),
                accountEpoch = o.getLong("accountEpoch"),
                metadataGeneration = o.getLong("metadataGeneration"),
                bootCount = o.optInt("bootCount", BootIdentity.UNKNOWN_BOOT_COUNT),
                createdAtElapsedNanos = createdAt,
                scheduledDueElapsedNanos = scheduledDue,
                deadlineElapsedNanos = o.getLong("deadlineElapsedNanos"),
                phase = AttemptPhase.valueOf(o.optString("phase", AttemptPhase.ARMED.name)),
                isNextDoor = o.optBoolean("isNextDoor", false),
                fetchingPid = if (o.has("fetchingPid") && !o.isNull("fetchingPid")) o.getInt("fetchingPid") else null,
                initialLat = if (o.has("initialLat") && !o.isNull("initialLat")) o.getDouble("initialLat") else null,
                initialLng = if (o.has("initialLng") && !o.isNull("initialLng")) o.getDouble("initialLng") else null,
                initialAccuracyM = if (o.has("initialAccuracyM") && !o.isNull("initialAccuracyM")) o.getDouble("initialAccuracyM").toFloat() else null,
                initialElapsedNanos = if (o.has("initialElapsedNanos") && !o.isNull("initialElapsedNanos")) o.getLong("initialElapsedNanos") else null,
            )
        } catch (_: Exception) {
            null
        }
    }
}

/// One-shot dwell timers with durable attempt tokens, one per merchant geofence.
/// Armed on geofence ENTER (or next-door check), cancelled on EXIT; firing wakes
/// [DwellCheckReceiver], which verifies the user is still at the fence before posting.
object DwellAlarms {
    private const val ACTION_PREFIX = "com.appsoflife.swipewise.DWELL_CHECK:"
    private const val EXTRA_TOKEN = "token"
    private const val EXTRA_RECHECK = "recheck"
    private const val EXTRA_NEXT_DOOR = "next_door"
    private const val PREFS = "swipewise_dwell_armed"
    private const val PREFS_ATTEMPTS = "swipewise_dwell_attempts"
    private const val OVERDUE_GRACE_NANOS = 30_000_000_000L // 30s grace for alarm firing delay

    private val rng = Random()

    fun isArmed(
        context: Context,
        geofenceId: String,
        nowElapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ): Boolean {
        val attempt = getAttempt(context, geofenceId, nowElapsedNanos) ?: return false
        return attempt.phase in setOf(
            AttemptPhase.ARMED,
            AttemptPhase.FETCHING_INITIAL,
            AttemptPhase.RECHECK_ARMED,
            AttemptPhase.FETCHING_RECHECK,
        )
    }

    fun isAbandonedFetching(attempt: DwellAttempt): Boolean {
        if (attempt.phase != AttemptPhase.FETCHING_INITIAL && attempt.phase != AttemptPhase.FETCHING_RECHECK) return false
        return attempt.fetchingPid != null && attempt.fetchingPid != Process.myPid()
    }

    private fun isExpiredOrInvalid(
        context: Context,
        geofenceId: String,
        attempt: DwellAttempt,
        nowElapsedNanos: Long,
    ): Boolean {
        val currentBoot = BootIdentity.getBootCount(context)
        return currentBoot == BootIdentity.UNKNOWN_BOOT_COUNT ||
            attempt.bootCount != currentBoot ||
            attempt.accountEpoch != GeofencePlugin.accountEpoch ||
            attempt.metadataGeneration != GeofenceMetadataStore(context).generation(geofenceId) ||
            nowElapsedNanos < attempt.createdAtElapsedNanos ||
            nowElapsedNanos > attempt.deadlineElapsedNanos + OVERDUE_GRACE_NANOS ||
            attempt.phase == AttemptPhase.COMPLETED ||
            isAbandonedFetching(attempt)
    }

    private fun getAttemptRaw(context: Context, geofenceId: String): DwellAttempt? {
        val raw = prefsAttempts(context).getString(geofenceId, null) ?: return null
        return DwellAttempt.fromJson(raw)
    }

    fun getAttempt(
        context: Context,
        geofenceId: String,
        nowElapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ): DwellAttempt? {
        val attempt = getAttemptRaw(context, geofenceId) ?: return null
        if (isExpiredOrInvalid(context, geofenceId, attempt, nowElapsedNanos)) {
            cancel(context, geofenceId, attempt.token)
            return null
        }
        return attempt
    }

    fun validateAttempt(
        context: Context,
        geofenceId: String,
        token: Long,
        nowElapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ): DwellAttempt? {
        if (token == 0L) return null
        val attempt = getAttemptRaw(context, geofenceId) ?: return null
        if (attempt.token != token) return null // Never cancel a newer token on mismatch
        if (isExpiredOrInvalid(context, geofenceId, attempt, nowElapsedNanos)) {
            // Owned attempt failed validation: discard/cancel THAT token only
            cancel(context, geofenceId, attempt.token)
            return null
        }
        return attempt
    }

    fun updatePhase(
        context: Context,
        geofenceId: String,
        token: Long,
        newPhase: AttemptPhase,
        nowElapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ): DwellAttempt? {
        val attempt = validateAttempt(context, geofenceId, token, nowElapsedNanos) ?: return null
        val pid = if (newPhase == AttemptPhase.FETCHING_INITIAL || newPhase == AttemptPhase.FETCHING_RECHECK) {
            Process.myPid()
        } else {
            null
        }
        val updated = attempt.copy(phase = newPhase, fetchingPid = pid)
        saveAttempt(context, updated)
        return updated
    }

    fun arm(
        context: Context,
        geofenceId: String,
        dwellSeconds: Int,
        recheck: Boolean = false,
        nextDoor: Boolean = false,
        triggeringLocation: Location? = null,
        nowElapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ): DwellAttempt? {
        val bootCount = BootIdentity.getBootCount(context)
        if (bootCount == BootIdentity.UNKNOWN_BOOT_COUNT) {
            WalkinLog.w(context, "dwell arm $geofenceId: unknown boot count -> failing closed")
            return null
        }

        val existing = getAttemptRaw(context, geofenceId)
        if (existing != null) {
            if (isExpiredOrInvalid(context, geofenceId, existing, nowElapsedNanos)) {
                cancel(context, geofenceId, existing.token)
            } else if (!recheck && !nextDoor && isArmed(context, geofenceId, nowElapsedNanos)) {
                WalkinLog.w(context, "dwell arm $geofenceId: already active with token ${existing.token}; keeping dwell countdown")
                return existing
            }
        }

        val token = if (recheck && existing != null) existing.token else generateToken()
        val createdAt = if (recheck && existing != null) existing.createdAtElapsedNanos else nowElapsedNanos
        val deadline = if (recheck && existing != null) {
            existing.deadlineElapsedNanos
        } else {
            val totalSeconds = dwellSeconds * 2 + 120
            createdAt + totalSeconds * 1_000_000_000L
        }
        val scheduledDue = nowElapsedNanos + dwellSeconds * 1_000_000_000L

        var initLat: Double? = if (recheck) existing?.initialLat else null
        var initLng: Double? = if (recheck) existing?.initialLng else null
        var initAcc: Float? = if (recheck) existing?.initialAccuracyM else null
        var initElapsed: Long? = if (recheck) existing?.initialElapsedNanos else null

        if (!recheck && triggeringLocation != null && triggeringLocation.hasAccuracy() &&
            triggeringLocation.accuracy <= StoreResolver.MAX_ACCURACY_M
        ) {
            val ageNanos = nowElapsedNanos - triggeringLocation.elapsedRealtimeNanos
            if (ageNanos in 0..(15_000L * 1_000_000L)) {
                initLat = triggeringLocation.latitude
                initLng = triggeringLocation.longitude
                initAcc = triggeringLocation.accuracy
                initElapsed = triggeringLocation.elapsedRealtimeNanos
            }
        }

        val attempt = DwellAttempt(
            token = token,
            geofenceId = geofenceId,
            accountEpoch = GeofencePlugin.accountEpoch,
            metadataGeneration = GeofenceMetadataStore(context).generation(geofenceId),
            bootCount = bootCount,
            createdAtElapsedNanos = createdAt,
            scheduledDueElapsedNanos = scheduledDue,
            deadlineElapsedNanos = deadline,
            phase = if (recheck) AttemptPhase.RECHECK_ARMED else AttemptPhase.ARMED,
            isNextDoor = nextDoor,
            initialLat = initLat,
            initialLng = initLng,
            initialAccuracyM = initAcc,
            initialElapsedNanos = initElapsed,
        )

        saveAttempt(context, attempt)
        prefs(context).edit()
            .putLong(geofenceId, System.currentTimeMillis() + dwellSeconds * 1000L)
            .apply()

        scheduleAlarm(context, geofenceId, dwellSeconds, attempt)
        return attempt
    }

    fun armRecheck(
        context: Context,
        geofenceId: String,
        dwellSeconds: Int,
        attempt: DwellAttempt,
        priorObservation: FixObservation?,
        nowElapsedNanos: Long = SystemClock.elapsedRealtimeNanos(),
    ): DwellAttempt? {
        val validated = validateAttempt(context, geofenceId, attempt.token, nowElapsedNanos) ?: return null
        if (validated.phase != AttemptPhase.FETCHING_INITIAL) return null

        val updated = validated.copy(
            phase = AttemptPhase.RECHECK_ARMED,
            scheduledDueElapsedNanos = nowElapsedNanos + dwellSeconds * 1_000_000_000L,
            initialLat = priorObservation?.lat ?: validated.initialLat,
            initialLng = priorObservation?.lng ?: validated.initialLng,
            initialAccuracyM = priorObservation?.accuracyM ?: validated.initialAccuracyM,
            initialElapsedNanos = priorObservation?.elapsedRealtimeNanos ?: validated.initialElapsedNanos,
        )
        saveAttempt(context, updated)
        prefs(context).edit()
            .putLong(geofenceId, System.currentTimeMillis() + dwellSeconds * 1000L)
            .apply()

        scheduleAlarm(context, geofenceId, dwellSeconds, updated)
        return updated
    }

    private fun scheduleAlarm(context: Context, geofenceId: String, dwellSeconds: Int, attempt: DwellAttempt) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pendingIntent(context, geofenceId, attempt.token, attempt.isRecheck, attempt.isNextDoor)
        val at = SystemClock.elapsedRealtime() + dwellSeconds * 1000L

        val exact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                am.canScheduleExactAlarms()
            } catch (_: Exception) {
                false
            }
        } else {
            true
        }
        WalkinLog.w(
            context,
            "dwell arm $geofenceId: delay_s=$dwellSeconds exact=$exact recheck=${attempt.isRecheck} next_door=${attempt.isNextDoor} token=${attempt.token}",
        )
        try {
            if (exact) {
                am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            }
        } catch (e: SecurityException) {
            WalkinLog.w(context, "dwell arm $geofenceId: exact permission revoked -> inexact")
            am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
        }
    }

    fun cancel(context: Context, geofenceId: String, token: Long? = null) {
        val existing = getAttemptRaw(context, geofenceId)
        if (token != null && existing != null && existing.token != token) {
            // Token mismatch: does not own this attempt (e.g. replacement attempt exists)
            return
        }
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context, geofenceId, existing?.token ?: 0L))
        markFired(context, geofenceId)
        prefsAttempts(context).edit().remove(geofenceId).apply()
    }

    fun markFired(context: Context, geofenceId: String) {
        prefs(context).edit().remove(geofenceId).apply()
    }

    fun clearAll(context: Context) {
        prefs(context).edit().clear().apply()
        prefsAttempts(context).edit().clear().apply()
    }

    fun cancelAll(context: Context) {
        prefsAttempts(context).all.keys.toList().forEach { cancel(context, it) }
        prefs(context).all.keys.toList().forEach { cancel(context, it) }
    }

    fun geofenceIdFromIntent(intent: Intent): String? =
        intent.action?.takeIf { it.startsWith(ACTION_PREFIX) }
            ?.removePrefix(ACTION_PREFIX)

    fun tokenFromIntent(intent: Intent): Long = intent.getLongExtra(EXTRA_TOKEN, 0L)

    fun isRecheck(intent: Intent): Boolean = intent.getBooleanExtra(EXTRA_RECHECK, false)

    fun isNextDoor(intent: Intent): Boolean = intent.getBooleanExtra(EXTRA_NEXT_DOOR, false)

    private fun saveAttempt(context: Context, attempt: DwellAttempt) {
        prefsAttempts(context).edit().putString(attempt.geofenceId, attempt.toJson()).apply()
    }

    private fun generateToken(): Long {
        val t = rng.nextLong()
        return if (t == 0L) 1L else t
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun prefsAttempts(context: Context) =
        context.getSharedPreferences(PREFS_ATTEMPTS, Context.MODE_PRIVATE)

    private fun pendingIntent(
        context: Context,
        geofenceId: String,
        token: Long,
        recheck: Boolean = false,
        nextDoor: Boolean = false,
    ): PendingIntent {
        val intent = Intent(context, DwellCheckReceiver::class.java).apply {
            action = ACTION_PREFIX + geofenceId
            putExtra(EXTRA_TOKEN, token)
            putExtra(EXTRA_RECHECK, recheck)
            putExtra(EXTRA_NEXT_DOOR, nextDoor)
        }
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
