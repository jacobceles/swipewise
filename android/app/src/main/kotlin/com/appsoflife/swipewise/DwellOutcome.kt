package com.appsoflife.swipewise

/// Why a dwell check did or did not submit an arrival notification to Android.
enum class DwellOutcome(val wire: String) {
    POSTED("posted"), // Submission is not proof that the user saw/heard it.

    /// Fence set was replaced while this timer was in flight, so the metadata it
    /// needed is gone. Expected occasionally (a re-register lands mid-dwell);
    /// frequent means the AR-settle re-register is racing arrivals.
    NO_META("no_meta"),

    /// The verification fix put the user outside the fence. The prime suspect for
    /// eaten visits: the fix is BALANCED-power and taken indoors, and rural fences
    /// often sit on a business's registered address rather than its storefront.
    OUTSIDE_FENCE("outside_fence"),

    /// No fix obtainable in time; distinct fail-closed reasons.
    NO_FIX_TIMEOUT("no_fix_timeout"),
    NO_FIX_NULL("no_fix_null"),
    NO_FIX_ERROR("no_fix_error"),
    NO_FIX_SECURITY("no_fix_security"),

    /// Fix coordinates, accuracy, or timestamps were invalid, non-finite, or negative.
    INVALID_FIX("invalid_fix"),

    /// Fix was older than the freshness threshold or from the future.
    STALE_FIX("stale_fix"),

    MUTED("muted"),
    MERCHANT_COOLDOWN("merchant_cooldown"),

    /// The fix was inside the fence but the user was still moving (driving or
    /// walking per activity recognition, or the fix's speed): a red light, or
    /// walking past. Re-armed once.
    MOVING_RECHECK("moving_recheck"),

    /// The fix was too coarse to tell stores apart; looked once more.
    COARSE_RECHECK("coarse_recheck"),

    /// Inside the fence, but no store close enough to be the one the user
    /// is in ([StoreResolver.AT_STORE_M]): a red light, a car park, a street.
    NOT_AT_STORE("not_at_store"),

    /// The post was attempted but notifications are off, so nothing showed and
    /// no cooldown or visit lock was set.
    NOTIFICATIONS_OFF("notifications_off"),

    /// The same inferred stay, including overlapping fences and quiet long visits.
    SAME_VISIT("same_visit"),
}

/// The verification fix, kept together so an [DwellOutcome.OUTSIDE_FENCE] log line
/// can be re-judged after the fact: `distanceM <= allowedM` is the exact comparison
/// the receiver made, and `accuracyM` says how much of `allowedM` was slack the
/// fix itself bought.
data class DwellFix(
    val distanceM: Float,
    val accuracyM: Float,
    val allowedM: Float,
)
