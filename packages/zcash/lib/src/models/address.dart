class AddressBalance {
  final int zatoshis;
  final int? received;

  const AddressBalance({required this.zatoshis, this.received});

  factory AddressBalance.fromJson(Map<String, dynamic> json) => AddressBalance(
        zatoshis: (json['balance'] as num).toInt(),
        received:
            json['received'] != null ? (json['received'] as num).toInt() : null,
      );

  double get zec => zatoshis / 1e8;

  @override
  String toString() => 'AddressBalance($zatoshis zatoshis / $zec ZEC)';
}

class AddressUtxo {
  final String address;
  final String txid;
  final int outputIndex;
  final String script;
  final int satoshis;
  final int height;

  const AddressUtxo({
    required this.address,
    required this.txid,
    required this.outputIndex,
    required this.script,
    required this.satoshis,
    required this.height,
  });

  factory AddressUtxo.fromJson(Map<String, dynamic> json) => AddressUtxo(
        address: json['address'] as String,
        txid: json['txid'] as String,
        outputIndex: (json['outputIndex'] as num).toInt(),
        script: json['script'] as String,
        satoshis: (json['satoshis'] as num).toInt(),
        height: (json['height'] as num).toInt(),
      );

  double get zec => satoshis / 1e8;

  @override
  String toString() =>
      'AddressUtxo(txid: $txid, index: $outputIndex, $satoshis zatoshis)';
}
