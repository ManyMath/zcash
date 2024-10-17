class TransactionInfo {
  final String txid;
  final String hex;
  final int? height;
  final String? blockHash;
  final int? confirmations;
  final int? time;

  const TransactionInfo({
    required this.txid,
    required this.hex,
    this.height,
    this.blockHash,
    this.confirmations,
    this.time,
  });

  factory TransactionInfo.fromJson(Map<String, dynamic> json) =>
      TransactionInfo(
        txid: json['txid'] as String,
        hex: json['hex'] as String,
        height:
            json['height'] != null ? (json['height'] as num).toInt() : null,
        blockHash: json['blockhash'] as String?,
        confirmations: json['confirmations'] != null
            ? (json['confirmations'] as num).toInt()
            : null,
        time: json['time'] != null ? (json['time'] as num).toInt() : null,
      );

  bool get isMined => blockHash != null;

  @override
  String toString() => 'TransactionInfo(txid: $txid, height: $height, '
      'confirmations: $confirmations)';
}
