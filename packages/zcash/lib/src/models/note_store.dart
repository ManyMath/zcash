import 'ironwood_notes.dart';
import 'orchard_notes.dart';
import 'sapling_notes.dart';
import 'scan.dart';

enum NoteStoreRefusal {
  coverageGap,

  foreignAccount,

  unknownRange,

  unsupportedVersion,

  wrongPool,

  malformed,
}

class NoteStoreException implements Exception {
  NoteStoreException(this.refusal, this.message, {this.missingRange});

  final NoteStoreRefusal refusal;
  final String message;

  final CompactBlockScanRange? missingRange;

  @override
  String toString() => 'NoteStoreException: $message';
}

class _NoteStoreState {
  _NoteStoreState(this.pool);

  final String pool;

  final Map<String, ZcashScannedNote> _notes = {};

  final Map<String, ZcashObservedSpend> _spends = {};

  String? accountFingerprint;
  int? coveredFrom;
  int? coveredThrough;

  List<ZcashScannedNote> get notes =>
      List<ZcashScannedNote>.unmodifiable(_notes.values);

  List<ZcashObservedSpend> get spends =>
      List<ZcashObservedSpend>.unmodifiable(_spends.values);

  void apply(ZcashScanResult scan, String fingerprint) {
    final known = accountFingerprint;
    if (known != null && known != fingerprint) {
      throw NoteStoreException(
        NoteStoreRefusal.foreignAccount,
        'scan is tagged with a different account than this store holds',
      );
    }

    final range = scan.scannedHeightRange;
    if (range == null &&
        !(scan.scannedBlocks == 0 &&
            scan.notes.isEmpty &&
            scan.spends.isEmpty)) {
      throw NoteStoreException(
        NoteStoreRefusal.unknownRange,
        'scan reports notes or spends but no scanned height range, so this '
        'store cannot tell which blocks it covers',
      );
    }

    final from = coveredFrom;
    final through = coveredThrough;
    if (range != null && from != null && through != null) {
      if (range.start > through + 1) {
        throw NoteStoreException(
          NoteStoreRefusal.coverageGap,
          'scan starts at ${range.start}; this store has covered through '
          '$through, so blocks ${through + 1}-${range.start - 1} were never '
          'scanned',
          missingRange: CompactBlockScanRange(
            start: through + 1,
            end: range.start - 1,
          ),
        );
      }
      if (range.end < from - 1) {
        throw NoteStoreException(
          NoteStoreRefusal.coverageGap,
          'scan ends at ${range.end}; this store begins at $from, so blocks '
          '${range.end + 1}-${from - 1} were never scanned',
          missingRange: CompactBlockScanRange(
            start: range.end + 1,
            end: from - 1,
          ),
        );
      }
    }

    // Reject stale or malformed canonical identities before mutating any
    // account, event, or coverage state.
    for (final note in scan.notes) {
      if (note.pool != pool) continue;
      _requireValidOptionalHex(note.witness, 'witness');
      final key = '${note.tx}:${note.output}';
      _requireCompatibleCanonicalBlock(_notes[key]?.blockHash, note.blockHash);
    }
    for (final spend in scan.spends) {
      if (spend.pool != pool) continue;
      _requireCompatibleCanonicalBlock(
        _spends[spend.nullifier]?.blockHash,
        spend.blockHash,
      );
    }

    accountFingerprint = fingerprint;

    for (final note in scan.notes) {
      if (note.pool != pool) {
        continue;
      }
      final key = '${note.tx}:${note.output}';
      _notes[key] = _merged(_notes[key], note);
    }

    for (final spend in scan.spends) {
      if (spend.pool != pool) {
        continue;
      }
      _spends[spend.nullifier] = _mergedSpend(_spends[spend.nullifier], spend);
    }

    if (range == null) {
      return;
    }
    coveredFrom = from == null || range.start < from ? range.start : from;
    coveredThrough = through == null || range.end > through
        ? range.end
        : through;
  }

  static const int version = 2;

