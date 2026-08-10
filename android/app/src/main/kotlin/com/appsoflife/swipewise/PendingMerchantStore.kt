package com.appsoflife.swipewise

/// Holds the option-list JSON parsed from a notification tap intent until
/// the Dart side asks for it via `GeofenceChannel.consumePendingMerchant()`.
/// Single process-wide value — the latest tap wins; consume() clears it.
object PendingMerchantStore {
    private var optionsJson: String? = null

    @Synchronized
    fun set(optionsJsonString: String?) {
        if (optionsJsonString.isNullOrEmpty()) return
        optionsJson = optionsJsonString
    }

    @Synchronized
    fun consume(): String? {
        val v = optionsJson
        optionsJson = null
        return v
    }
}
