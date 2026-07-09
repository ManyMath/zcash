import 'address.dart';

class ZcashAccountReceiverSet {
  final bool orchard;
  final bool sapling;
  final bool transparent;
  final bool p2pkh;
  final bool p2sh;
  final int unknown;
  final int total;

  const ZcashAccountReceiverSet({
    required this.orchard,
    required this.sapling,
    required this.transparent,
    required this.p2pkh,
    required this.p2sh,
    required this.unknown,
    required this.total,
  });

  factory ZcashAccountReceiverSet.fromJson(Map<String, dynamic> json) =>
      ZcashAccountReceiverSet(
        orchard: json['orchard'] as bool? ?? false,
        sapling: json['sapling'] as bool? ?? false,
        transparent: json['transparent'] as bool? ?? false,
        p2pkh: json['p2pkh'] as bool? ?? false,
        p2sh: json['p2sh'] as bool? ?? false,
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

class ZcashAccountReceiverKind {
  final ZcashAddressReceiverType kind;
  final ZcashAddressPool pool;

  const ZcashAccountReceiverKind({required this.kind, required this.pool});

  factory ZcashAccountReceiverKind.fromJson(Map<String, dynamic> json) =>
      ZcashAccountReceiverKind(
        kind: ZcashAddressReceiverType.fromJson(json['kind'] as String),
        pool: ZcashAddressPool.fromJson(json['pool'] as String),
      );

  Map<String, Object?> toJson() => {'kind': kind.name, 'pool': pool.name};
}

class ZcashAccountMetadata {
  final ZcashAddressNetwork network;
  final int accountIndex;
  final String ufvk;
  final String? transparentAccountXpub;
  final ZcashAccountReceiverSet receivers;
  final List<ZcashAccountReceiverKind> receiverKinds;

  const ZcashAccountMetadata({
    required this.network,
    required this.accountIndex,
    required this.ufvk,
    required this.transparentAccountXpub,
    required this.receivers,
    required this.receiverKinds,
  });

  bool get hasOrchard => receivers.orchard;
  bool get hasSapling => receivers.sapling;
  bool get hasTransparent => receivers.transparent;

  factory ZcashAccountMetadata.fromJson(Map<String, dynamic> json) {
    final receivers = json['receivers'];
    if (receivers is! Map) {
      throw const FormatException('Account metadata missing receivers object');
    }
    final receiverKinds = json['receiver_kinds'];
    if (receiverKinds is! List) {
      throw const FormatException(
        'Account metadata missing receiver kinds list',
      );
    }

    return ZcashAccountMetadata(
      network: ZcashAddressNetwork.fromJson(json['network'] as String),
      accountIndex: (json['account_index'] as num).toInt(),
      ufvk: json['ufvk'] as String,
      transparentAccountXpub: json['transparent_account_xpub'] as String?,
      receivers: ZcashAccountReceiverSet.fromJson(
        receivers.cast<String, dynamic>(),
      ),
      receiverKinds: receiverKinds
          .map(
            (receiver) => ZcashAccountReceiverKind.fromJson(
              (receiver as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    'network': network.name,
    'account_index': accountIndex,
    'ufvk': ufvk,
    'transparent_account_xpub': transparentAccountXpub,
    'receivers': receivers.toJson(),
    'receiver_kinds': receiverKinds
        .map((receiver) => receiver.toJson())
        .toList(growable: false),
  };
}
