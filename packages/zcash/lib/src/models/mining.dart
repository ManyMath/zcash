class BlockTemplate {
  final int version;
  final String previousBlockHash;
  final List<Map<String, dynamic>> transactions;
  final Map<String, dynamic>? coinbaseTxn;
  final int? coinbaseValue;
  final String target;
  final int minTime;
  final int? curTime;
  final String bits;
  final int height;

  final String? blockCommitmentsHash;

  final String? defaultMerkleRoot;

  const BlockTemplate({
    required this.version,
    required this.previousBlockHash,
    required this.transactions,
    this.coinbaseTxn,
    this.coinbaseValue,
    required this.target,
    required this.minTime,
    this.curTime,
    required this.bits,
    required this.height,
    this.blockCommitmentsHash,
    this.defaultMerkleRoot,
  });

  factory BlockTemplate.fromJson(Map<String, dynamic> json) {
    final defaultRoots = json['defaultroots'] as Map<String, dynamic>?;
    return BlockTemplate(
      version: (json['version'] as num).toInt(),
      previousBlockHash: json['previousblockhash'] as String,
      transactions: (json['transactions'] as List).cast<Map<String, dynamic>>(),
      coinbaseTxn: json['coinbasetxn'] as Map<String, dynamic>?,
      coinbaseValue: json['coinbasevalue'] != null
          ? (json['coinbasevalue'] as num).toInt()
          : null,
      target: json['target'] as String,
      minTime: (json['mintime'] as num).toInt(),
      curTime: json['curtime'] != null
          ? (json['curtime'] as num).toInt()
          : null,
      bits: json['bits'] as String,
      height: (json['height'] as num).toInt(),
      blockCommitmentsHash:
          (json['blockcommitmentshash'] ??
                  json['lightclientroothash'] ??
                  json['finalsaplingroothash'])
              as String?,
      defaultMerkleRoot: defaultRoots?['merkleroot'] as String?,
    );
  }

  @override
  String toString() =>
      'BlockTemplate(height: $height, target: $target, txs: ${transactions.length})';
}

class AddressMempoolEntry {
  final String txid;
  final int index;
  final int satoshis;
  final String script;
  final String address;

  const AddressMempoolEntry({
    required this.txid,
    required this.index,
    required this.satoshis,
    required this.script,
    required this.address,
  });

  factory AddressMempoolEntry.fromJson(Map<String, dynamic> json) =>
      AddressMempoolEntry(
        txid: json['txid'] as String,
        index: (json['index'] as num).toInt(),
        satoshis: (json['satoshis'] as num).toInt(),
        script: json['script'] as String,
        address: json['address'] as String,
      );

  @override
  String toString() =>
      'AddressMempoolEntry(txid: $txid, index: $index, $satoshis zatoshis)';
}
