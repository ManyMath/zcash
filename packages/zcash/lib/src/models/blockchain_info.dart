class NodeInfo {
  final String build;
  final String subversion;

  const NodeInfo({required this.build, required this.subversion});

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
        build: json['build'] as String,
        subversion: json['subversion'] as String,
      );

  @override
  String toString() => 'NodeInfo(build: $build, subversion: $subversion)';
}

class NetworkUpgrade {
  final String name;
  final int activationHeight;
  final String status;

  const NetworkUpgrade({
    required this.name,
    required this.activationHeight,
    required this.status,
  });

  factory NetworkUpgrade.fromJson(Map<String, dynamic> json) => NetworkUpgrade(
        name: json['name'] as String,
        activationHeight: (json['activationheight'] as num).toInt(),
        status: json['status'] as String,
      );

  @override
  String toString() =>
      'NetworkUpgrade(name: $name, height: $activationHeight, status: $status)';
}

// 'lockbox' replaced 'deferred' after NU6.1.
class ValuePool {
  final String id;
  final int? chainValue;

  const ValuePool({required this.id, this.chainValue});

  factory ValuePool.fromJson(Map<String, dynamic> json) => ValuePool(
        id: json['id'] as String,
        chainValue: json['chainValue'] != null
            ? (json['chainValue'] as num).toInt()
            : null,
      );

  @override
  String toString() => 'ValuePool(id: $id, chainValue: $chainValue)';
}

class BlockchainInfo {
  final String chain;
  final int blocks;
  final String bestBlockHash;
  final int estimatedHeight;
  final Map<String, NetworkUpgrade> upgrades;
  final List<ValuePool> valuePools;

  const BlockchainInfo({
    required this.chain,
    required this.blocks,
    required this.bestBlockHash,
    required this.estimatedHeight,
    required this.upgrades,
    this.valuePools = const [],
  });

  factory BlockchainInfo.fromJson(Map<String, dynamic> json) => BlockchainInfo(
        chain: json['chain'] as String,
        blocks: (json['blocks'] as num).toInt(),
        bestBlockHash: json['bestblockhash'] as String,
        estimatedHeight: (json['estimatedheight'] as num).toInt(),
        upgrades: (json['upgrades'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(
            k,
            NetworkUpgrade.fromJson(v as Map<String, dynamic>),
          ),
        ),
        valuePools: (json['valuePools'] as List? ?? [])
            .map((e) => ValuePool.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  String toString() =>
      'BlockchainInfo(chain: $chain, blocks: $blocks, tip: $bestBlockHash)';
}

class BlockHeightAndHash {
  final int height;
  final String hash;

  const BlockHeightAndHash({required this.height, required this.hash});

  factory BlockHeightAndHash.fromJson(Map<String, dynamic> json) =>
      BlockHeightAndHash(
        height: (json['height'] as num).toInt(),
        hash: json['hash'] is List
            ? (json['hash'] as List<dynamic>)
                  .reversed
                  .map((b) => (b as int).toRadixString(16).padLeft(2, '0'))
                  .join()
            : json['hash'] as String,
      );

  @override
  String toString() => 'BlockHeightAndHash(height: $height, hash: $hash)';
}
