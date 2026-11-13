import 'ironwood_send.dart';
import 'proposal.dart';
import 'sapling_send.dart';
import 'scan.dart';
import 'transaction.dart';

enum IronwoodDestinationPool { transparent, sapling, orchard, ironwood }

enum ShieldedPendingSourcePool { sapling, ironwood }

enum IronwoodPendingBroadcastState {
  prepared,
  submitting,
  acknowledged,
  indeterminate,
}

enum IronwoodPendingSendRefusal {
  malformed,
  duplicateTransaction,
  notesAlreadyReserved,
  unknownTransaction,
  expiredRequiresRebuild,
  invalidTransition,
}

class IronwoodPendingSendException implements Exception {
  const IronwoodPendingSendException(this.refusal, this.message);

  final IronwoodPendingSendRefusal refusal;
  final String message;

  @override
  String toString() => 'IronwoodPendingSendException: $message';
}

class IronwoodPendingSendRecord {
  IronwoodPendingSendRecord._({
    required this.transactionHex,
    required this.txid,
    required Set<String> selectedNullifiers,
    required this.sourcePool,
    required this.recipient,
    required this.actualDestinationPool,
    required this.amountZatoshis,
    required this.feeZatoshis,
    required this.expiryHeight,
    required this.createdHeight,
    required this.broadcastState,
    this.confirmedHeight,
    this.confirmedBlockHash,
  }) : selectedNullifiers = Set.unmodifiable(selectedNullifiers);

  static const int version = 2;

  final String transactionHex;
  final String txid;
  final Set<String> selectedNullifiers;
  final ShieldedPendingSourcePool sourcePool;
  final String recipient;
  final IronwoodDestinationPool actualDestinationPool;
  final int amountZatoshis;
  final int feeZatoshis;
  final int expiryHeight;
  final int createdHeight;
  final IronwoodPendingBroadcastState broadcastState;
  final int? confirmedHeight;
  final String? confirmedBlockHash;

  bool get isConfirmed => confirmedHeight != null;

  bool isExpiredAt(int chainHeight) => chainHeight >= expiryHeight;

  Map<String, Object?> toJson() => {
    'pending_send_version': version,
    'transaction': transactionHex,
    'txid': txid,
    'selected_nullifiers': selectedNullifiers.toList(growable: false),
    'source_pool': sourcePool.name,
    'recipient': recipient,
    'actual_destination_pool': actualDestinationPool.name,
    'amount_zatoshis': amountZatoshis,
    'fee_zatoshis': feeZatoshis,
    'expiry_height': expiryHeight,
    'created_height': createdHeight,
    'broadcast_state': broadcastState.name,
    if (confirmedHeight != null) 'confirmed_height': confirmedHeight,
    if (confirmedBlockHash != null) 'confirmed_block_hash': confirmedBlockHash,
  };

  factory IronwoodPendingSendRecord.fromJson(Map<String, Object?> json) {
    final documentVersion = json['pending_send_version'];
    if (documentVersion != 1 && documentVersion != version) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'unsupported Ironwood pending-send record version',
      );
    }
    final transaction = _string(json, 'transaction');
    final txid = _string(json, 'txid');
    final nullifiers = _strings(json, 'selected_nullifiers').toSet();
    final recipient = _string(json, 'recipient');
    final amount = _integer(json, 'amount_zatoshis');
    final fee = _integer(json, 'fee_zatoshis');
    final expiry = _integer(json, 'expiry_height');
    final created = _integer(json, 'created_height');
    final confirmedHeight = _optionalInteger(json, 'confirmed_height');
    final confirmedHash = _optionalString(json, 'confirmed_block_hash');
    final destination = _destination(json['actual_destination_pool']);
    final sourcePool = documentVersion == 1
        ? ShieldedPendingSourcePool.ironwood
        : _sourcePool(json['source_pool']);
    final broadcast = _broadcastState(json['broadcast_state']);
    if (destination != IronwoodDestinationPool.ironwood) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'this first pending-send record version only accepts an actual '
        'Ironwood destination',
      );
    }
    _validate(
      transactionHex: transaction,
      txid: txid,
      nullifiers: nullifiers,
      recipient: recipient,
      amount: amount,
      fee: fee,
      expiry: expiry,
      created: created,
      confirmedHeight: confirmedHeight,
      confirmedHash: confirmedHash,
    );
    return IronwoodPendingSendRecord._(
      transactionHex: transaction,
      txid: txid,
      selectedNullifiers: nullifiers,
      sourcePool: sourcePool,
      recipient: recipient,
      actualDestinationPool: destination,
      amountZatoshis: amount,
      feeZatoshis: fee,
      expiryHeight: expiry,
      createdHeight: created,
      broadcastState: broadcast,
      confirmedHeight: confirmedHeight,
      confirmedBlockHash: confirmedHash,
    );
  }

  IronwoodPendingSendRecord _copyWith({
    IronwoodPendingBroadcastState? broadcastState,
    int? confirmedHeight,
    String? confirmedBlockHash,
    bool clearConfirmation = false,
  }) => IronwoodPendingSendRecord._(
    transactionHex: transactionHex,
    txid: txid,
    selectedNullifiers: selectedNullifiers,
    sourcePool: sourcePool,
    recipient: recipient,
    actualDestinationPool: actualDestinationPool,
    amountZatoshis: amountZatoshis,
    feeZatoshis: feeZatoshis,
    expiryHeight: expiryHeight,
    createdHeight: createdHeight,
    broadcastState: broadcastState ?? this.broadcastState,
    confirmedHeight: clearConfirmation
        ? null
        : confirmedHeight ?? this.confirmedHeight,
    confirmedBlockHash: clearConfirmation
        ? null
        : confirmedBlockHash ?? this.confirmedBlockHash,
  );

  @override
  String toString() =>
      'IronwoodPendingSendRecord(state: ${broadcastState.name}, '
      'confirmed: $isConfirmed, nullifierCount: ${selectedNullifiers.length})';
}

