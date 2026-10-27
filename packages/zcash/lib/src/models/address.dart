enum ZcashAddressNetwork {
  mainnet,
  testnet,
  regtest;

  factory ZcashAddressNetwork.fromJson(String value) => switch (value) {
    'mainnet' || 'main' => ZcashAddressNetwork.mainnet,
    'testnet' || 'test' => ZcashAddressNetwork.testnet,
    'regtest' => ZcashAddressNetwork.regtest,
    _ => throw FormatException('Unknown Zcash address network: $value'),
  };
}

enum ZcashAddressReceiverType {
  unknown,
  sprout,
  p2pkh,
  p2sh,
  tex,
  sapling,
  orchard,
  unified;

  factory ZcashAddressReceiverType.fromJson(String value) => switch (value) {
    'unknown' => ZcashAddressReceiverType.unknown,
    'sprout' => ZcashAddressReceiverType.sprout,
    'p2pkh' => ZcashAddressReceiverType.p2pkh,
    'p2sh' => ZcashAddressReceiverType.p2sh,
    'tex' => ZcashAddressReceiverType.tex,
    'sapling' => ZcashAddressReceiverType.sapling,
    'orchard' => ZcashAddressReceiverType.orchard,
    'unified' => ZcashAddressReceiverType.unified,
    _ => throw FormatException('Unknown Zcash address receiver type: $value'),
  };
}

enum ZcashAddressPool {
  unknown,
  sprout,
  transparent,
  sapling,
  orchard,
  mixed;

  factory ZcashAddressPool.fromJson(String value) => switch (value) {
    'unknown' => ZcashAddressPool.unknown,
    'sprout' => ZcashAddressPool.sprout,
    'transparent' => ZcashAddressPool.transparent,
    'sapling' => ZcashAddressPool.sapling,
    'orchard' => ZcashAddressPool.orchard,
    'mixed' => ZcashAddressPool.mixed,
    _ => throw FormatException('Unknown Zcash address pool: $value'),
  };
}

enum ZcashTransparentClassificationInput {
  address,
  script;

  factory ZcashTransparentClassificationInput.fromJson(String value) =>
      switch (value) {
        'address' => ZcashTransparentClassificationInput.address,
        'script' => ZcashTransparentClassificationInput.script,
        _ => throw FormatException(
          'Unknown transparent classification input: $value',
        ),
      };
}

enum ZcashTransparentClassificationKind {
  p2pkh,
  p2sh,
  nonStandard;

  factory ZcashTransparentClassificationKind.fromJson(String value) =>
      switch (value) {
        'p2pkh' => ZcashTransparentClassificationKind.p2pkh,
        'p2sh' => ZcashTransparentClassificationKind.p2sh,
        'non_standard' => ZcashTransparentClassificationKind.nonStandard,
        _ => throw FormatException(
          'Unknown transparent classification kind: $value',
        ),
      };

  String get jsonName => switch (this) {
    ZcashTransparentClassificationKind.p2pkh => 'p2pkh',
    ZcashTransparentClassificationKind.p2sh => 'p2sh',
    ZcashTransparentClassificationKind.nonStandard => 'non_standard',
  };
}

class ZcashTransparentClassification {
  final ZcashAddressNetwork? network;
  final ZcashTransparentClassificationInput inputType;
  final ZcashTransparentClassificationKind kind;
  final ZcashAddressPool pool;
  final bool standard;
  final bool transparent;
  final int scriptSize;

  const ZcashTransparentClassification({
    required this.network,
    required this.inputType,
    required this.kind,
    required this.pool,
    required this.standard,
    required this.transparent,
    required this.scriptSize,
  });

