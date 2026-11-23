/// Data shapes returned by the ReceiptLens API (see api/app/main.py).
class Receipt {
  Receipt({
    required this.id,
    required this.status,
    required this.createdAt,
    this.merchant,
    this.totalVnd,
    this.purchasedAt,
    this.confidence,
    this.rawText,
  });

  final String id;
  final String status; // uploaded | parsed | failed | corrected
  final String? merchant;
  final int? totalVnd;
  final DateTime? purchasedAt;
  final DateTime createdAt;
  final double? confidence;
  final String? rawText; // only on the detail endpoint

  bool get isReading => status == 'uploaded';

  factory Receipt.fromJson(Map<String, dynamic> j) => Receipt(
    id: j['id'] as String,
    status: j['status'] as String,
    merchant: j['merchant'] as String?,
    totalVnd: (j['total_vnd'] as num?)?.toInt(),
    purchasedAt: j['purchased_at'] == null ? null : DateTime.parse(j['purchased_at'] as String),
    createdAt: DateTime.parse(j['created_at'] as String),
    confidence: (j['confidence'] as num?)?.toDouble(),
    rawText: j['raw_text'] as String?,
  );
}

class MonthStat {
  MonthStat({required this.month, required this.count, required this.totalVnd});

  final String month; // YYYY-MM
  final int count;
  final int totalVnd;

  factory MonthStat.fromJson(Map<String, dynamic> j) =>
      MonthStat(month: j['month'] as String, count: j['count'] as int, totalVnd: (j['total_vnd'] as num).toInt());
}

/// Receipts are in Vietnam time; the API returns UTC. Shift explicitly instead of trusting the phone's zone.
DateTime toVietnamTime(DateTime t) => t.toUtc().add(const Duration(hours: 7));
