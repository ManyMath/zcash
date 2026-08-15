import 'sapling_send.dart';
import 'scan.dart';
import 'transaction.dart';

enum SaplingBroadcastRefusal { expired, rejected, undetermined, txidMismatch }

class SaplingBroadcastException implements Exception {
  SaplingBroadcastException(this.refusal, this.message, {this.cause});

  final SaplingBroadcastRefusal refusal;
  final String message;

  final Object? cause;

  bool get notesRemainCommitted =>
      refusal != SaplingBroadcastRefusal.rejected &&
      refusal != SaplingBroadcastRefusal.expired;

  @override
  String toString() => 'SaplingBroadcastException: $message';
}

class SaplingBroadcastReceipt {
  const SaplingBroadcastReceipt({
    required this.plan,
    required this.txid,
    required this.expiryHeight,
    this.broadcastAtHeight,
  });

  final SaplingSendPlan plan;

  final String txid;

  String get scanTxId => reverseTxidByteOrder(txid);

  final int expiryHeight;

  final int? broadcastAtHeight;

  Set<String> get committedNullifiers => plan.spentNullifiers;

  bool hasExpiredAt(int chainHeight) => chainHeight >= expiryHeight;

  ZcashObservedSpend? confirmationIn(ZcashScanResult scan) {
    for (final spend in scan.spends) {
      if (spend.pool == 'sapling' &&
          spend.tx.toLowerCase() == scanTxId.toLowerCase() &&
          committedNullifiers.contains(spend.nullifier)) {
        return spend;
      }
    }
    return null;
  }

  bool isConfirmedBy(ZcashScanResult scan) => confirmationIn(scan) != null;
}

Future<SaplingBroadcastReceipt> broadcastSaplingSend({
  required SaplingPreparedSend send,
  required Future<String> Function(String transactionHex) submit,
  int? chainHeight,
  bool Function(Object error)? isRejection,
}) async {
  if (chainHeight != null && chainHeight >= send.expiryHeight) {
    throw SaplingBroadcastException(
      SaplingBroadcastRefusal.expired,
      'this payment can last be mined in a block at height '
      '${send.expiryHeight} and the chain is already at $chainHeight, so the '
      'next block is past it and no block that could contain it will ever be '
      'produced. '
      'Plan it again against the current tip; its notes are free',
    );
  }

  final String acknowledged;
  try {
    acknowledged = await submit(send.transactionHex);
  } catch (error) {
    if (isRejection != null && isRejection(error)) {
      throw SaplingBroadcastException(
        SaplingBroadcastRefusal.rejected,
        'the node rejected this payment: $error. It reached no mempool, so its '
        'notes may be selected again',
        cause: error,
      );
    }
    throw SaplingBroadcastException(
      SaplingBroadcastRefusal.undetermined,
      'the payment may or may not have been broadcast: $error. Keep its notes '
      'committed until a scan sees them spent or the chain passes height '
      '${send.expiryHeight} — re-selecting them now risks publishing a second '
      'transaction over the same nullifiers',
      cause: error,
    );
  }

  if (acknowledged.isNotEmpty &&
      acknowledged.toLowerCase() != send.txid.toLowerCase()) {
    throw SaplingBroadcastException(
      SaplingBroadcastRefusal.txidMismatch,
      'the node acknowledged $acknowledged where this payment is ${send.txid}. '
      'A transaction id is a hash of its bytes, so the node parsed something '
      'other than what was built here, and this receipt would name the wrong '
      'transaction. Treat the notes as committed',
      cause: acknowledged,
    );
  }

  return SaplingBroadcastReceipt(
    plan: send.plan,
    txid: send.txid,
    expiryHeight: send.expiryHeight,
    broadcastAtHeight: chainHeight,
  );
}
