class BlockInfo {
  final String hash;
  final int confirmations;
  final int? height;
  final int? time;
  final List<String> transactions;

  const BlockInfo({
    required this.hash,
    required this.confirmations,
    this.height,
    this.time,
    required this.transactions,
  });

  factory BlockInfo.fromJson(Map<String, dynamic> json) => BlockInfo(
    hash: json['hash'] as String,
    confirmations: (json['confirmations'] as num).toInt(),
    height: json['height'] != null ? (json['height'] as num).toInt() : null,
    time: json['time'] != null ? (json['time'] as num).toInt() : null,
    transactions: (json['tx'] as List? ?? []).cast<String>(),
  );

  @override
  String toString() =>
      'BlockInfo(hash: $hash, height: $height, '
      'txCount: ${transactions.length})';
}

class BlockInfoFull {
  final String hash;
  final int confirmations;
  final int? height;
  final int? time;
  final List<Map<String, dynamic>> transactions;

  const BlockInfoFull({
    required this.hash,
    required this.confirmations,
    this.height,
    this.time,
    required this.transactions,
  });

  factory BlockInfoFull.fromJson(Map<String, dynamic> json) => BlockInfoFull(
    hash: json['hash'] as String,
    confirmations: (json['confirmations'] as num).toInt(),
    height: json['height'] != null ? (json['height'] as num).toInt() : null,
    time: json['time'] != null ? (json['time'] as num).toInt() : null,
    transactions: (json['tx'] as List? ?? []).cast<Map<String, dynamic>>(),
  );

  @override
  String toString() =>
      'BlockInfoFull(hash: $hash, height: $height, '
      'txCount: ${transactions.length})';
}
