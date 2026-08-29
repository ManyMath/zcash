import 'ironwood_notes.dart';
import 'note_store.dart';
import 'orchard_notes.dart';
import 'sapling_notes.dart';
import 'scan.dart';
import 'transparent_coins.dart';

enum ZcashPoolCapability {
  spendable,

  /// Can only be moved into Ironwood under ZIP 318: Orchard, after NU6.3.
  migratable,

  shieldable,
}

class ZcashAccountBalance {
  const ZcashAccountBalance._({
    required this.sapling,
    required this.orchard,
    required this.ironwood,
    required this.transparent,
  });

  factory ZcashAccountBalance.fromScan({
    required ZcashScanResult scan,
    TransparentCoinSet? transparent,
  }) {
    return ZcashAccountBalance._(
      sapling: SaplingNoteSet.fromScan(notes: scan.notes, spends: scan.spends),
      orchard: OrchardNoteSet.fromScan(notes: scan.notes, spends: scan.spends),
      ironwood: IronwoodNoteSet.fromScan(
        notes: scan.notes,
        spends: scan.spends,
      ),
      transparent:
          transparent ??
          TransparentCoinSet.fromUtxos(
            utxos: const [],
            chainHeight: 0,
            coinbaseOutpoints: const {},
          ),
    );
  }

  factory ZcashAccountBalance.fromStores({
    required SaplingNoteStore sapling,
    required OrchardNoteStore orchard,
    required IronwoodNoteStore ironwood,
    TransparentCoinSet? transparent,
  }) {
    final fingerprints = <String>{
      for (final f in [
        sapling.accountFingerprint,
        orchard.accountFingerprint,
        ironwood.accountFingerprint,
      ])
        ?f,
    };
    if (fingerprints.length > 1) {
      throw NoteStoreException(
        NoteStoreRefusal.foreignAccount,
        'these stores have been accumulating different accounts',
      );
    }
    return ZcashAccountBalance._(
      sapling: sapling.noteSet,
      orchard: orchard.noteSet,
      ironwood: ironwood.noteSet,
      transparent:
          transparent ??
          TransparentCoinSet.fromUtxos(
            utxos: const [],
            chainHeight: 0,
            coinbaseOutpoints: const {},
          ),
    );
  }

  final SaplingNoteSet sapling;

  final OrchardNoteSet orchard;

  final IronwoodNoteSet ironwood;

  final TransparentCoinSet transparent;

  int get transparentZatoshis => transparent.totalZatoshis;

  int get totalZatoshis =>
      sapling.unspentZatoshis +
      orchard.unspentZatoshis +
      ironwood.unspentZatoshis +
      transparentZatoshis;

  int get spendableZatoshis =>
      sapling.spendableZatoshis + ironwood.spendableZatoshis;

  int get migratableZatoshis => orchard.migratableZatoshis;

  Map<String, ZcashPoolCapability> get capabilities => const {
    'sapling': ZcashPoolCapability.spendable,
    'ironwood': ZcashPoolCapability.spendable,
    'orchard': ZcashPoolCapability.migratable,
    'transparent': ZcashPoolCapability.shieldable,
  };

  Map<String, int> get byPool => {
    'sapling': sapling.unspentZatoshis,
    'orchard': orchard.unspentZatoshis,
    'ironwood': ironwood.unspentZatoshis,
    'transparent': transparentZatoshis,
  };

  int get unusableZatoshis =>
      (sapling.unspentZatoshis - sapling.spendableZatoshis) +
      (orchard.unspentZatoshis - orchard.migratableZatoshis) +
      (ironwood.unspentZatoshis - ironwood.spendableZatoshis) +
      transparent.maturingZatoshis;

  int get untrackableZatoshis =>
      sapling.untrackableZatoshis +
      orchard.untrackableZatoshis +
      ironwood.untrackableZatoshis;

  bool get isFullyUsable =>
      sapling.hasCompleteSpendComponents &&
      orchard.hasCompleteSpendComponents &&
      ironwood.hasCompleteSpendComponents &&
      transparent.maturingZatoshis == 0;
}
