import 'dart:convert';
import 'dart:typed_data';

class CompactBlockScanInput {
  CompactBlockScanInput({required List<int> bytes, this.height})
    : bytes = Uint8List.fromList(bytes);

  factory CompactBlockScanInput.fromBytes(List<int> bytes, {int? height}) =>
      CompactBlockScanInput(bytes: bytes, height: height);

  final Uint8List bytes;
  final int? height;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{'data': base64Encode(bytes)};
    final blockHeight = height;
    if (blockHeight != null) {
      json['height'] = blockHeight;
    }
    return json;
  }
}

/// The unversioned envelope.
String encodeCompactBlocksForScan(Iterable<CompactBlockScanInput> blocks) =>
    jsonEncode({
      'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
    });

class CompactBlockScanRange {
  const CompactBlockScanRange({required this.start, required this.end})
    : assert(start <= end, 'start must be <= end');

  final int start;
  final int end;

  Map<String, Object?> toJson() => {'start': start, 'end': end};
}

class ScanInputEnvelope {
  ScanInputEnvelope({
    this.network,
    this.range,
    this.includeSaplingWitnesses = false,
    this.priorSaplingFrontier,
    this.includeOrchardWitnesses = false,
    this.priorOrchardFrontier,
    this.priorIronwoodFrontier,
    this.watchedNullifiers,
    required Iterable<CompactBlockScanInput> blocks,
  }) : blocks = List<CompactBlockScanInput>.unmodifiable(blocks);

  static const int version = 1;

  final String? network;
  final CompactBlockScanRange? range;

  final bool includeSaplingWitnesses;

  final String? priorSaplingFrontier;

  final bool includeOrchardWitnesses;

  final String? priorOrchardFrontier;

  final String? priorIronwoodFrontier;

  final ZcashWatchedNullifiers? watchedNullifiers;

  final List<CompactBlockScanInput> blocks;

  Map<String, Object?> toJson() => {
    'scan_input_version': version,
    if (network != null) 'network': network,
    if (range != null) 'range': range!.toJson(),
    if (includeSaplingWitnesses) 'include_sapling_witnesses': true,
    'prior_sapling_frontier': ?priorSaplingFrontier,
    if (includeOrchardWitnesses) 'include_orchard_witnesses': true,
    'prior_orchard_frontier': ?priorOrchardFrontier,
    'prior_ironwood_frontier': ?priorIronwoodFrontier,
    if (watchedNullifiers != null && !watchedNullifiers!.isEmpty)
      'watched_nullifiers': watchedNullifiers!.toJson(),
    'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
  };

  String encode() => jsonEncode(toJson());
}

String encodeVersionedCompactBlocksForScan({
  required Iterable<CompactBlockScanInput> blocks,
  String? network,
  CompactBlockScanRange? range,
  bool includeSaplingWitnesses = false,
  String? priorSaplingFrontier,
  bool includeOrchardWitnesses = false,
  String? priorOrchardFrontier,
  String? priorIronwoodFrontier,
  ZcashWatchedNullifiers? watchedNullifiers,
}) => ScanInputEnvelope(
  network: network,
  range: range,
  includeSaplingWitnesses: includeSaplingWitnesses,
  priorSaplingFrontier: priorSaplingFrontier,
  includeOrchardWitnesses: includeOrchardWitnesses,
  priorOrchardFrontier: priorOrchardFrontier,
  priorIronwoodFrontier: priorIronwoodFrontier,
  watchedNullifiers: watchedNullifiers,
  blocks: blocks,
).encode();

class ZcashWatchedNullifiers {
  ZcashWatchedNullifiers({
    Iterable<String> sapling = const [],
    Iterable<String> orchard = const [],
    Iterable<String> ironwood = const [],
  }) : sapling = _validatedNullifiers(sapling, 'sapling'),
       orchard = _validatedNullifiers(orchard, 'orchard'),
       ironwood = _validatedNullifiers(ironwood, 'ironwood');

  factory ZcashWatchedNullifiers.forPool(
    String pool,
    Iterable<String> nullifiers,
  ) => switch (pool) {
    'sapling' => ZcashWatchedNullifiers(sapling: nullifiers),
    'orchard' => ZcashWatchedNullifiers(orchard: nullifiers),
    'ironwood' => ZcashWatchedNullifiers(ironwood: nullifiers),
    _ => throw ArgumentError.value(
      pool,
      'pool',
      'must be "sapling", "orchard", or "ironwood"',
    ),
  };

