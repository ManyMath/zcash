import 'scan.dart';
import 'spend.dart';

/// The durable identity of a note whose spend data is acquired on demand.
///
/// This deliberately excludes the witness, recipient, rseed, and rho. Those
/// values are reacquired for one build and must not become wallet state merely
/// because a caller asked to spend a note.
class ZcashSpendNoteIdentity {
  const ZcashSpendNoteIdentity._({
    required this.height,
    required this.tx,
    required this.output,
    required this.value,
    required this.pool,
    required this.nullifier,
    required this.commitmentPosition,
  });

  factory ZcashSpendNoteIdentity.fromScannedNote(ZcashScannedNote note) {
    final nullifier = note.nullifier;
    final position = note.commitmentPosition;
    if (nullifier == null || position == null) {
      throw ZcashModelException(
        'a spend-material request needs the note nullifier and commitment '
        'position recorded by the durable scan; without both it cannot prove '
        'that a reacquired note is the same note the wallet selected',
      );
    }
    if (!_isHexOfLength(note.tx, 64) || !_isHexOfLength(nullifier, 64)) {
      throw ZcashModelException(
        'a spend-material request needs 32-byte hexadecimal transaction and '
        'nullifier identities',
      );
    }
    if (note.height < 0 || note.output < 0 || note.value < 0 || position < 0) {
      throw ZcashModelException(
        'a spend-material note identity cannot contain a negative height, '
        'output index, value, or commitment position',
      );
    }
    return ZcashSpendNoteIdentity._(
      height: note.height,
      tx: note.tx,
      output: note.output,
      value: note.value,
      pool: note.pool,
      nullifier: nullifier,
      commitmentPosition: position,
    );
  }

  final int height;
  final String tx;
  final int output;
  final int value;
  final String pool;
  final String nullifier;
  final int commitmentPosition;

  bool matches(ZcashScannedNote note) =>
      note.height == height &&
      note.tx == tx &&
      note.output == output &&
      note.value == value &&
      note.pool == pool &&
      note.nullifier == nullifier &&
      note.commitmentPosition == commitmentPosition;

  String get key => '$tx:$output';

  @override
  String toString() =>
      'ZcashSpendNoteIdentity(pool: $pool, height: $height, output: $output)';
}

/// A request to reacquire ephemeral spend data for already-discovered notes.
class ZcashSpendMaterialRequest {
  ZcashSpendMaterialRequest._({
    required this.accountFingerprint,
    required this.pool,
    required this.anchorHeight,
    required List<ZcashSpendNoteIdentity> noteIdentities,
  }) : noteIdentities = List.unmodifiable(noteIdentities);

  factory ZcashSpendMaterialRequest.ironwood({
    required String accountFingerprint,
    required Iterable<ZcashScannedNote> notes,
    required int anchorHeight,
  }) {
    if (accountFingerprint.isEmpty) {
      throw ZcashModelException(
        'a spend-material request must name the account that discovered its '
        'notes',
      );
    }
    final identities = [
      for (final note in notes) ZcashSpendNoteIdentity.fromScannedNote(note),
    ];
    if (identities.isEmpty) {
      throw ZcashModelException(
        'an Ironwood spend-material request must contain at least one note',
      );
    }
    if (identities.any((identity) => identity.pool != 'ironwood')) {
      throw ZcashModelException(
        'an Ironwood spend-material request cannot contain a note from '
        'another pool',
      );
    }
    if (identities.map((identity) => identity.key).toSet().length !=
        identities.length) {
      throw ZcashModelException(
        'an Ironwood spend-material request contains the same note more than '
        'once',
      );
    }
    final newestNoteHeight = identities
        .map((identity) => identity.height)
        .reduce((a, b) => a > b ? a : b);
    if (anchorHeight < newestNoteHeight) {
      throw ZcashModelException(
        'the requested anchor at height $anchorHeight predates a selected '
        'note at height $newestNoteHeight and cannot witness it',
      );
    }
    return ZcashSpendMaterialRequest._(
      accountFingerprint: accountFingerprint,
      pool: 'ironwood',
      anchorHeight: anchorHeight,
      noteIdentities: identities,
    );
  }

  final String accountFingerprint;
  final String pool;
  final int anchorHeight;
  final List<ZcashSpendNoteIdentity> noteIdentities;

  int get earliestNoteHeight => noteIdentities
      .map((identity) => identity.height)
      .reduce((a, b) => a < b ? a : b);

  @override
  String toString() =>
      'ZcashSpendMaterialRequest(pool: $pool, anchorHeight: $anchorHeight, '
      'noteCount: ${noteIdentities.length})';
}

/// Build-ready material tied to one account, pool anchor, and chain block.
///
/// This type intentionally has no JSON codec. Callers should retain it only
/// for the transaction build that requested it, then discard it.
class ZcashSpendMaterial {
  ZcashSpendMaterial.verified({
    required this.accountFingerprint,
    required this.pool,
    required this.anchorHeight,
    required this.anchorBlockHash,
    required this.scan,
  }) {
    if (pool != 'ironwood' || scan.ironwoodAnchor == null) {
      throw ZcashModelException(
        'Ironwood spend material must carry the Ironwood anchor produced by '
        'its continuous scan',
      );
    }
    if (scan.scannedHeightRange?.end != anchorHeight) {
      throw ZcashModelException(
        'spend material at height $anchorHeight must come from a scan ending '
        'at that exact height',
      );
    }
    if (scan.notes.isEmpty || scan.notes.any((note) => note.witness == null)) {
      throw ZcashModelException(
        'spend material contains no selected notes or a selected note without '
        'a witness',
      );
    }
  }

  final String accountFingerprint;
  final String pool;
  final int anchorHeight;
  final String anchorBlockHash;
  final ZcashScanResult scan;

  List<ZcashScannedNote> get notes => List.unmodifiable(scan.notes);

  String get anchor => scan.ironwoodAnchor!;

  @override
  String toString() =>
      'ZcashSpendMaterial(pool: $pool, anchorHeight: $anchorHeight, '
      'noteCount: ${scan.notes.length})';
}

bool _isHexOfLength(String value, int length) {
  if (value.length != length) return false;
  for (final unit in value.codeUnits) {
    final digit = unit >= 0x30 && unit <= 0x39;
    final lower = unit >= 0x61 && unit <= 0x66;
    final upper = unit >= 0x41 && unit <= 0x46;
    if (!digit && !lower && !upper) return false;
  }
  return true;
}