class IronwoodPendingSendState
    implements IronwoodNoteReservations, SaplingNoteReservations {
  IronwoodPendingSendState();

  static const int version = 2;

  final List<IronwoodPendingSendRecord> _records = [];

  List<IronwoodPendingSendRecord> get records => List.unmodifiable(_records);

  void addPrepared(
    IronwoodPreparedSend send, {
    required IronwoodDestinationPool actualDestinationPool,
    required int createdHeight,
  }) {
    if (actualDestinationPool != IronwoodDestinationPool.ironwood) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'this first pending-send slice only records a build whose actual '
        'destination pool is Ironwood',
      );
    }
    if (_records.any(
      (record) => record.txid.toLowerCase() == send.txid.toLowerCase(),
    )) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.duplicateTransaction,
        'this Ironwood transaction is already in pending-send state',
      );
    }
    final nullifiers = send.plan.spentNullifiers;
    final alreadyReserved = reservedNullifiersAt(createdHeight);
    if (nullifiers.any(alreadyReserved.contains)) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.notesAlreadyReserved,
        'an Ironwood note selected by this transaction is already reserved',
      );
    }
    _validate(
      transactionHex: send.transactionHex,
      txid: send.txid,
      nullifiers: nullifiers,
      recipient: send.plan.recipientAddress,
      amount: send.plan.amountZatoshis,
      fee: send.plan.feeZatoshis,
      expiry: send.expiryHeight,
      created: createdHeight,
    );
    _records.add(
      IronwoodPendingSendRecord._(
        transactionHex: send.transactionHex,
        txid: send.txid,
        selectedNullifiers: nullifiers,
        sourcePool: ShieldedPendingSourcePool.ironwood,
        recipient: send.plan.recipientAddress,
        actualDestinationPool: actualDestinationPool,
        amountZatoshis: send.plan.amountZatoshis,
        feeZatoshis: send.plan.feeZatoshis,
        expiryHeight: send.expiryHeight,
        createdHeight: createdHeight,
        broadcastState: IronwoodPendingBroadcastState.prepared,
      ),
    );
  }

  void addPreparedSaplingPayment(
    SaplingPreparedPayment payment, {
    required int createdHeight,
  }) {
    if (payment.plan.output.actualOutputPool != ProposalOutputPool.ironwood) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'a Sapling-funded Path B pending send must pay Ironwood',
      );
    }
    if (_records.any(
      (record) => record.txid.toLowerCase() == payment.txid.toLowerCase(),
    )) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.duplicateTransaction,
        'this transaction is already in pending-send state',
      );
    }
    final nullifiers = payment.plan.spentNullifiers;
    final reserved = reservedSaplingNullifiersAt(createdHeight);
    if (nullifiers.any(reserved.contains)) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.notesAlreadyReserved,
        'a Sapling note selected by this transaction is already reserved',
      );
    }
    _validate(
      transactionHex: payment.transactionHex,
      txid: payment.txid,
      nullifiers: nullifiers,
      recipient: payment.plan.output.encodedAddress,
      amount: payment.plan.amountZatoshis,
      fee: payment.plan.feeZatoshis,
      expiry: payment.expiryHeight,
      created: createdHeight,
    );
    _records.add(
      IronwoodPendingSendRecord._(
        transactionHex: payment.transactionHex,
        txid: payment.txid,
        selectedNullifiers: nullifiers,
        sourcePool: ShieldedPendingSourcePool.sapling,
        recipient: payment.plan.output.encodedAddress,
        actualDestinationPool: IronwoodDestinationPool.ironwood,
        amountZatoshis: payment.plan.amountZatoshis,
        feeZatoshis: payment.plan.feeZatoshis,
        expiryHeight: payment.expiryHeight,
        createdHeight: createdHeight,
        broadcastState: IronwoodPendingBroadcastState.prepared,
      ),
    );
  }

  IronwoodPendingSendRecord requireBroadcastableSaplingPayment(
    SaplingPreparedPayment payment, {
    int? chainHeight,
  }) => _requireBroadcastable(
    txid: payment.txid,
    transactionHex: payment.transactionHex,
    nullifiers: payment.plan.spentNullifiers,
    sourcePool: ShieldedPendingSourcePool.sapling,
    chainHeight: chainHeight,
  );

  IronwoodPendingSendRecord requireBroadcastable(
    IronwoodPreparedSend send, {
    int? chainHeight,
  }) {
    return _requireBroadcastable(
      txid: send.txid,
      transactionHex: send.transactionHex,
      nullifiers: send.plan.spentNullifiers,
      sourcePool: ShieldedPendingSourcePool.ironwood,
      chainHeight: chainHeight,
    );
  }

  IronwoodPendingSendRecord _requireBroadcastable({
    required String txid,
    required String transactionHex,
    required Set<String> nullifiers,
    required ShieldedPendingSourcePool sourcePool,
    int? chainHeight,
  }) {
    final index = _records.indexWhere(
      (record) => record.txid.toLowerCase() == txid.toLowerCase(),
    );
    if (index < 0) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.unknownTransaction,
        'persist an Ironwood prepared send before submitting it',
      );
    }
    final record = _records[index];
    if (record.transactionHex != transactionHex ||
        record.sourcePool != sourcePool ||
        record.selectedNullifiers.length != nullifiers.length ||
        !record.selectedNullifiers.containsAll(nullifiers)) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'the persisted Ironwood pending send does not match the transaction '
        'being submitted',
      );
    }
    if (chainHeight != null && record.isExpiredAt(chainHeight)) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.expiredRequiresRebuild,
        'this Ironwood transaction has expired; release its reservation and '
        'build a new transaction at the current chain height',
      );
    }
    return record;
  }

  /// Revalidates a prepared send reconstructed from durable state immediately
  /// before submission. Callers may retain a recovered artifact while the
  /// chain advances, so recovery-time expiry checks are not sufficient.
  IronwoodPendingSendRecord requireBroadcastableRecord(
    IronwoodPendingSendRecord recovered, {
    int? chainHeight,
  }) {
    final index = _records.indexWhere(
      (record) => record.txid.toLowerCase() == recovered.txid.toLowerCase(),
    );
    if (index < 0) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.unknownTransaction,
        'persist an Ironwood prepared send before submitting it',
      );
    }
    final record = _records[index];
    if (record.transactionHex != recovered.transactionHex ||
        record.selectedNullifiers.length !=
            recovered.selectedNullifiers.length ||
        !record.selectedNullifiers.containsAll(
          recovered.selectedNullifiers,
        )) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'the persisted Ironwood pending send does not match the transaction '
        'being submitted',
      );
    }
    if (chainHeight != null && record.isExpiredAt(chainHeight)) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.expiredRequiresRebuild,
        'this Ironwood transaction has expired; release its reservation and '
        'build a new transaction at the current chain height',
      );
    }
    return record;
  }

  void markSubmitting(String txid) => _setBroadcastState(
    txid,
    IronwoodPendingBroadcastState.submitting,
    allowedFrom: const {
      IronwoodPendingBroadcastState.prepared,
      IronwoodPendingBroadcastState.indeterminate,
    },
  );

  void markAcknowledged(String txid) => _setBroadcastState(
    txid,
    IronwoodPendingBroadcastState.acknowledged,
    allowedFrom: const {IronwoodPendingBroadcastState.submitting},
  );

  void markIndeterminate(String txid) => _setBroadcastState(
    txid,
    IronwoodPendingBroadcastState.indeterminate,
    allowedFrom: const {IronwoodPendingBroadcastState.submitting},
  );

  void releaseRejected(String txid) {
    final index = _indexOf(txid);
    _records.removeAt(index);
  }

  /// Reconciles spends only when the block identity from [scan] agrees with
  /// the independently read canonical block identity at the same height.
  void reconcileWithScan({
    required ZcashScanResult scan,
    required String? Function(int height) canonicalBlockHashAt,
    required String? Function(int height) scannedBlockHashAt,
  }) {
    for (var index = 0; index < _records.length; index++) {
      var record = _records[index];
      final confirmedHeight = record.confirmedHeight;
      if (confirmedHeight != null) {
        final canonical = canonicalBlockHashAt(confirmedHeight);
        if (canonical != null &&
            canonical.toLowerCase() ==
                record.confirmedBlockHash!.toLowerCase()) {
          continue;
        }
        record = record._copyWith(clearConfirmation: true);
        _records[index] = record;
      }
      final scanTxid = reverseTxidByteOrder(record.txid).toLowerCase();
      final matching = scan.spends.where(
        (spend) =>
            spend.pool == record.sourcePool.name &&
            spend.tx.toLowerCase() == scanTxid,
      );
      final byHeight = <int, Set<String>>{};
      for (final spend in matching) {
        byHeight.putIfAbsent(spend.height, () => {}).add(spend.nullifier);
      }
      int? confirmationHeight;
      for (final entry in byHeight.entries) {
        if (entry.value.containsAll(record.selectedNullifiers)) {
          confirmationHeight = entry.key;
          break;
        }
      }
      if (confirmationHeight == null) continue;
      final blockHash = canonicalBlockHashAt(confirmationHeight);
      final scannedBlockHash = scannedBlockHashAt(confirmationHeight);
      if (blockHash == null ||
          scannedBlockHash == null ||
          !_is32ByteHex(blockHash) ||
          !_is32ByteHex(scannedBlockHash) ||
          blockHash.toLowerCase() != scannedBlockHash.toLowerCase()) {
        continue;
      }
      _records[index] = record._copyWith(
        confirmedHeight: confirmationHeight,
        confirmedBlockHash: blockHash,
      );
    }
  }

  void _setBroadcastState(
    String txid,
    IronwoodPendingBroadcastState state, {
    required Set<IronwoodPendingBroadcastState> allowedFrom,
  }) {
    final index = _indexOf(txid);
    final record = _records[index];
    if (!allowedFrom.contains(record.broadcastState)) {
      throw IronwoodPendingSendException(
        IronwoodPendingSendRefusal.invalidTransition,
        'an Ironwood pending send in ${record.broadcastState.name} state '
        'cannot transition to ${state.name}',
      );
    }
    _records[index] = record._copyWith(broadcastState: state);
  }

  int _indexOf(String txid) {
    final index = _records.indexWhere(
      (record) => record.txid.toLowerCase() == txid.toLowerCase(),
    );
    if (index < 0) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.unknownTransaction,
        'unknown Ironwood pending transaction',
      );
    }
    return index;
  }

  @override
  Set<String> reservedNullifiersAt(int chainHeight) => Set.unmodifiable({
    for (final record in _records)
      if (record.sourcePool == ShieldedPendingSourcePool.ironwood &&
          !record.isExpiredAt(chainHeight))
        ...record.selectedNullifiers,
  });

  @override
  Set<String> reservedSaplingNullifiersAt(int chainHeight) => Set.unmodifiable({
    for (final record in _records)
      if (record.sourcePool == ShieldedPendingSourcePool.sapling &&
          !record.isExpiredAt(chainHeight))
        ...record.selectedNullifiers,
  });

  Map<String, Object?> toJson() => {
    'pending_send_state_version': version,
    'records': [for (final record in _records) record.toJson()],
  };

  factory IronwoodPendingSendState.fromJson(Map<String, Object?> json) {
    final documentVersion = json['pending_send_state_version'];
    if (documentVersion != 1 && documentVersion != version) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'unsupported Ironwood pending-send state version',
      );
    }
    final entries = json['records'];
    if (entries is! List) {
      throw const IronwoodPendingSendException(
        IronwoodPendingSendRefusal.malformed,
        'Ironwood pending-send state records must be a list',
      );
    }
    final state = IronwoodPendingSendState();
    for (final entry in entries) {
      if (entry is! Map) {
        throw const IronwoodPendingSendException(
          IronwoodPendingSendRefusal.malformed,
          'every Ironwood pending-send state record must be an object',
        );
      }
      final record = IronwoodPendingSendRecord.fromJson(
        entry.cast<String, Object?>(),
      );
      if (record.actualDestinationPool != IronwoodDestinationPool.ironwood) {
        throw const IronwoodPendingSendException(
          IronwoodPendingSendRefusal.malformed,
          'this pending-send state contains a non-Ironwood destination',
        );
      }
      if (state._records.any(
        (existing) => existing.txid.toLowerCase() == record.txid.toLowerCase(),
      )) {
        throw const IronwoodPendingSendException(
          IronwoodPendingSendRefusal.duplicateTransaction,
          'Ironwood pending-send state contains a duplicate transaction',
        );
      }
      for (final existing in state._records) {
        final lifetimesOverlap =
            record.createdHeight < existing.expiryHeight &&
            existing.createdHeight < record.expiryHeight;
        final notesOverlap =
            record.sourcePool == existing.sourcePool &&
            record.selectedNullifiers.any(existing.selectedNullifiers.contains);
        if (lifetimesOverlap && notesOverlap) {
          throw const IronwoodPendingSendException(
            IronwoodPendingSendRefusal.notesAlreadyReserved,
            'two Ironwood pending sends reserve the same note during '
            'overlapping transaction lifetimes',
          );
        }
      }
      state._records.add(record);
    }
    return state;
  }

  @override
  String toString() =>
      'IronwoodPendingSendState(recordCount: ${_records.length})';
}

