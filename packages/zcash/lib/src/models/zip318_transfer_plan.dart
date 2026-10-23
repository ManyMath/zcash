import 'scan.dart';
import 'spend.dart';
import 'zip318_migration.dart';

enum Zip318PlanRefusal {
  insufficientOrchardBalance,

  notYetFunded,

  wrongPool,

  incompleteNote,

  /// The anchor height is not on the ZIP 318 anchor grid.
  anchorOffBoundary,

  malformedAnchor,

  offSchedule,

  sessionAlreadyUsed,
}

class Zip318PlanException extends ZcashModelException {
  Zip318PlanException(this.refusal, String message) : super(message);

  final Zip318PlanRefusal refusal;
}

class Zip318FundingSelection {
  const Zip318FundingSelection({
    required this.note,
    required this.changeZatoshis,
  });

  final ZcashScannedNote note;

  final int changeZatoshis;

  bool get isExact => changeZatoshis == 0;

  static Zip318FundingSelection select({
    required Zip318ScheduledTransfer transfer,
    required Iterable<ZcashScannedNote> notes,
    bool requireExact = false,
  }) {
    final funding = transfer.fundingNoteValueZatoshis;
    final orchard = [
      for (final note in notes)
        if (note.pool == 'orchard') note,
    ];
    for (final note in orchard) {
      if (note.value >= funding && !_isSpendable(note)) {
        throw Zip318PlanException(
          Zip318PlanRefusal.incompleteNote,
          'an Orchard note large enough to fund this transfer is missing spend '
          'components. An Orchard-family note needs recipient, rseed, rho, its '
          'note version, and a witness; rho in particular is not recoverable '
          'from anything else, so rescan with witness export enabled',
        );
      }
    }
    final candidates = [
      for (final note in orchard)
        if (note.value >= funding) note,
    ]..sort((a, b) => a.value.compareTo(b.value));

    if (candidates.isEmpty) {
      throw Zip318PlanException(
        Zip318PlanRefusal.insufficientOrchardBalance,
        'no Orchard note holds the $funding zatoshis this transfer needs '
        '(${transfer.denominationZatoshis} denomination plus '
        '${transfer.feeZatoshis} fee)',
      );
    }
    for (final note in candidates) {
      if (note.value == funding) {
        return Zip318FundingSelection(note: note, changeZatoshis: 0);
      }
    }
    if (requireExact) {
      throw Zip318PlanException(
        Zip318PlanRefusal.notYetFunded,
        'no Orchard note holds exactly $funding zatoshis. Phase-1 note '
        'preparation restructures existing notes into exact funding values; '
        'until it confirms, plan with requireExact: false to fund this '
        'transfer with change instead',
      );
    }
    final smallest = candidates.first;
    return Zip318FundingSelection(
      note: smallest,
      changeZatoshis: smallest.value - funding,
    );
  }

  static bool _isSpendable(ZcashScannedNote note) =>
      note.recipient != null &&
      note.rseed != null &&
      note.rho != null &&
      note.noteVersion == 'v2' &&
      note.witness != null;
}

class Zip318TransferPlan {
  const Zip318TransferPlan({
    required this.transfer,
    required this.funding,
    required this.orchardAnchorHex,
    required this.ironwoodAnchorHex,
    required this.recipientAddress,
    required this.parameters,
  });

  final Zip318ScheduledTransfer transfer;

  final Zip318FundingSelection funding;

  final String orchardAnchorHex;

  final String ironwoodAnchorHex;

  final String recipientAddress;

  final Zip318Parameters parameters;

  int get targetHeight => transfer.broadcastHeight;

  int get expiryHeight => transfer.expiryHeight;

  int get ironwoodOutputZatoshis => transfer.denominationZatoshis;

  int? get orchardChangeZatoshis =>
      funding.isExact ? null : funding.changeZatoshis;

  int get feeZatoshis => transfer.feeZatoshis;

