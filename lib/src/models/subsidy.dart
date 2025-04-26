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
        miner: (json['miner'] as num).toInt(),
        lockbox:
            json['lockbox'] != null ? (json['lockbox'] as num).toInt() : null,
        fundingStreams: (json['fundingstreams'] as List? ?? [])
            .map((e) => FundingStream.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  String toString() =>
      'BlockSubsidy(miner: $miner, lockbox: $lockbox, streams: ${fundingStreams.length})';
}