void _validate({
  required String transactionHex,
  required String txid,
  required Set<String> nullifiers,
  required String recipient,
  required int amount,
  required int fee,
  required int expiry,
  required int created,
  int? confirmedHeight,
  String? confirmedHash,
}) {
  final confirmationIsPaired =
      (confirmedHeight == null) == (confirmedHash == null);
  if (!_isHex(transactionHex) ||
      transactionHex.isEmpty ||
      transactionHex.length.isOdd ||
      !_is32ByteHex(txid) ||
      nullifiers.isEmpty ||
      nullifiers.any((value) => !_is32ByteHex(value)) ||
      recipient.isEmpty ||
      amount <= 0 ||
      fee < 0 ||
      created < 0 ||
      expiry <= created ||
      !confirmationIsPaired ||
      (confirmedHeight != null && confirmedHeight < created) ||
      (confirmedHash != null && !_is32ByteHex(confirmedHash))) {
    throw const IronwoodPendingSendException(
      IronwoodPendingSendRefusal.malformed,
      'malformed Ironwood pending-send record',
    );
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'Ironwood pending-send record is missing a string field',
  );
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'Ironwood pending-send optional field must be a string',
  );
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'Ironwood pending-send record is missing an integer field',
  );
}

int? _optionalInteger(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'Ironwood pending-send optional field must be an integer',
  );
}