  factory Zip318TransferPlan.forTransfer({
    required Zip318ScheduledTransfer transfer,
    required Zip318FundingSelection funding,
    required String orchardAnchorHex,
    required String ironwoodAnchorHex,
    required String recipientAddress,
    Zip318Parameters parameters = Zip318Parameters.provisional,
  }) {
    final note = funding.note;
    if (note.pool != 'orchard') {
      throw Zip318PlanException(
        Zip318PlanRefusal.wrongPool,
        'a ZIP 318 migration spends an Orchard-pool note; this one is in the '
        "'${note.pool}' pool. An Ironwood note is already in the destination "
        'pool, and a Sapling note migrates by Path B',
      );
    }
    if (!Zip318FundingSelection._isSpendable(note)) {
      throw Zip318PlanException(
        Zip318PlanRefusal.incompleteNote,
        'the funding note is missing spend components. An Orchard-family note '
        'needs recipient, rseed, rho, note version v2, and a witness',
      );
    }
    if (note.value !=
        transfer.fundingNoteValueZatoshis + funding.changeZatoshis) {
      throw Zip318PlanException(
        Zip318PlanRefusal.notYetFunded,
        'the funding note does not cover the denomination, the fee, and the '
        'declared change exactly; the amount crossing the turnstile would not '
        'be a canonical denomination',
      );
    }
    final grid = Zip318AnchorSelection(parameters);
    if (!grid.isBoundary(transfer.anchorHeight)) {
      throw Zip318PlanException(
        Zip318PlanRefusal.anchorOffBoundary,
        'the transfer anchors at height ${transfer.anchorHeight}, which is not '
        'on the anchor grid (${grid.gridDescription}). Shared boundary anchors '
        "are what decouple a transaction's anchor from when its wallet last "
        'synced',
      );
    }
    _requireAnchor(orchardAnchorHex, 'the Orchard anchor');
    _requireAnchor(ironwoodAnchorHex, 'the Ironwood anchor');
    return Zip318TransferPlan(
      transfer: transfer,
      funding: funding,
      orchardAnchorHex: orchardAnchorHex,
      ironwoodAnchorHex: ironwoodAnchorHex,
      recipientAddress: recipientAddress,
      parameters: parameters,
    );
  }

  void checkDueAt(int chainHeight) {
    if (chainHeight < transfer.broadcastHeight) {
      throw Zip318PlanException(
        Zip318PlanRefusal.offSchedule,
        'this transfer is scheduled for height ${transfer.broadcastHeight} and '
        'the chain is at $chainHeight; broadcasting early collapses the '
        'randomised timing the schedule exists to create',
      );
    }
    if (chainHeight >= expiryHeight) {
      throw Zip318PlanException(
        Zip318PlanRefusal.offSchedule,
        'this transfer expired at $expiryHeight; rebuild it against the '
        'current canonical expiry rather than broadcasting a dead transaction',
      );
    }
  }
}

void _requireAnchor(String hex, String what) {
  final valid =
      hex.length == 64 &&
      hex.codeUnits.every((u) {
        final isDigit = u >= 0x30 && u <= 0x39;
        final isLower = u >= 0x61 && u <= 0x66;
        final isUpper = u >= 0x41 && u <= 0x46;
        return isDigit || isLower || isUpper;
      });
  if (!valid) {
    throw Zip318PlanException(
      Zip318PlanRefusal.malformedAnchor,
      '$what must be a 32-byte hex tree root',
    );
  }
}

/// ZIP 318: at most one migration broadcast per application open.
class Zip318BroadcastSession {
  Zip318BroadcastSession();

  bool _spent = false;

  bool get hasBroadcast => _spent;

  void claim(Zip318TransferPlan plan, {required int chainHeight}) {
    if (_spent) {
      throw Zip318PlanException(
        Zip318PlanRefusal.sessionAlreadyUsed,
        'this application open has already broadcast a migration transfer. '
        'Catching up on a backlog in one session correlates every overdue '
        'transfer with a single sync, which is what the randomised schedule '
        'exists to prevent; send the next one on the next open',
      );
    }
    plan.checkDueAt(chainHeight);
    _spent = true;
  }

  static Zip318ScheduledTransfer? nextDue(
    Zip318Schedule schedule,
    int chainHeight,
  ) {
    final overdue = schedule.overdueAt(chainHeight);
    return overdue.isEmpty ? null : overdue.first;
  }
}