  factory ZcashTransparentClassification.fromJson(Map<String, dynamic> json) =>
      ZcashTransparentClassification(
        network: switch (json['network']) {
          final String value => ZcashAddressNetwork.fromJson(value),
          null => null,
          _ => throw const FormatException(
            'Transparent classification network must be a string',
          ),
        },
        inputType: ZcashTransparentClassificationInput.fromJson(
          json['input_type'] as String,
        ),
        kind: ZcashTransparentClassificationKind.fromJson(
          json['kind'] as String,
        ),
        pool: ZcashAddressPool.fromJson(json['pool'] as String),
        standard: json['standard'] as bool,
        transparent: json['transparent'] as bool,
        scriptSize: (json['script_size'] as num).toInt(),
      );

  Map<String, Object?> toJson() => {
    if (network != null) 'network': network!.name,
    'input_type': inputType.name,
    'kind': kind.jsonName,
    'pool': pool.name,
    'standard': standard,
    'transparent': transparent,
    'script_size': scriptSize,
  };
}

class ZcashAddressReceiverPresence {
  final bool sprout;
  final bool orchard;
  final bool sapling;
  final bool transparent;
  final String? transparentKind;
  final int unknown;
  final int total;

  const ZcashAddressReceiverPresence({
    required this.sprout,
    required this.orchard,
    required this.sapling,
    required this.transparent,
    this.transparentKind,
    required this.unknown,
    required this.total,
  });

  factory ZcashAddressReceiverPresence.fromJson(Map<String, dynamic> json) =>
      ZcashAddressReceiverPresence(
        sprout: json['sprout'] as bool? ?? false,
        orchard: json['orchard'] as bool? ?? false,
        sapling: json['sapling'] as bool? ?? false,
        transparent: json['transparent'] as bool? ?? false,
        transparentKind: json['transparent_kind'] as String?,
        unknown: (json['unknown'] as num? ?? 0).toInt(),
        total: (json['total'] as num? ?? 0).toInt(),
      );

  Map<String, Object?> toJson() => {
    'sprout': sprout,
    'orchard': orchard,
    'sapling': sapling,
    'transparent': transparent,
    'transparent_kind': transparentKind,
    'unknown': unknown,
    'total': total,
  };
}

class ZcashAddressMetadata {
  final ZcashAddressNetwork network;
  final ZcashAddressReceiverType receiverType;
  final ZcashAddressPool pool;
  final ZcashAddressReceiverPresence receivers;

  /// `r0` or `r2` for a Unified Address, otherwise null.
  final String? unifiedRevision;

  /// ZIP 316 Revision 2 expiry; the native builders refuse to pay past it.
  final int? expiryHeight;

  /// Unix seconds.
  final int? expiryTime;

  const ZcashAddressMetadata({
    required this.network,
    required this.receiverType,
    required this.pool,
    required this.receivers,
    this.unifiedRevision,
    this.expiryHeight,
    this.expiryTime,
  });

