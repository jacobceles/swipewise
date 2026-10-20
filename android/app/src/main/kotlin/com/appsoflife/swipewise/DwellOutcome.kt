package com.appsoflife.swipewise

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

    /// The fix was inside the fence but the user was still moving (driving or
    /// walking per activity recognition, or the fix's speed): a red light, or
    /// walking past. Re-armed once.
    MOVING_RECHECK("moving_recheck"),

    /// The fix was too coarse to tell stores apart; looked once more.
    COARSE_RECHECK("coarse_recheck"),

    /// Inside the fence, but no store close enough to be the one the user
    /// is in ([StoreResolver.AT_STORE_M]): a red light, a car park, a street.
    NOT_AT_STORE("not_at_store"),

    /// [ResidentGuard]: this fence keeps firing, so the user lives or works
    /// beside it. Suppressed without taking a fix.
    RESIDENT("resident"),

    /// The post was attempted but notifications are off, so nothing showed and
    /// no cooldown or visit lock was set.
    NOTIFICATIONS_OFF("notifications_off"),

    /// Another store alert already posted near here within [VisitLock.WINDOW_MS]
    /// — the same walk-in, seen through an overlapping fence.
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
