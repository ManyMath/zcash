import 'scan.dart';

enum IronwoodNoteStatus { spendable, spent, untrackable, incomplete }

class TrackedIronwoodNote {
  const TrackedIronwoodNote({
    required this.note,
    required this.status,
    this.spend,
  });

  final ZcashScannedNote note;
  final IronwoodNoteStatus status;

  final ZcashObservedSpend? spend;

  bool get isUnspent => status != IronwoodNoteStatus.spent;
}

class IronwoodNoteSet {
  const IronwoodNoteSet._(this.tracked);

  factory IronwoodNoteSet.fromScan({
    required Iterable<ZcashScannedNote> notes,
    Iterable<ZcashObservedSpend> spends = const [],
  }) {
    final spentByNullifier = <String, ZcashObservedSpend>{
      for (final spend in spends)
        if (spend.pool == _pool) spend.nullifier: spend,
    };
    final tracked = <TrackedIronwoodNote>[];
    for (final note in notes) {
      if (note.pool != _pool) {
        continue;
      }
      final nullifier = note.nullifier;
      if (nullifier == null) {
        tracked.add(
          TrackedIronwoodNote(
            note: note,
            status: IronwoodNoteStatus.untrackable,
          ),
        );
        continue;
      }
      final spend = spentByNullifier[nullifier];
      if (spend != null) {
        tracked.add(
          TrackedIronwoodNote(
            note: note,
            status: IronwoodNoteStatus.spent,
            spend: spend,
          ),
        );
        continue;
      }
      tracked.add(
        TrackedIronwoodNote(
          note: note,
          status: _isRebuildable(note)
              ? IronwoodNoteStatus.spendable
              : IronwoodNoteStatus.incomplete,
        ),
      );
    }
    return IronwoodNoteSet._(List<TrackedIronwoodNote>.unmodifiable(tracked));
  }

  static const String _pool = 'ironwood';

  final List<TrackedIronwoodNote> tracked;

  List<ZcashScannedNote> get spendable => [
    for (final entry in tracked)
      if (entry.status == IronwoodNoteStatus.spendable) entry.note,
  ];

  int get spendableZatoshis =>
      spendable.fold(0, (sum, note) => sum + note.value);

  List<TrackedIronwoodNote> get unspent => [
    for (final entry in tracked)
      if (entry.isUnspent) entry,
  ];

  int get unspentZatoshis =>
      unspent.fold(0, (sum, entry) => sum + entry.note.value);

  List<TrackedIronwoodNote> get untrackable => [
    for (final entry in tracked)
      if (entry.status == IronwoodNoteStatus.untrackable) entry,
  ];

  int get untrackableZatoshis =>
      untrackable.fold(0, (sum, entry) => sum + entry.note.value);

  List<TrackedIronwoodNote> get spent => [
    for (final entry in tracked)
      if (entry.status == IronwoodNoteStatus.spent) entry,
  ];

  bool get hasCompleteSpendComponents =>
      unspent.every((entry) => entry.status == IronwoodNoteStatus.spendable);

  static bool _isRebuildable(ZcashScannedNote note) =>
      note.recipient != null &&
      note.rseed != null &&
      note.rho != null &&
      note.noteVersion == 'v3' &&
      note.witness != null;
}