List<String> _strings(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is List && value.every((entry) => entry is String)) {
    return value.cast<String>();
  }
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'Ironwood pending-send nullifiers must be a string list',
  );
}

IronwoodDestinationPool _destination(Object? value) {
  for (final candidate in IronwoodDestinationPool.values) {
    if (candidate.name == value) return candidate;
  }
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'unknown Ironwood pending-send destination pool',
  );
}

ShieldedPendingSourcePool _sourcePool(Object? value) {
  for (final candidate in ShieldedPendingSourcePool.values) {
    if (candidate.name == value) return candidate;
  }
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'unknown shielded pending-send source pool',
  );
}

IronwoodPendingBroadcastState _broadcastState(Object? value) {
  for (final candidate in IronwoodPendingBroadcastState.values) {
    if (candidate.name == value) return candidate;
  }
  throw const IronwoodPendingSendException(
    IronwoodPendingSendRefusal.malformed,
    'unknown Ironwood pending-send broadcast state',
  );
}

bool _is32ByteHex(String value) => value.length == 64 && _isHex(value);

bool _isHex(String value) {
  for (final unit in value.codeUnits) {
    final digit = unit >= 0x30 && unit <= 0x39;
    final lower = unit >= 0x61 && unit <= 0x66;
    final upper = unit >= 0x41 && unit <= 0x46;
    if (!digit && !lower && !upper) return false;
  }
  return true;
}
