class Transaction {
  final String id;
  final String? postedAt;
  final String? name;
  final String? merchant;
  final String? category;
  final String? categoryId;
  final String? type;
  final double? amount;
  final String? currency;
  final String? card;
  final String? cardId;
  final String? cardLastFour;
  final String? status;
  // Live display name resolved at query time via `queryTransactions`'s
  // LEFT JOIN onto `cards`/`card_overrides`. Prefer this over `card`
  // when rendering - it follows renames immediately, without needing
  // sync to propagate. Falls back to the sync-time snapshot `card` for
  // orphaned rows whose `cards` row no longer exists.
  final String? cardDisplay;

  Transaction({
    required this.id,
    this.postedAt,
    this.name,
    this.merchant,
    this.category,
    this.categoryId,
    this.type,
    this.amount,
    this.currency,
    this.card,
    this.cardId,
    this.cardLastFour,
    this.status,
    this.cardDisplay,
  });

  bool get isPending => status != null && status!.toUpperCase() == 'PENDING';

  /// Best display label for the card this transaction belongs to.
  /// Honors a live rename via the JOIN, then falls back to the
  /// sync-time `card` snapshot.
  String? get cardLabel => cardDisplay ?? card;

  factory Transaction.fromJson(Map<String, dynamic> json) {
    return Transaction(
      id: json['id'],
      postedAt: json['posted_at'],
      name: json['name'],
      merchant: json['merchant'],
      category: json['category'],
      categoryId: json['category_id'],
      type: json['type'],
      amount: (json['amount'] as num?)?.toDouble(),
      currency: json['currency'],
      card: json['card'],
      cardId: json['card_id'],
      cardLastFour: json['card_last_four'],
      status: json['status'],
      cardDisplay: json['card_display'],
    );
  }
}

class TransactionResponse {
  final List<Transaction> transactions;
  final int page;
  final int pages;
  final int total;

  TransactionResponse({
    required this.transactions,
    required this.page,
    required this.pages,
    required this.total,
  });
}
