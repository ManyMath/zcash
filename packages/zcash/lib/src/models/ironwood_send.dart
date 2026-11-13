import 'dart:typed_data';

import 'ironwood_build.dart';
import 'ironwood_notes.dart';
import 'ironwood_selection.dart';
import 'proposal.dart';
import 'scan.dart';

enum IronwoodSendRefusal {
  invalidMemo,

  noIronwoodAnchor,

  notesInFlight,

  invalidRecipient,

  planBuildMismatch,
}

class IronwoodSendException implements Exception {
  IronwoodSendException(this.refusal, this.message);

  final IronwoodSendRefusal refusal;
  final String message;

  @override
  String toString() => 'IronwoodSendException: $message';
}

abstract interface class IronwoodNoteReservations {
  Set<String> reservedNullifiersAt(int chainHeight);
}

class IronwoodSendPlan {
  IronwoodSendPlan._({
    required this.recipientAddress,
    required this.amountZatoshis,
    required this.notes,
    required this.feeZatoshis,
    required this.changeZatoshis,
    required this.anchorHex,
    required this.targetHeight,
    required this.expiryHeight,
    required this.memo,
  });

  final String recipientAddress;

  final int amountZatoshis;

  final List<ZcashScannedNote> notes;

  final int feeZatoshis;

  final int changeZatoshis;

  final String anchorHex;

  final int targetHeight;

  final int? expiryHeight;

  /// Raw bytes; ZIP 302 gives the first byte its meaning.
  final Uint8List? memo;