  factory ZcashAddressMetadata.fromJson(Map<String, dynamic> json) {
    final receivers = json['receivers'];
    if (receivers is! Map) {
      throw const FormatException('Address metadata missing receivers object');
    }

    return ZcashAddressMetadata(
      network: ZcashAddressNetwork.fromJson(json['network'] as String),
      receiverType: ZcashAddressReceiverType.fromJson(
        json['receiver_type'] as String,
      ),
      pool: ZcashAddressPool.fromJson(json['pool'] as String),
      receivers: ZcashAddressReceiverPresence.fromJson(
        receivers.cast<String, dynamic>(),
      ),
      unifiedRevision: json['unified_revision'] as String?,
      expiryHeight: (json['expiry_height'] as num?)?.toInt(),
      expiryTime: (json['expiry_time'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'network': network.name,
    'receiver_type': receiverType.name,
    'pool': pool.name,
    'receivers': receivers.toJson(),
    'unified_revision': unifiedRevision,
    'expiry_height': expiryHeight,
    'expiry_time': expiryTime,
  };
}

class ZcashUnifiedAddressReceiver {
  final int index;
  final ZcashAddressReceiverType kind;
  final ZcashAddressPool pool;

  const ZcashUnifiedAddressReceiver({
    required this.index,
    required this.kind,
    required this.pool,
  });

  factory ZcashUnifiedAddressReceiver.fromJson(Map<String, dynamic> json) =>
      ZcashUnifiedAddressReceiver(
        index: (json['index'] as num).toInt(),
        kind: ZcashAddressReceiverType.fromJson(json['kind'] as String),
        pool: ZcashAddressPool.fromJson(json['pool'] as String),
      );

  Map<String, Object?> toJson() => {
    'index': index,
    'kind': kind.name,
    'pool': pool.name,
  };
}

class ZcashUnifiedAddressReceiverCounts {
  final int orchard;
  final int sapling;
  final int transparent;
  final int p2pkh;
  final int p2sh;
  final int unknown;
  final int total;

  const ZcashUnifiedAddressReceiverCounts({
    required this.orchard,
    required this.sapling,
    required this.transparent,
    required this.p2pkh,
    required this.p2sh,
    required this.unknown,
    required this.total,
  });

  factory ZcashUnifiedAddressReceiverCounts.fromJson(
    Map<String, dynamic> json,
  ) => ZcashUnifiedAddressReceiverCounts(
    orchard: (json['orchard'] as num? ?? 0).toInt(),
    sapling: (json['sapling'] as num? ?? 0).toInt(),
    transparent: (json['transparent'] as num? ?? 0).toInt(),
    p2pkh: (json['p2pkh'] as num? ?? 0).toInt(),
    p2sh: (json['p2sh'] as num? ?? 0).toInt(),
    unknown: (json['unknown'] as num? ?? 0).toInt(),
    total: (json['total'] as num? ?? 0).toInt(),
  );

  Map<String, Object?> toJson() => {
    'orchard': orchard,
    'sapling': sapling,
    'transparent': transparent,
    'p2pkh': p2pkh,
    'p2sh': p2sh,
    'unknown': unknown,
    'total': total,
  };
}

class ZcashUnifiedAddressReceiverInventory {
  final ZcashAddressNetwork network;
  final List<ZcashUnifiedAddressReceiver> receivers;
  final ZcashUnifiedAddressReceiverCounts counts;

  /// `r0` or `r2`.
  final String? unifiedRevision;

  final int? expiryHeight;

  /// Unix seconds.
  final int? expiryTime;

  const ZcashUnifiedAddressReceiverInventory({
    required this.network,
    required this.receivers,
    required this.counts,
    this.unifiedRevision,
    this.expiryHeight,
    this.expiryTime,
  });

  int get receiverCount => receivers.length;

  bool get hasOrchard => counts.orchard > 0;
  bool get hasSapling => counts.sapling > 0;
  bool get hasTransparent => counts.transparent > 0;

  factory ZcashUnifiedAddressReceiverInventory.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawReceivers = json['receivers'];
    if (rawReceivers is! List) {
      throw const FormatException(
        'Unified address inventory missing receivers array',
      );
    }
    final rawCounts = json['counts'];
    if (rawCounts is! Map) {
      throw const FormatException(
        'Unified address inventory missing counts object',
      );
    }

    return ZcashUnifiedAddressReceiverInventory(
      network: ZcashAddressNetwork.fromJson(json['network'] as String),
      receivers: rawReceivers
          .map(
            (receiver) => ZcashUnifiedAddressReceiver.fromJson(
              (receiver as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
      counts: ZcashUnifiedAddressReceiverCounts.fromJson(
        rawCounts.cast<String, dynamic>(),
      ),
      unifiedRevision: json['unified_revision'] as String?,
      expiryHeight: (json['expiry_height'] as num?)?.toInt(),
      expiryTime: (json['expiry_time'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'network': network.name,
    'address_type': 'unified',
    'receiver_count': receiverCount,
    'receivers': receivers.map((receiver) => receiver.toJson()).toList(),
    'counts': counts.toJson(),
    'unified_revision': unifiedRevision,
    'expiry_height': expiryHeight,
    'expiry_time': expiryTime,
  };
}

class ZcashDiversifiedAddressSet {
  final String ua;
  final String? saplingAddress;
  final String? orchardAddress;
  final String? transparentAddress;

  const ZcashDiversifiedAddressSet({
    required this.ua,
    required this.saplingAddress,
    required this.orchardAddress,
    required this.transparentAddress,
  });

  factory ZcashDiversifiedAddressSet.fromJson(Map<String, dynamic> json) =>
      ZcashDiversifiedAddressSet(
        ua: json['ua'] as String,
        saplingAddress: json['sapling'] as String?,
        orchardAddress: json['orchard'] as String?,
        transparentAddress: json['transparent'] as String?,
      );

  Map<String, Object?> toJson() => {
    'ua': ua,
    'sapling': saplingAddress,
    'orchard': orchardAddress,
    'transparent': transparentAddress,
  };
}

class ZcashDiversifierReceiverPresence {
  final bool orchard;
  final bool sapling;
  final bool transparent;
  final String? transparentKind;
  final int total;

  const ZcashDiversifierReceiverPresence({
    required this.orchard,
    required this.sapling,
    required this.transparent,
    required this.transparentKind,
    required this.total,
  });

  factory ZcashDiversifierReceiverPresence.fromJson(
    Map<String, dynamic> json,
  ) => ZcashDiversifierReceiverPresence(
    orchard: json['orchard'] as bool? ?? false,
    sapling: json['sapling'] as bool? ?? false,
    transparent: json['transparent'] as bool? ?? false,
    transparentKind: json['transparent_kind'] as String?,
    total: (json['total'] as num? ?? 0).toInt(),
  );

  Map<String, Object?> toJson() => {
    'orchard': orchard,
    'sapling': sapling,
    'transparent': transparent,
    'transparent_kind': transparentKind,
    'total': total,
  };
}

class ZcashDiversifierSearchResult {
  final int requestedIndex;
  final int nextValidIndex;
  final int skippedCount;
  final ZcashDiversifierReceiverPresence receiverPresence;
  final ZcashDiversifiedAddressSet addresses;

  final String? addressEncoding;

  const ZcashDiversifierSearchResult({
    required this.requestedIndex,
    required this.nextValidIndex,
    required this.skippedCount,
    required this.receiverPresence,
    required this.addresses,
    this.addressEncoding,
  });

  factory ZcashDiversifierSearchResult.fromJson(Map<String, dynamic> json) {
    final presence = json['receiver_presence'];
    if (presence is! Map) {
      throw const FormatException(
        'Diversifier search result missing receiver presence object',
      );
    }
    final addresses = json['addresses'];
    if (addresses is! Map) {
      throw const FormatException(
        'Diversifier search result missing addresses object',
      );
    }

    return ZcashDiversifierSearchResult(
      requestedIndex: (json['requested_index'] as num).toInt(),
      nextValidIndex: (json['next_valid_index'] as num).toInt(),
      skippedCount: (json['skipped_count'] as num? ?? 0).toInt(),
      receiverPresence: ZcashDiversifierReceiverPresence.fromJson(
        presence.cast<String, dynamic>(),
      ),
      addresses: ZcashDiversifiedAddressSet.fromJson(
        addresses.cast<String, dynamic>(),
      ),
      addressEncoding: json['address_encoding'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'requested_index': requestedIndex,
    'next_valid_index': nextValidIndex,
    'skipped_count': skippedCount,
    'receiver_presence': receiverPresence.toJson(),
    'addresses': addresses.toJson(),
    'address_encoding': addressEncoding,
  };
}

class AddressBalance {
  final int zatoshis;
  final int? received;

  const AddressBalance({required this.zatoshis, this.received});

  factory AddressBalance.fromJson(Map<String, dynamic> json) => AddressBalance(
    zatoshis: (json['balance'] as num).toInt(),
    received: json['received'] != null
        ? (json['received'] as num).toInt()
        : null,
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