  Map<String, Object?> toJson() => {
    'note_store_version': version,
    'pool': pool,
    if (accountFingerprint != null) 'account_fingerprint': accountFingerprint,
    if (coveredFrom != null) 'covered_from': coveredFrom,
    if (coveredThrough != null) 'covered_through': coveredThrough,
    'notes': [
      for (final note in _notes.values)
        {
          'height': note.height,
          'tx': note.tx,
          'output': note.output,
          'value': note.value,
          if (note.nullifier != null) 'nullifier': note.nullifier,
          if (note.commitmentPosition != null)
            'commitment_position': note.commitmentPosition,
          if (note.isChange != null) 'is_change': note.isChange,
          if (note.witness != null) 'witness': note.witness,
          if (note.recipient != null) 'recipient': note.recipient,
          if (note.rseed != null) 'rseed': note.rseed,
          if (note.rho != null) 'rho': note.rho,
          if (note.noteVersion != null) 'note_version': note.noteVersion,
          if (note.blockHash != null) 'block_hash': note.blockHash,
        },
    ],
    'spends': [
      for (final spend in _spends.values)
        {
          'height': spend.height,
          'tx': spend.tx,
          'nullifier': spend.nullifier,
          'index': spend.index,
          if (spend.noteIndex != null) 'note_index': spend.noteIndex,
          if (spend.blockHash != null) 'block_hash': spend.blockHash,
        },
    ],
  };

  void restore(Map<String, Object?> json) {
    final version = json['note_store_version'];
    if (version != 1 && version != _NoteStoreState.version) {
      throw NoteStoreException(
        NoteStoreRefusal.unsupportedVersion,
        'note_store_version ${version ?? "(absent)"} is not supported; '
        'this build reads 1 and ${_NoteStoreState.version}',
      );
    }
    final documentPool = json['pool'];
    if (documentPool != pool) {
      throw NoteStoreException(
        NoteStoreRefusal.wrongPool,
        'this document is not a $pool note store',
      );
    }

    final fingerprint = json['account_fingerprint'];
    if (fingerprint != null && fingerprint is! String) {
      throw NoteStoreException(
        NoteStoreRefusal.malformed,
        'account_fingerprint must be a string',
      );
    }
    final from = _optionalHeight(json, 'covered_from');
    final through = _optionalHeight(json, 'covered_through');
    if ((from == null) != (through == null)) {
      throw NoteStoreException(
        NoteStoreRefusal.malformed,
        'covered_from and covered_through are written together or not at all',
      );
    }
    if (from != null && through != null && from > through) {
      throw NoteStoreException(
        NoteStoreRefusal.malformed,
        'covered_from is above covered_through',
      );
    }

    for (final entry in _list(json, 'notes')) {
      final note = ZcashScannedNote(
        height: _int(entry, 'height'),
        tx: _string(entry, 'tx'),
        output: _int(entry, 'output'),
        value: _int(entry, 'value'),
        pool: pool,
        nullifier: _optionalString(entry, 'nullifier'),
        commitmentPosition: _optionalHeight(entry, 'commitment_position'),
        isChange: entry['is_change'] as bool?,
        witness: _optionalHexString(entry, 'witness'),
        recipient: _optionalString(entry, 'recipient'),
        rseed: _optionalString(entry, 'rseed'),
        rho: _optionalString(entry, 'rho'),
        noteVersion: _optionalString(entry, 'note_version'),
        blockHash: _optionalBlockHash(entry, 'block_hash'),
      );
      _notes['${note.tx}:${note.output}'] = note;
    }

    for (final entry in _list(json, 'spends')) {
      final spend = ZcashObservedSpend(
        height: _int(entry, 'height'),
        tx: _string(entry, 'tx'),
        pool: pool,
        nullifier: _string(entry, 'nullifier'),
        index: _int(entry, 'index'),
        noteIndex: _optionalHeight(entry, 'note_index'),
        blockHash: _optionalBlockHash(entry, 'block_hash'),
      );
      _spends[spend.nullifier] = spend;
    }

    accountFingerprint = fingerprint as String?;
    coveredFrom = from;
    coveredThrough = through;
  }