  factory ZcashWatchedNullifiers.fromScannedNotes(
    Iterable<ZcashScannedNote> notes,
  ) {
    final byPool = <String, List<String>>{
      'sapling': [],
      'orchard': [],
      'ironwood': [],
    };
    for (final note in notes) {
      final nullifier = note.nullifier;
      final pool = byPool[note.pool];
      if (nullifier != null && pool != null) {
        pool.add(nullifier);
      }
    }
    return ZcashWatchedNullifiers(
      sapling: byPool['sapling']!,
      orchard: byPool['orchard']!,
      ironwood: byPool['ironwood']!,
    );
  }

  final List<String> sapling;
  final List<String> orchard;
  final List<String> ironwood;

  bool get isEmpty => sapling.isEmpty && orchard.isEmpty && ironwood.isEmpty;

  Map<String, Object?> toJson() => {
    if (sapling.isNotEmpty) 'sapling': sapling,
    if (orchard.isNotEmpty) 'orchard': orchard,
    if (ironwood.isNotEmpty) 'ironwood': ironwood,
  };
}

List<String> _validatedNullifiers(Iterable<String> nullifiers, String pool) {
  for (final nullifier in nullifiers) {
    if (nullifier.length != 64 || !_isHex(nullifier)) {
      throw ArgumentError.value(
        pool,
        'nullifiers',
        'each watched nullifier must be 32 bytes of hex',
      );
    }
  }
  return List<String>.unmodifiable(nullifiers);
}

bool _isHex(String value) {
  for (final unit in value.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLower = unit >= 0x61 && unit <= 0x66;
    final isUpper = unit >= 0x41 && unit <= 0x46;
    if (!isDigit && !isLower && !isUpper) {
      return false;
    }
  }
  return true;
}

class ZcashScanResult {
  const ZcashScanResult({
    required this.scannedBlocks,
    required this.discoveredNotes,
    required this.totalValue,
    required this.notes,
    this.spends = const [],
    this.scannedHeightRange,
    this.orderedBlocks,
    this.diagnostics = const [],
    this.orchardActions,
    this.saplingAnchor,
    this.orchardAnchor,
    this.ironwoodAnchor,
  });

  final int scannedBlocks;
  final int discoveredNotes;
  final int totalValue;
  final List<ZcashScannedNote> notes;

  final List<ZcashObservedSpend> spends;

  final CompactBlockScanRange? scannedHeightRange;

  final int? orderedBlocks;

  final List<ZcashScanBlockDiagnostic> diagnostics;

  final int? orchardActions;

  final String? saplingAnchor;

  final String? orchardAnchor;

  final String? ironwoodAnchor;

  factory ZcashScanResult.fromRawJson(
    String raw, {
    String context = 'scan_compact_blocks',
    Iterable<String> redactSensitive = const [],
    bool allowExperimentalOrchardNotes = false,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw StateError('$context returned malformed JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw StateError('$context returned non-object JSON');
    }
    return ZcashScanResult.fromJson(
      decoded,
      context: context,
      redactSensitive: redactSensitive,
      allowExperimentalOrchardNotes: allowExperimentalOrchardNotes,
    );
  }

  factory ZcashScanResult.fromJson(
    Map<String, Object?> json, {
    String context = 'scan_compact_blocks',
    Iterable<String> redactSensitive = const [],
    bool allowExperimentalOrchardNotes = false,
  }) {
    _throwIfScannerError(
      json,
      context: context,
      redactSensitive: redactSensitive,
    );

    final scannedBlocks = _requiredInt(
      json,
      'scanned_blocks',
      context: context,
    );
    final discoveredNotes = _requiredInt(
      json,
      'discovered_notes',
      context: context,
    );
    final totalValue = _requiredInt(json, 'total_value', context: context);
    final notesJson = _requiredList(json, 'notes', context: context);
    return ZcashScanResult(
      scannedBlocks: scannedBlocks,
      discoveredNotes: discoveredNotes,
      totalValue: totalValue,
      notes: notesJson
          .map(
            (note) => ZcashScannedNote.fromJson(
              _asObject(note, field: 'notes[]', context: context),
              context: context,
              allowExperimentalOrchardNotes: allowExperimentalOrchardNotes,
            ),
          )
          .toList(growable: false),
      spends: _optionalSpends(json, context),
      scannedHeightRange: _optionalRange(json, 'scanned_height_range', context),
      orderedBlocks: _optionalInt(json, 'ordered_blocks', context: context),
      diagnostics: _optionalDiagnostics(json, context),
      orchardActions: _optionalInt(json, 'orchard_actions', context: context),
      saplingAnchor: _optionalHex(json, 'sapling_anchor', context: context),
      orchardAnchor: _optionalHex(json, 'orchard_anchor', context: context),
      ironwoodAnchor: _optionalHex(json, 'ironwood_anchor', context: context),
    );
  }
}

class ZcashObservedSpend {
  const ZcashObservedSpend({
    required this.height,
    required this.tx,
    required this.pool,
    required this.nullifier,
    required this.index,
    this.noteIndex,
  });

