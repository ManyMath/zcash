import 'scan.dart';

/// ZIP 258 closes Orchard to incoming value after NU6.3; its notes can
/// only move out under ZIP 318.
enum OrchardNoteStatus { migratable, spent, untrackable, incomplete }

class TrackedOrchardNote {
  const TrackedOrchardNote({
    required this.note,
    required this.status,
    this.spend,
  });

  final ZcashScannedNote note;
  final OrchardNoteStatus status;

  final ZcashObservedSpend? spend;

  bool get isUnspent => status != OrchardNoteStatus.spent;
}

class OrchardNoteSet {
  const OrchardNoteSet._(this.tracked);

  factory OrchardNoteSet.fromScan({
    required Iterable<ZcashScannedNote> notes,
    Iterable<ZcashObservedSpend> spends = const [],
  }) {
    final spentByNullifier = <String, ZcashObservedSpend>{
      for (final spend in spends)
        if (spend.pool == _pool) spend.nullifier: spend,
    };
    final tracked = <TrackedOrchardNote>[];
    for (final note in notes) {
      if (note.pool != _pool) {
        continue;
      }
      final nullifier = note.nullifier;
      if (nullifier == null) {
        tracked.add(
          TrackedOrchardNote(note: note, status: OrchardNoteStatus.untrackable),
        );
        continue;
      }
      final spend = spentByNullifier[nullifier];
      if (spend != null) {
        tracked.add(
          TrackedOrchardNote(
            note: note,
            status: OrchardNoteStatus.spent,
            spend: spend,
          ),
        );
        continue;
      }
      tracked.add(
        TrackedOrchardNote(
          note: note,
          status: _isRebuildable(note)
              ? OrchardNoteStatus.migratable
              : OrchardNoteStatus.incomplete,
        ),
      );
    }
    return OrchardNoteSet._(List<TrackedOrchardNote>.unmodifiable(tracked));
  }

  static const String _pool = 'orchard';

  final List<TrackedOrchardNote> tracked;

  List<ZcashScannedNote> get migratable => [
    for (final entry in tracked)
      if (entry.status == OrchardNoteStatus.migratable) entry.note,
  ];

  int get migratableZatoshis =>
      migratable.fold(0, (sum, note) => sum + note.value);

  List<TrackedOrchardNote> get unspent => [
    for (final entry in tracked)
      if (entry.isUnspent) entry,
  ];

  int get unspentZatoshis =>
      unspent.fold(0, (sum, entry) => sum + entry.note.value);

  List<TrackedOrchardNote> get untrackable => [
    for (final entry in tracked)
      if (entry.status == OrchardNoteStatus.untrackable) entry,
  ];

  int get untrackableZatoshis =>
      untrackable.fold(0, (sum, entry) => sum + entry.note.value);

  List<TrackedOrchardNote> get spent => [
    for (final entry in tracked)
      if (entry.status == OrchardNoteStatus.spent) entry,
  ];

  bool get hasCompleteSpendComponents =>
      unspent.every((entry) => entry.status == OrchardNoteStatus.migratable);

  static bool _isRebuildable(ZcashScannedNote note) =>
      note.recipient != null &&
      note.rseed != null &&
      note.rho != null &&
      note.noteVersion == 'v2' &&
      note.witness != null;
}