  static List<Map<String, Object?>> _list(Map<String, Object?> json, String k) {
    final value = json[k];
    if (value is! List) {
      throw NoteStoreException(
        NoteStoreRefusal.malformed,
        '"$k" must be a list',
      );
    }
    return [
      for (final entry in value)
        if (entry is Map<String, Object?>)
          entry
        else
          throw NoteStoreException(
            NoteStoreRefusal.malformed,
            'every entry of "$k" must be an object',
          ),
    ];
  }

  static int _int(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is num) {
      return value.toInt();
    }
    throw NoteStoreException(
      NoteStoreRefusal.malformed,
      'missing integer field "$key"',
    );
  }

  static int? _optionalHeight(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toInt();
    }
    throw NoteStoreException(
      NoteStoreRefusal.malformed,
      '"$key" must be an integer',
    );
  }

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is String) {
      return value;
    }
    throw NoteStoreException(
      NoteStoreRefusal.malformed,
      'missing string field "$key"',
    );
  }

  static String? _optionalString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    throw NoteStoreException(
      NoteStoreRefusal.malformed,
      '"$key" must be a string',
    );
  }

  static String? _optionalBlockHash(Map<String, Object?> json, String key) {
    final value = _optionalString(json, key);
    if (value == null) return null;
    if (value.length != 64 || !_isHex(value)) {
      throw NoteStoreException(
        NoteStoreRefusal.malformed,
        '"$key" must be a 32-byte hexadecimal block hash',
      );
    }
    return value;
  }

  static String? _optionalHexString(Map<String, Object?> json, String key) {
    final value = _optionalString(json, key);
    _requireValidOptionalHex(value, key);
    return value;
  }

  static void _requireValidOptionalHex(String? value, String field) {
    if (value == null) return;
    if (value.isEmpty || value.length.isOdd || !_isHex(value)) {
      throw NoteStoreException(
        NoteStoreRefusal.malformed,
        '"$field" must be non-empty, even-length hexadecimal data',
      );
    }
  }

  static bool _isHex(String value) {
    for (final unit in value.codeUnits) {
      final digit = unit >= 0x30 && unit <= 0x39;
      final lower = unit >= 0x61 && unit <= 0x66;
      final upper = unit >= 0x41 && unit <= 0x46;
      if (!digit && !lower && !upper) return false;
    }
    return true;
  }

  List<String> get nullifiersToWatch => List<String>.unmodifiable([
    for (final note in _notes.values)
      if (note.nullifier != null && !_spends.containsKey(note.nullifier))
        note.nullifier!,
  ]);

  static ZcashScannedNote _merged(
    ZcashScannedNote? existing,
    ZcashScannedNote incoming,
  ) {
    _requireCompatibleCanonicalBlock(existing?.blockHash, incoming.blockHash);
    return ZcashScannedNote(
      height: incoming.height,
      tx: incoming.tx,
      output: incoming.output,
      value: incoming.value,
      pool: incoming.pool,
      nullifier: incoming.nullifier ?? existing?.nullifier,
      commitmentPosition:
          incoming.commitmentPosition ?? existing?.commitmentPosition,
      isChange: incoming.isChange ?? existing?.isChange,
      witness: incoming.witness ?? existing?.witness,
      recipient: incoming.recipient ?? existing?.recipient,
      rseed: incoming.rseed ?? existing?.rseed,
      rho: incoming.rho ?? existing?.rho,
      noteVersion: incoming.noteVersion ?? existing?.noteVersion,
      blockHash: incoming.blockHash ?? existing?.blockHash,
    );
  }

  static ZcashObservedSpend _mergedSpend(
    ZcashObservedSpend? existing,
    ZcashObservedSpend incoming,
  ) {
    _requireCompatibleCanonicalBlock(existing?.blockHash, incoming.blockHash);
    return incoming;
  }

  static void _requireCompatibleCanonicalBlock(
    String? existing,
    String? incoming,
  ) {
    for (final hash in [existing, incoming]) {
      if (hash != null && (hash.length != 64 || !_isHex(hash))) {
        throw NoteStoreException(
          NoteStoreRefusal.malformed,
          'a canonical block identity must be a 32-byte hexadecimal hash',
        );
      }
    }
    if (existing != null && incoming != null && existing != incoming) {
      throw NoteStoreException(
        NoteStoreRefusal.malformed,
        'a wallet event changed canonical block identity without a rollback',
      );
    }
  }

  void rollbackTo(int height) {
    _notes.removeWhere((_, note) => note.height > height);
    _spends.removeWhere((_, spend) => spend.height > height);

    final from = coveredFrom;
    if (from == null) {
      return;
    }
    if (height < from) {
      coveredFrom = null;
      coveredThrough = null;
      return;
    }
    final through = coveredThrough;
    if (through != null && height < through) {
      coveredThrough = height;
    }
  }
}

