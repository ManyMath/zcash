import 'scan.dart';

enum SaplingNoteStatus { spendable, spent, untrackable, incomplete }

class TrackedSaplingNote {
  const TrackedSaplingNote({
    required this.note,
    required this.status,
    this.spend,
  });

  final ZcashScannedNote note;
  final SaplingNoteStatus status;

  final ZcashObservedSpend? spend;

  bool get isUnspent => status != SaplingNoteStatus.spent;
}

class SaplingNoteSet {
  const SaplingNoteSet._(this.tracked);

  factory SaplingNoteSet.fromScan({
    required Iterable<ZcashScannedNote> notes,
    Iterable<ZcashObservedSpend> spends = const [],
  }) {
    final spentByNullifier = <String, ZcashObservedSpend>{
      for (final spend in spends)
        if (spend.pool == _pool) spend.nullifier: spend,
    };
    final tracked = <TrackedSaplingNote>[];
    for (final note in notes) {
      if (note.pool != _pool) {
        continue;
      }
      final nullifier = note.nullifier;
      if (nullifier == null) {
        tracked.add(
          TrackedSaplingNote(note: note, status: SaplingNoteStatus.untrackable),
        );
        continue;
      }
      final spend = spentByNullifier[nullifier];
      if (spend != null) {
        tracked.add(
          TrackedSaplingNote(
            note: note,
            status: SaplingNoteStatus.spent,
            spend: spend,
          ),
        );
        continue;
      }
      tracked.add(
        TrackedSaplingNote(
          note: note,
          status: _isRebuildable(note)
              ? SaplingNoteStatus.spendable
              : SaplingNoteStatus.incomplete,
        ),
      );
    }
    return SaplingNoteSet._(List<TrackedSaplingNote>.unmodifiable(tracked));
  }

  static const String _pool = 'sapling';

  final List<TrackedSaplingNote> tracked;

  List<ZcashScannedNote> get spendable => [
    for (final entry in tracked)
      if (entry.status == SaplingNoteStatus.spendable) entry.note,
  ];

  int get spendableZatoshis =>
      spendable.fold(0, (sum, note) => sum + note.value);

  List<TrackedSaplingNote> get unspent => [
    for (final entry in tracked)
      if (entry.isUnspent) entry,
  ];

  int get unspentZatoshis =>
      unspent.fold(0, (sum, entry) => sum + entry.note.value);

  List<TrackedSaplingNote> get untrackable => [
    for (final entry in tracked)
      if (entry.status == SaplingNoteStatus.untrackable) entry,
  ];

  int get untrackableZatoshis =>
      untrackable.fold(0, (sum, entry) => sum + entry.note.value);

  List<TrackedSaplingNote> get spent => [
    for (final entry in tracked)
      if (entry.status == SaplingNoteStatus.spent) entry,
  ];

  bool get hasCompleteSpendComponents =>
      unspent.every((entry) => entry.status == SaplingNoteStatus.spendable);

  static bool _isRebuildable(ZcashScannedNote note) =>
      note.recipient != null && note.rseed != null && note.witness != null;
}
