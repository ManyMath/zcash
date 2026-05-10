class BlockHeader {
  final String hash;
  final int confirmations;
  final int height;
  final int version;
  final String merkleRoot;
  final int time;
  final String nonce;
  final String bits;
  final String? previousBlockHash;
  final String? nextBlockHash;

  const BlockHeader({
    required this.hash,
    required this.confirmations,
    required this.height,
    required this.version,
    required this.merkleRoot,
    required this.time,
    required this.nonce,
    required this.bits,
    this.previousBlockHash,
    this.nextBlockHash,
  });

  factory BlockHeader.fromJson(Map<String, dynamic> json) => BlockHeader(
    hash: json['hash'] as String,
    confirmations: (json['confirmations'] as num).toInt(),
    height: (json['height'] as num).toInt(),
    version: (json['version'] as num).toInt(),
    merkleRoot: json['merkleroot'] as String,
    time: (json['time'] as num).toInt(),
    nonce: json['nonce'] as String,
    bits: json['bits'] as String,
    previousBlockHash: json['previousblockhash'] as String?,
    nextBlockHash: json['nextblockhash'] as String?,
  );

  @override
  String toString() => 'BlockHeader(hash: $hash, height: $height, time: $time)';
}
