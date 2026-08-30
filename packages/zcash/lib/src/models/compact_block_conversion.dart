import 'address.dart';
import 'spend.dart';

class ZcashConvertedBlock {
  final int height;

  final String dataBase64;

  final int transactions;

  final int saplingOutputs;

  final int orchardActions;

  final int ironwoodActions;

  const ZcashConvertedBlock({
    required this.height,
    required this.dataBase64,
    required this.transactions,
    required this.saplingOutputs,
    required this.orchardActions,
    required this.ironwoodActions,
  });

  Map<String, Object?> toScanEntry() => {'height': height, 'data': dataBase64};

  factory ZcashConvertedBlock.fromJson(Map<String, Object?> json) {
    return ZcashConvertedBlock(
      height: _requireInt(json['height'], 'height'),
      dataBase64: _requireString(json['data'], 'data'),
      transactions: _optionalInt(json['transactions']) ?? 0,
      saplingOutputs: _optionalInt(json['sapling_outputs']) ?? 0,
      orchardActions: _optionalInt(json['orchard_actions']) ?? 0,
      ironwoodActions: _optionalInt(json['ironwood_actions']) ?? 0,
    );
  }
}

class ZcashCompactBlockConversion {
  final ZcashAddressNetwork network;

  final List<ZcashConvertedBlock> blocks;

  final int saplingCommitmentTreeSize;

  final int orchardCommitmentTreeSize;

  final int ironwoodCommitmentTreeSize;

  const ZcashCompactBlockConversion({
    required this.network,
    required this.blocks,
    required this.saplingCommitmentTreeSize,
    required this.orchardCommitmentTreeSize,
    required this.ironwoodCommitmentTreeSize,
  });

  List<Map<String, Object?>> toScanEntries() => [
    for (final block in blocks) block.toScanEntry(),
  ];

  factory ZcashCompactBlockConversion.fromJson(Map<String, Object?> json) {
    final raw = json['blocks'];
    if (raw is! List) {
      throw ZcashModelException('compact block conversion is missing blocks');
    }
    return ZcashCompactBlockConversion(
      network: ZcashAddressNetwork.fromJson(
        json['network'] as String? ?? 'mainnet',
      ),
      blocks: [
        for (final entry in raw)
          ZcashConvertedBlock.fromJson(
            entry is Map
                ? entry.cast<String, Object?>()
                : throw ZcashModelException(
                    'each converted block must be an object',
                  ),
          ),
      ],
      saplingCommitmentTreeSize: _requireInt(
        json['sapling_commitment_tree_size'],
        'sapling_commitment_tree_size',
      ),
      orchardCommitmentTreeSize: _requireInt(
        json['orchard_commitment_tree_size'],
        'orchard_commitment_tree_size',
      ),
      ironwoodCommitmentTreeSize: _requireInt(
        json['ironwood_commitment_tree_size'],
        'ironwood_commitment_tree_size',
      ),
    );
  }
}

int _requireInt(Object? value, String field) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException(
    'compact block conversion $field must be an integer',
  );
}

int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw ZcashModelException(
    'compact block conversion contains a non-integer numeric field',
  );
}

String _requireString(Object? value, String field) {
  if (value is String && value.isNotEmpty) return value;
  throw ZcashModelException(
    'compact block conversion $field must be a non-empty string',
  );
}
