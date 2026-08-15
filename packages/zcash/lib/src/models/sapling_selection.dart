import 'sapling_notes.dart';
import 'scan.dart';

enum SaplingSelectionRefusal {
  insufficientFunds,

  insufficientSpendableNotes,

  invalidAmount,

  invalidFee,

  tooManyNotes,
}

class SaplingSelectionException implements Exception {
  SaplingSelectionException(this.refusal, this.message);

  final SaplingSelectionRefusal refusal;
  final String message;

  @override
  String toString() => 'SaplingSelectionException: $message';
}

class SaplingInputSelection {
  const SaplingInputSelection({
    required this.notes,
    required this.amountZatoshis,
    required this.feeZatoshis,
    required this.changeZatoshis,
  });

  final List<ZcashScannedNote> notes;

  final int amountZatoshis;

  final int feeZatoshis;

  final int changeZatoshis;

  int get inputZatoshis => notes.fold(0, (sum, note) => sum + note.value);

  /// [feeForSpends] must come from the builder's ZIP 317 fee quote.
  static SaplingInputSelection select({
    required SaplingNoteSet notes,
    required int amountZatoshis,
    required int Function(List<ZcashScannedNote> spends) feeForSpends,
    int? maxNotes,
  }) {
    if (amountZatoshis <= 0) {
      throw SaplingSelectionException(
        SaplingSelectionRefusal.invalidAmount,
        'the payment amount must be positive',
      );
    }

    final candidates = [...notes.spendable]
      ..sort((a, b) => a.value.compareTo(b.value));

    final chosen = <ZcashScannedNote>[];
    var total = 0;
    for (final note in candidates) {
      if (maxNotes != null && chosen.length >= maxNotes) {
        throw SaplingSelectionException(
          SaplingSelectionRefusal.tooManyNotes,
          'covering $amountZatoshis zatoshis would take more than $maxNotes '
          'notes; $total is the most $maxNotes of them hold',
        );
      }
      chosen.add(note);
      total += note.value;
      final fee = feeForSpends(List<ZcashScannedNote>.unmodifiable(chosen));
      if (fee < 0) {
        throw SaplingSelectionException(
          SaplingSelectionRefusal.invalidFee,
          'the fee quote returned a negative fee for ${chosen.length} notes',
        );
      }
      final required = amountZatoshis + fee;
      if (total >= required) {
        return SaplingInputSelection(
          notes: List<ZcashScannedNote>.unmodifiable(chosen),
          amountZatoshis: amountZatoshis,
          feeZatoshis: fee,
          changeZatoshis: total - required,
        );
      }
    }

    final held = notes.unspentZatoshis;
    if (held > total) {
      throw SaplingSelectionException(
        SaplingSelectionRefusal.insufficientSpendableNotes,
        'the wallet holds $held zatoshis in Sapling and can spend only $total '
        'of it; the rest is in notes missing a witness or a nullifier. Rescan '
        'with witness export before treating this as an insufficient balance',
      );
    }
    throw SaplingSelectionException(
      SaplingSelectionRefusal.insufficientFunds,
      'the spendable Sapling notes total $total zatoshis, which does not cover '
      '$amountZatoshis plus its fee',
    );
  }
}