  final int height;

  final String tx;

  final String pool;

  final String nullifier;

  final int index;

  final int? noteIndex;

  factory ZcashObservedSpend.fromJson(
    Map<String, Object?> json, {
    String context = 'scan_compact_blocks',
  }) => ZcashObservedSpend(
    height: _requiredInt(json, 'height', context: context),
    tx: _requiredString(json, 'tx', context: context),
    pool: _requiredSpendPool(json, context: context),
    nullifier: _requiredHex(json, 'nullifier', context: context),
    index: _requiredInt(json, 'index', context: context),
    noteIndex: _optionalInt(json, 'note_index', context: context),
  );
}

String _requiredSpendPool(
  Map<String, Object?> json, {
  required String context,
}) {
  final pool = _requiredString(json, 'pool', context: context);
  if (pool == 'sapling' || pool == 'orchard' || pool == 'ironwood') {
    return pool;
  }
  throw StateError(
    '$context returned an unsupported spend pool; expected "sapling", '
    '"orchard", or "ironwood"',
  );
}

List<ZcashObservedSpend> _optionalSpends(
  Map<String, Object?> json,
  String context,
) {
  final value = json['spends'];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw StateError('$context has invalid list field "spends"');
  }
  return value
      .map(
        (spend) => ZcashObservedSpend.fromJson(
          _asObject(spend, field: 'spends[]', context: context),
          context: context,
        ),
      )
      .toList(growable: false);
}

class ZcashScanBlockDiagnostic {
  const ZcashScanBlockDiagnostic({
    required this.blockIndex,
    required this.height,
    required this.category,
    required this.notes,
    this.orchardActions,
    this.orchardCommitmentTreeSize,
  });

  final int blockIndex;
  final int height;
  final String category;
  final int notes;

  final int? orchardActions;

  final int? orchardCommitmentTreeSize;

  factory ZcashScanBlockDiagnostic.fromJson(
    Map<String, Object?> json, {
    String context = 'scan_compact_blocks',
  }) => ZcashScanBlockDiagnostic(
    blockIndex: _requiredInt(json, 'block_index', context: context),
    height: _requiredInt(json, 'height', context: context),
    category: _requiredString(json, 'category', context: context),
    notes: _requiredInt(json, 'notes', context: context),
    orchardActions: _optionalInt(json, 'orchard_actions', context: context),
    orchardCommitmentTreeSize: _optionalInt(
      json,
      'orchard_commitment_tree_size',
      context: context,
    ),
  );
}

class ZcashScannedNote {
  const ZcashScannedNote({
    required this.height,
    required this.tx,
    required this.output,
    required this.value,
    required this.pool,
    this.nullifier,
    this.commitmentPosition,
    this.isChange,
    this.witness,
    this.recipient,
    this.rseed,
    this.rho,
    this.noteVersion,
  });

  final int height;
  final String tx;
  final int output;
  final int value;
  final String pool;

  final String? nullifier;

  final int? commitmentPosition;

  final bool? isChange;

  final String? witness;

  /// For Orchard-family notes, a UA with only the Orchard receiver
  /// (ZIP 229 adds no Ironwood address form).
  final String? recipient;

  /// `null` unless witness export was requested, or for pre-ZIP-212 notes.
  final String? rseed;

  final String? rho;

  /// `v2` for an Orchard note (ZIP 212), `v3` for Ironwood (ZIP 2005).
  final String? noteVersion;

