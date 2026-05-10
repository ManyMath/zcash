class FundingStream {
  final String recipient;
  final int valueZat;

  const FundingStream({required this.recipient, required this.valueZat});

  factory FundingStream.fromJson(Map<String, dynamic> json) => FundingStream(
    recipient: json['recipient'] as String,
    valueZat: (json['valueZat'] as num).toInt(),
  );

  @override
  String toString() => 'FundingStream($recipient: $valueZat zat)';
}

class BlockSubsidy {
  final int miner;
  final int? lockbox;
  final List<FundingStream> fundingStreams;

  const BlockSubsidy({
    required this.miner,
    this.lockbox,
    required this.fundingStreams,
  });

  factory BlockSubsidy.fromJson(Map<String, dynamic> json) => BlockSubsidy(
    miner: json['miner'] is int
        ? json['miner'] as int
        : ((json['miner'] as num) * 1e8).round(),
    lockbox: json['lockbox'] != null
        ? (json['lockbox'] is int
              ? json['lockbox'] as int
              : ((json['lockbox'] as num) * 1e8).round())
        : null,
    fundingStreams: (json['fundingstreams'] as List? ?? [])
        .map((e) => FundingStream.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  @override
  String toString() =>
      'BlockSubsidy(miner: $miner, lockbox: $lockbox, streams: ${fundingStreams.length})';
}