class IronwoodNoteStore {
  IronwoodNoteStore();

  factory IronwoodNoteStore.fromJson(Map<String, Object?> json) {
    final store = IronwoodNoteStore();
    store._state.restore(json);
    return store;
  }

  final _NoteStoreState _state = _NoteStoreState('ironwood');

  String? get accountFingerprint => _state.accountFingerprint;

  int? get coveredFrom => _state.coveredFrom;

  int? get coveredThrough => _state.coveredThrough;

  List<ZcashScannedNote> get notes => _state.notes;

  List<ZcashObservedSpend> get spends => _state.spends;

  void apply(ZcashScanResult scan, {required String accountFingerprint}) =>
      _state.apply(scan, accountFingerprint);

  void rollbackTo(int height) => _state.rollbackTo(height);

  Map<String, Object?> toJson() => _state.toJson();

  List<String> get nullifiersToWatch => _state.nullifiersToWatch;

  ZcashWatchedNullifiers get watchSet =>
      ZcashWatchedNullifiers.forPool(_state.pool, nullifiersToWatch);

  IronwoodNoteSet get noteSet =>
      IronwoodNoteSet.fromScan(notes: _state.notes, spends: _state.spends);
}

class SaplingNoteStore {
  SaplingNoteStore();

  factory SaplingNoteStore.fromJson(Map<String, Object?> json) {
    final store = SaplingNoteStore();
    store._state.restore(json);
    return store;
  }

  final _NoteStoreState _state = _NoteStoreState('sapling');

  String? get accountFingerprint => _state.accountFingerprint;

  int? get coveredFrom => _state.coveredFrom;

  int? get coveredThrough => _state.coveredThrough;

  List<ZcashScannedNote> get notes => _state.notes;

  List<ZcashObservedSpend> get spends => _state.spends;

  void apply(ZcashScanResult scan, {required String accountFingerprint}) =>
      _state.apply(scan, accountFingerprint);

  void rollbackTo(int height) => _state.rollbackTo(height);

  Map<String, Object?> toJson() => _state.toJson();

  List<String> get nullifiersToWatch => _state.nullifiersToWatch;

  ZcashWatchedNullifiers get watchSet =>
      ZcashWatchedNullifiers.forPool(_state.pool, nullifiersToWatch);

  SaplingNoteSet get noteSet =>
      SaplingNoteSet.fromScan(notes: _state.notes, spends: _state.spends);
}

/// Unspent notes are `migratable`; after NU6.3 only ZIP 318 moves them.
class OrchardNoteStore {
  OrchardNoteStore();

  factory OrchardNoteStore.fromJson(Map<String, Object?> json) {
    final store = OrchardNoteStore();
    store._state.restore(json);
    return store;
  }

  final _NoteStoreState _state = _NoteStoreState('orchard');

  String? get accountFingerprint => _state.accountFingerprint;

  int? get coveredFrom => _state.coveredFrom;

  int? get coveredThrough => _state.coveredThrough;

  List<ZcashScannedNote> get notes => _state.notes;

  List<ZcashObservedSpend> get spends => _state.spends;

  void apply(ZcashScanResult scan, {required String accountFingerprint}) =>
      _state.apply(scan, accountFingerprint);

  void rollbackTo(int height) => _state.rollbackTo(height);

  Map<String, Object?> toJson() => _state.toJson();

  List<String> get nullifiersToWatch => _state.nullifiersToWatch;

  ZcashWatchedNullifiers get watchSet =>
      ZcashWatchedNullifiers.forPool(_state.pool, nullifiersToWatch);

  OrchardNoteSet get noteSet =>
      OrchardNoteSet.fromScan(notes: _state.notes, spends: _state.spends);
}