  factory ZcashScannedNote.fromJson(
    Map<String, Object?> json, {
    String context = 'scan_compact_blocks',
    bool allowExperimentalOrchardNotes = false,
  }) => ZcashScannedNote(
    height: _requiredInt(json, 'height', context: context),
    tx: _requiredString(json, 'tx', context: context),
    output: _requiredInt(json, 'output', context: context),
    value: _requiredInt(json, 'value', context: context),
    pool: _requiredShieldedPool(
      json,
      context: context,
      allowExperimentalOrchardNotes: allowExperimentalOrchardNotes,
    ),
    nullifier: _optionalHex(json, 'nullifier', context: context),
    commitmentPosition: _optionalInt(
      json,
      'commitment_position',
      context: context,
    ),
    isChange: _optionalBool(json, 'is_change', context: context),
    witness: _optionalHex(json, 'witness', context: context),
    recipient: _optionalString(json, 'recipient', context: context),
    rseed: _optionalHex(json, 'rseed', context: context),
    rho: _optionalHex(json, 'rho', context: context),
    noteVersion: _optionalString(json, 'note_version', context: context),
  );
}

String _requiredShieldedPool(
  Map<String, Object?> json, {
  required String context,
  required bool allowExperimentalOrchardNotes,
}) {
  final pool = _requiredString(json, 'pool', context: context);
  if (pool == 'sapling' || pool == 'ironwood') {
    return pool;
  }
  if (pool == 'orchard' && allowExperimentalOrchardNotes) {
    return pool;
  }
  throw StateError(
    '$context returned unsupported scanner note pool; the default contract '
    'expected "sapling" or "ironwood", and the experimental Orchard pool '
    'requires an explicit opt-in',
  );
}

void _throwIfScannerError(
  Map<String, Object?> json, {
  required String context,
  required Iterable<String> redactSensitive,
}) {
  final error = json['error'];
  if (error == null) {
    return;
  }
  final category = json['category'];
  final blockIndex = json['block_index'];
  final height = json['height'];
  final parts = <String>[
    '$context failed',
    if (category is String && category.isNotEmpty) '[$category]',
    _redact(error.toString(), redactSensitive),
    if (blockIndex is num) 'block_index=${blockIndex.toInt()}',
    if (height is num) 'height=${height.toInt()}',
  ];
  throw StateError(parts.join(' '));
}

int _requiredInt(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value is num) {
    return value.toInt();
  }
  throw StateError('$context missing integer field "$key"');
}

int? _optionalInt(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toInt();
  }
  throw StateError('$context has invalid integer field "$key"');
}

bool? _optionalBool(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is bool) {
    return value;
  }
  throw StateError('$context has invalid boolean field "$key"');
}

String? _optionalHex(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw StateError('$context has invalid hex field "$key"');
  }
  if (value.isEmpty || value.length.isOdd) {
    throw StateError('$context has malformed hex field "$key"');
  }
  for (final unit in value.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLower = unit >= 0x61 && unit <= 0x66;
    final isUpper = unit >= 0x41 && unit <= 0x46;
    if (!isDigit && !isLower && !isUpper) {
      throw StateError('$context has malformed hex field "$key"');
    }
  }
  return value;
}

String? _optionalString(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.isEmpty) {
    throw StateError('$context has invalid string field "$key"');
  }
  return value;
}

CompactBlockScanRange? _optionalRange(
  Map<String, Object?> json,
  String key,
  String context,
) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! Map<String, Object?>) {
    throw StateError('$context has invalid object field "$key"');
  }
  return CompactBlockScanRange(
    start: _requiredInt(value, 'start', context: context),
    end: _requiredInt(value, 'end', context: context),
  );
}

List<ZcashScanBlockDiagnostic> _optionalDiagnostics(
  Map<String, Object?> json,
  String context,
) {
  final value = json['diagnostics'];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw StateError('$context has invalid list field "diagnostics"');
  }
  return value
      .map(
        (entry) => ZcashScanBlockDiagnostic.fromJson(
          _asObject(entry, field: 'diagnostics[]', context: context),
          context: context,
        ),
      )
      .toList(growable: false);
}

String _requiredString(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw StateError('$context missing non-empty string field "$key"');
}

String _requiredHex(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = _optionalHex(json, key, context: context);
  if (value == null) {
    throw StateError('$context missing hex field "$key"');
  }
  return value;
}

List<Object?> _requiredList(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value is List) {
    return value.cast<Object?>();
  }
  throw StateError('$context missing list field "$key"');
}

Map<String, Object?> _asObject(
  Object? value, {
  required String field,
  required String context,
}) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw StateError('$context has invalid object field "$field"');
}

String _redact(String message, Iterable<String> sensitiveValues) {
  var redacted = message;
  for (final value in sensitiveValues) {
    if (value.isNotEmpty) {
      redacted = redacted.replaceAll(value, '<redacted>');
    }
  }
  return redacted;
}
