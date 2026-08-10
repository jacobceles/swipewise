import 'dart:convert';
import 'package:flutter/services.dart';

class GeofenceChannel {
  static const _channel = MethodChannel('com.appsoflife/geofence');

  /// Each `zone` describes one registered geofence. The `options` list is the
  /// merchants we want to surface for that zone - usually one entry, but
  /// multiple when overlapping merchants were clustered together.
  static Future<int> registerSet({
    required List<Map<String, dynamic>> zones,
    Map<String, dynamic>? boundary,
  }) async {
    final count = await _channel.invokeMethod<int>('registerSet', {
      'zones': zones,
      'boundary': boundary,
    });
    return count ?? 0;
  }

  static Future<void> unregisterAll() async {
    await _channel.invokeMethod('unregisterAll');
  }

  static Future<int> getRegisteredCount() async {
    final c = await _channel.invokeMethod<int>('getRegisteredCount');
    return c ?? 0;
  }

  /// Returns the option list parsed from the notification the user tapped,
  /// or null if none pending. One entry → single merchant; multiple entries
  /// → cluster (open the disambiguation sheet).
  static Future<List<PendingMerchantOption>?> consumePendingMerchant() async {
    final raw = await _channel.invokeMethod<String>('consumePendingMerchant');
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(PendingMerchantOption.fromJson).toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  /// Debug-only: fires a fake dwell notification so we can test the deep
  /// link end-to-end without driving to a real merchant.
  static Future<void> fireTestNotification({
    List<PendingMerchantOption>? options,
  }) {
    return _channel.invokeMethod('fireTestNotification', {
      if (options != null)
        'options': options.map((o) => o.toJson()).toList(growable: false),
    });
  }
}

class PendingMerchantOption {
  final String merchantId;
  final String name;
  final String? category;
  final String? bestCardName;
  final double? bestRate;

  const PendingMerchantOption({
    required this.merchantId,
    required this.name,
    this.category,
    this.bestCardName,
    this.bestRate,
  });

  Map<String, dynamic> toJson() => {
    'merchant_id': merchantId,
    'name': name,
    if (category != null) 'category': category,
    if (bestCardName != null) 'best_card_name': bestCardName,
    if (bestRate != null) 'best_rate': bestRate,
  };

  static PendingMerchantOption fromJson(Map<String, dynamic> j) =>
      PendingMerchantOption(
        merchantId: j['merchant_id'] as String,
        name: j['name'] as String,
        category: j['category'] as String?,
        bestCardName: j['best_card_name'] as String?,
        bestRate: (j['best_rate'] as num?)?.toDouble(),
      );
}