  String? get memoHex {
    final bytes = memo;
    if (bytes == null) {
      return null;
    }
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  int get inputZatoshis => notes.fold(0, (sum, note) => sum + note.value);

  Set<String> get spentNullifiers => {
    for (final note in notes)
      if (note.nullifier != null) note.nullifier!,
  };

  static IronwoodSendPlan fromScan({
    required ZcashScanResult scan,
    required String recipientAddress,
    required int amountZatoshis,
    required int targetHeight,
    required int Function(List<ZcashScannedNote> spends) feeForSpends,
    Iterable<IronwoodSendPlan> inFlight = const [],
    IronwoodNoteReservations? reservations,
    int? maxNotes,
    int? expiryHeight,
    Uint8List? memo,
  }) {
    if (recipientAddress.isEmpty) {
      throw IronwoodSendException(
        IronwoodSendRefusal.invalidRecipient,
        'a payment needs a recipient address',
      );
    }
    if (memo != null) {
      final refusal = zcashMemoRefusalReason(
        memo,
        recipientCanCarryMemo: !zcashAddressIsTransparent(recipientAddress),
        recipientDescription: 'transparent recipient',
      );
      if (refusal != null) {
        throw IronwoodSendException(IronwoodSendRefusal.invalidMemo, refusal);
      }
    }

    final anchor = scan.ironwoodAnchor;
    if (anchor == null) {
      throw IronwoodSendException(
        IronwoodSendRefusal.noIronwoodAnchor,
        'the scan reports no Ironwood anchor, so its notes cannot be proven '
        'against any tree state. Rescan with witness export, against a native '
        'library built with Ironwood note discovery. The Orchard anchor '
        '${scan.orchardAnchor == null ? '' : 'this scan does report '}is not a '
        'substitute: it is a root of a different tree, and a transaction '
        'anchored to it builds, proves, and is rejected by every node',
      );
    }

    final reserved = <String>{
      for (final plan in inFlight) ...plan.spentNullifiers,
      ...?reservations?.reservedNullifiersAt(targetHeight),
    };

    IronwoodSendPlan planFrom(IronwoodNoteSet candidates) {
      final selection = IronwoodInputSelection.select(
        notes: candidates,
        amountZatoshis: amountZatoshis,
        feeForSpends: feeForSpends,
        maxNotes: maxNotes,
      );
      return IronwoodSendPlan._(
        recipientAddress: recipientAddress,
        amountZatoshis: selection.amountZatoshis,
        notes: selection.notes,
        feeZatoshis: selection.feeZatoshis,
        changeZatoshis: selection.changeZatoshis,
        anchorHex: anchor,
        targetHeight: targetHeight,
        expiryHeight: expiryHeight,
        memo: memo,
      );
    }

    final everything = IronwoodNoteSet.fromScan(
      notes: scan.notes,
      spends: scan.spends,
    );
    if (reserved.isEmpty) {
      return planFrom(everything);
    }

    final available = IronwoodNoteSet.fromScan(
      notes: [
        for (final note in scan.notes)
          if (!reserved.contains(note.nullifier)) note,
      ],
      spends: scan.spends,
    );
    try {
      return planFrom(available);
    } on IronwoodSelectionException catch (refusal) {
      var fundableWithThem = true;
      try {
        planFrom(everything);
      } on IronwoodSelectionException {
        fundableWithThem = false;
      }
      if (!fundableWithThem) {
        rethrow;
      }
      final committed =
          everything.spendableZatoshis - available.spendableZatoshis;
      throw IronwoodSendException(
        IronwoodSendRefusal.notesInFlight,
        'the wallet holds enough Ironwood value to pay $amountZatoshis '
        'zatoshis, but $committed of it is committed to ${reserved.length} '
        'note(s) in a pending or confirmed payment. Spending them '
        'again would be a double spend the network rejects. Wait until a scan '
        'observes them spent rather than treating this as an insufficient '
        'balance (${refusal.message})',
      );
    }
  }
}

class IronwoodPreparedSend {
  factory IronwoodPreparedSend({
    required IronwoodSendPlan plan,
    required IronwoodBuildResult transaction,
  }) {
    void require(String field, int planned, int built) {
      if (planned != built) {
        throw IronwoodSendException(
          IronwoodSendRefusal.planBuildMismatch,
          'the built transaction $field is $built zatoshis where the plan the '
          'user approved says $planned. The quote and the build have diverged; '
          'neither number may be preferred over the other',
        );
      }
    }

    require('fee', plan.feeZatoshis, transaction.feeZatoshis);
    require('payment', plan.amountZatoshis, transaction.ironwoodOutputZatoshis);
    require('change', plan.changeZatoshis, transaction.ironwoodChangeZatoshis);
    require('input', plan.inputZatoshis, transaction.ironwoodInputZatoshis);
    if (transaction.ironwoodSpends != plan.notes.length) {
      throw IronwoodSendException(
        IronwoodSendRefusal.planBuildMismatch,
        'the built transaction spends ${transaction.ironwoodSpends} Ironwood '
        'notes where the plan selected ${plan.notes.length}',
      );
    }
    if (transaction.ironwoodAnchor.toLowerCase() !=
        plan.anchorHex.toLowerCase()) {
      throw IronwoodSendException(
        IronwoodSendRefusal.planBuildMismatch,
        'the built transaction is anchored to a different Ironwood tree state '
        'than the notes were selected against',
      );
    }
    return IronwoodPreparedSend._(plan: plan, transaction: transaction);
  }

  const IronwoodPreparedSend._({required this.plan, required this.transaction});

  final IronwoodSendPlan plan;

  final IronwoodBuildResult transaction;

  String get transactionHex => transaction.transactionHex;

  String get txid => transaction.txid;

  int get expiryHeight => transaction.expiryHeight;
}

/// A payment funded only by Ironwood notes, with the destination route kept
/// separate from note selection. This permits the mandatory Ironwood builder
/// output to be either the payment itself or wallet change.
class IronwoodPaymentPlan {
  IronwoodPaymentPlan._({required this.output, required IronwoodSendPlan base})
    : _base = base;

  final ProposalOutput output;
  final IronwoodSendPlan _base;

  List<ZcashScannedNote> get notes => _base.notes;
  int get amountZatoshis => output.amountZatoshis;
  int get feeZatoshis => _base.feeZatoshis;
  int get changeZatoshis => _base.changeZatoshis;
  String get anchorHex => _base.anchorHex;
  int get targetHeight => _base.targetHeight;
  int? get expiryHeight => _base.expiryHeight;
  int get inputZatoshis => _base.inputZatoshis;
  Set<String> get spentNullifiers => _base.spentNullifiers;

