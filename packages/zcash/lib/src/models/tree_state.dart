class ShieldedTree {
  final String? finalState;

  const ShieldedTree({this.finalState});

  factory ShieldedTree.fromJson(Map<String, dynamic> json) => ShieldedTree(
    finalState:
        (json['commitments'] as Map<String, dynamic>?)?['finalState']
            as String?,
  );

  @override
  String toString() => 'ShieldedTree(finalState: $finalState)';
}

class TreeState {
  final String hash;
  final int height;
  final int time;
  final ShieldedTree? sapling;
  final ShieldedTree? orchard;

  final ShieldedTree? ironwood;

  const TreeState({
    required this.hash,
    required this.height,
    required this.time,
    this.sapling,
    this.orchard,
    this.ironwood,
  });

  factory TreeState.fromJson(Map<String, dynamic> json) => TreeState(
    hash: json['hash'] as String,
    height: (json['height'] as num).toInt(),
    time: (json['time'] as num).toInt(),
    sapling: json['sapling'] != null
        ? ShieldedTree.fromJson(json['sapling'] as Map<String, dynamic>)
        : null,
    orchard: json['orchard'] != null
        ? ShieldedTree.fromJson(json['orchard'] as Map<String, dynamic>)
        : null,
    ironwood: json['ironwood'] != null
        ? ShieldedTree.fromJson(json['ironwood'] as Map<String, dynamic>)
        : null,
  );

  @override
  String toString() => 'TreeState(hash: $hash, height: $height)';
}

class Subtree {
  final String root;
  final int endHeight;

  const Subtree({required this.root, required this.endHeight});

  factory Subtree.fromJson(Map<String, dynamic> json) => Subtree(
    root: json['root'] as String,
    endHeight: (json['end_height'] as num).toInt(),
  );

  @override
  String toString() => 'Subtree(root: $root, endHeight: $endHeight)';
}

class SubtreeList {
  final String pool;
  final int startIndex;
  final List<Subtree> subtrees;

  const SubtreeList({
    required this.pool,
    required this.startIndex,
    required this.subtrees,
  });

  factory SubtreeList.fromJson(Map<String, dynamic> json) => SubtreeList(
    pool: json['pool'] as String,
    startIndex: (json['start_index'] as num).toInt(),
    subtrees: (json['subtrees'] as List? ?? [])
        .map((e) => Subtree.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  @override
  String toString() =>
      'SubtreeList(pool: $pool, startIndex: $startIndex, count: ${subtrees.length})';
}
