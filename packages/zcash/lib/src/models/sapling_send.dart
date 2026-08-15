import 'dart:typed_data';

import 'proposal.dart';
import 'sapling_build.dart';
import 'sapling_notes.dart';
import 'sapling_selection.dart';
import 'scan.dart';

enum SaplingSendRefusal {
  noSaplingAnchor,

  notesInFlight,

  invalidRecipient,

  invalidChangeAddress,

  invalidMemo,

  planBuildMismatch,
}

class SaplingSendException implements Exception {
  SaplingSendException(this.refusal, this.message);

  final SaplingSendRefusal refusal;
  final String message;

  @override
  String toString() => 'SaplingSendException: $message';
}

class SaplingSendPlan {
  SaplingSendPlan._({
    required this.recipientAddress,
    required this.changeAddress,
    required this.amountZatoshis,
    required this.notes,
    required this.feeZatoshis,
    required this.changeZatoshis,
    required this.anchorHex,
    required this.targetHeight,
    required this.memo,
  });

  final String recipientAddress;

  final String changeAddress;

  final int amountZatoshis;

  final List<ZcashScannedNote> notes;

  final int feeZatoshis;

  final int changeZatoshis;

  final String anchorHex;

  final int targetHeight;

  int get inputZatoshis => notes.fold(0, (sum, note) => sum + note.value);

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

  Set<String> get spentNullifiers => {
    for (final note in notes)
      if (note.nullifier != null) note.nullifier!,
  };

  static SaplingSendPlan fromScan({
    required ZcashScanResult scan,
    required String recipientAddress,
    required String changeAddress,
    required int amountZatoshis,
    required int targetHeight,
    required int Function(List<ZcashScannedNote> spends) feeForSpends,
    Iterable<SaplingSendPlan> inFlight = const [],
    int? maxNotes,
    Uint8List? memo,
  }) {
    if (recipientAddress.isEmpty) {
      throw SaplingSendException(
        SaplingSendRefusal.invalidRecipient,
        'a payment needs a recipient address',
      );
    }
    if (changeAddress.isEmpty) {
      throw SaplingSendException(
        SaplingSendRefusal.invalidChangeAddress,
        'a Sapling payment states every output it makes, so it has to name '
        'where its change goes; unstated change is paid to the miner',
      );
    }
    if (memo != null) {
      final refusal = zcashMemoRefusalReason(
        memo,
        recipientCanCarryMemo: !zcashAddressIsTransparent(recipientAddress),
        recipientDescription: 'transparent recipient',
      );
      if (refusal != null) {
        throw SaplingSendException(SaplingSendRefusal.invalidMemo, refusal);
      }
    }

    final anchor = scan.saplingAnchor;
    if (anchor == null) {
      throw SaplingSendException(
        SaplingSendRefusal.noSaplingAnchor,
        'the scan reports no Sapling anchor, so its notes cannot be proven '
        'against any tree state. Rescan with include_sapling_witnesses, '
        'against a native library built with sapling-spend-build. An anchor '
        'from another pool is not a substitute: it is a root of a different '
        'tree, and a transaction anchored to it builds, proves, and is '
        'rejected by every node',
      );
    }

    final reserved = <String>{
      for (final plan in inFlight) ...plan.spentNullifiers,
    };

    SaplingSendPlan planFrom(SaplingNoteSet candidates) {
      final selection = SaplingInputSelection.select(
        notes: candidates,
        amountZatoshis: amountZatoshis,
        feeForSpends: feeForSpends,
        maxNotes: maxNotes,
      );
      return SaplingSendPlan._(
        recipientAddress: recipientAddress,
        changeAddress: changeAddress,
        amountZatoshis: selection.amountZatoshis,
        notes: selection.notes,
        feeZatoshis: selection.feeZatoshis,
        changeZatoshis: selection.changeZatoshis,
        anchorHex: anchor,
        targetHeight: targetHeight,
        memo: memo,
      );
    }

    final everything = SaplingNoteSet.fromScan(
      notes: scan.notes,
      spends: scan.spends,
    );
    if (reserved.isEmpty) {
      return planFrom(everything);
    }

    final available = SaplingNoteSet.fromScan(
      notes: [
        for (final note in scan.notes)
          if (!reserved.contains(note.nullifier)) note,
      ],
      spends: scan.spends,
    );
    try {
      return planFrom(available);
    } on SaplingSelectionException catch (refusal) {
      var fundableWithThem = true;
      try {
        planFrom(everything);
      } on SaplingSelectionException {
        fundableWithThem = false;
      }
      if (!fundableWithThem) {
        rethrow;
      }
      final committed =
          everything.spendableZatoshis - available.spendableZatoshis;
      throw SaplingSendException(
        SaplingSendRefusal.notesInFlight,
        'the wallet holds enough Sapling value to pay $amountZatoshis '
        'zatoshis, but $committed of it is committed to ${reserved.length} '
        'note(s) in ${inFlight.length} unconfirmed payment(s). Spending them '
        'again would be a double spend the network rejects. Wait until a scan '
        'observes them spent rather than treating this as an insufficient '
        'balance (${refusal.message})',
      );
    }
  }
}

class SaplingPreparedSend {
  factory SaplingPreparedSend({
    required SaplingSendPlan plan,
    required SaplingBuildResult transaction,
  }) {
    void require(String field, int planned, int built) {
      if (planned != built) {
        throw SaplingSendException(
          SaplingSendRefusal.planBuildMismatch,
          'the built transaction $field is $built zatoshis where the plan the '
          'user approved says $planned. The quote and the build have diverged; '
          'neither number may be preferred over the other',
        );
      }
    }

    require('fee', plan.feeZatoshis, transaction.feeZatoshis);
    require('input', plan.inputZatoshis, transaction.totalSpentZatoshis);
    require(
      'delivered value',
      plan.amountZatoshis + plan.changeZatoshis,
      transaction.totalOutputZatoshis,
    );
    if (transaction.saplingSpends != plan.notes.length) {
      throw SaplingSendException(
        SaplingSendRefusal.planBuildMismatch,
        'the built transaction spends ${transaction.saplingSpends} Sapling '
        'notes where the plan selected ${plan.notes.length}',
      );
    }
    if (!transaction.hasRealProofs) {
      throw SaplingSendException(
        SaplingSendRefusal.planBuildMismatch,
        'the built transaction carries placeholder proofs, so it can never be '
        'broadcast. Supply the Sapling MPC parameters; a send that cannot be '
        'sent is worse than an error',
      );
    }
    return SaplingPreparedSend._(plan: plan, transaction: transaction);
  }

  const SaplingPreparedSend._({required this.plan, required this.transaction});

  final SaplingSendPlan plan;

  final SaplingBuildResult transaction;

  String get transactionHex => transaction.transactionHex;

  String get txid => transaction.txid;

  int get expiryHeight => transaction.expiryHeight;
}