  static IronwoodPaymentPlan fromScan({
    required ZcashScanResult scan,
    required ProposalOutput output,
    required int targetHeight,
    required int Function(List<ZcashScannedNote> spends) feeForSpends,
    IronwoodNoteReservations? reservations,
    int? maxNotes,
    int? expiryHeight,
  }) {
    final base = IronwoodSendPlan.fromScan(
      scan: scan,
      recipientAddress: output.receiverAddress,
      amountZatoshis: output.amountZatoshis,
      targetHeight: targetHeight,
      feeForSpends: feeForSpends,
      reservations: reservations,
      maxNotes: maxNotes,
      expiryHeight: expiryHeight,
      memo: output.memo,
    );
    return IronwoodPaymentPlan._(output: output, base: base);
  }
}

class IronwoodPreparedPayment {
  factory IronwoodPreparedPayment({
    required IronwoodPaymentPlan plan,
    required IronwoodBuildResult transaction,
  }) {
    void require(String field, int planned, int built) {
      if (planned != built) {
        throw IronwoodSendException(
          IronwoodSendRefusal.planBuildMismatch,
          'the built transaction $field is $built where the approved payment '
          'plan says $planned',
        );
      }
    }

    require('fee', plan.feeZatoshis, transaction.feeZatoshis);
    require('input', plan.inputZatoshis, transaction.ironwoodInputZatoshis);
    if (transaction.feeRule != 'zip317') {
      throw IronwoodSendException(
        IronwoodSendRefusal.planBuildMismatch,
        'the payment was not built with ZIP 317 fee accounting',
      );
    }
    if (transaction.ironwoodSpends != plan.notes.length) {
      throw IronwoodSendException(
        IronwoodSendRefusal.planBuildMismatch,
        'the build spends ${transaction.ironwoodSpends} Ironwood notes where '
        'the approved plan selected ${plan.notes.length}',
      );
    }
    if (transaction.ironwoodAnchor.toLowerCase() !=
        plan.anchorHex.toLowerCase()) {
      throw IronwoodSendException(
        IronwoodSendRefusal.planBuildMismatch,
        'the build uses a different Ironwood anchor than note selection',
      );
    }

    switch (plan.output.actualOutputPool) {
      case ProposalOutputPool.ironwood:
        require(
          'Ironwood payment',
          plan.amountZatoshis,
          transaction.ironwoodOutputZatoshis,
        );
        require(
          'Ironwood change',
          plan.changeZatoshis,
          transaction.ironwoodChangeZatoshis,
        );
        require('transparent output count', 0, transaction.vout);
        require('Sapling output count', 0, transaction.saplingOutputs);
      case ProposalOutputPool.transparent:
        require(
          'transparent payment',
          plan.amountZatoshis,
          transaction.nonIronwoodOutputZatoshis,
        );
        require(
          'Ironwood change output',
          plan.changeZatoshis,
          transaction.ironwoodOutputZatoshis,
        );
        require(
          'separate Ironwood change',
          0,
          transaction.ironwoodChangeZatoshis,
        );
        require('transparent output count', 1, transaction.vout);
        require('Sapling output count', 0, transaction.saplingOutputs);
      case ProposalOutputPool.sapling:
        require(
          'Sapling payment',
          plan.amountZatoshis,
          transaction.nonIronwoodOutputZatoshis,
        );
        require(
          'Ironwood change output',
          plan.changeZatoshis,
          transaction.ironwoodOutputZatoshis,
        );
        require(
          'separate Ironwood change',
          0,
          transaction.ironwoodChangeZatoshis,
        );
        require('transparent output count', 0, transaction.vout);
        require('Sapling output count', 1, transaction.saplingOutputs);
      case ProposalOutputPool.orchard:
        throw IronwoodSendException(
          IronwoodSendRefusal.planBuildMismatch,
          'ordinary post-NU6.3 payments cannot build an Orchard output',
        );
    }
    return IronwoodPreparedPayment._(plan: plan, transaction: transaction);
  }

  const IronwoodPreparedPayment._({
    required this.plan,
    required this.transaction,
  });

  final IronwoodPaymentPlan plan;
  final IronwoodBuildResult transaction;

  String get transactionHex => transaction.transactionHex;
  String get txid => transaction.txid;
  int get expiryHeight => transaction.expiryHeight;
}
