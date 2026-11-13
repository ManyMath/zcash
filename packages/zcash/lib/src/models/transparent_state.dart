import 'account.dart';
import 'address.dart';
import 'proposal.dart';
import 'spend.dart';
import 'transaction.dart';
import 'transparent_coins.dart';
import 'viewing_keys.dart';

enum ZcashTransparentReceiverScope { external, internal }

class ZcashTransparentReceiver {
  const ZcashTransparentReceiver({
    required this.address,
    required this.scope,
    required this.childIndex,
  });

  final String address;
  final ZcashTransparentReceiverScope scope;
  final int childIndex;

  Map<String, Object?> toJson() => {
    'address': address,
    'scope': scope.name,
    'child_index': childIndex,
  };

  factory ZcashTransparentReceiver.fromJson(Map<String, Object?> json) {
    final address = _requiredString(json, 'address');
    final scope = switch (_requiredString(json, 'scope')) {
      'external' => ZcashTransparentReceiverScope.external,
      'internal' => ZcashTransparentReceiverScope.internal,
      _ => throw const ZcashModelException(
        'transparent receiver scope is unknown',
      ),
    };
    final childIndex = _requiredInt(json, 'child_index');
    if (address.isEmpty || childIndex < 0) {
      throw const ZcashModelException(
        'transparent receiver address and child index must be valid',
      );
    }
    return ZcashTransparentReceiver(
      address: address,
      scope: scope,
      childIndex: childIndex,
    );
  }
}

enum ZcashTransparentSpendState { unspent, spent }

class ZcashTransparentOutputObservation {
  ZcashTransparentOutputObservation({
    required this.address,
    required this.protocolTxid,
    required this.outputIndex,
    required this.scriptHex,
    required this.valueZatoshis,
    required this.minedHeight,
    required this.blockHash,
    required this.blockTime,
    this.creationFeeZatoshis,
    required this.isCoinbase,
  }) {
    _validateOutput(
      address: address,
      protocolTxid: protocolTxid,
      outputIndex: outputIndex,
      scriptHex: scriptHex,
      valueZatoshis: valueZatoshis,
      minedHeight: minedHeight,
      blockHash: blockHash,
      blockTime: blockTime,
      feeZatoshis: creationFeeZatoshis,
    );
  }

  final String address;
  final String protocolTxid;
  final int outputIndex;
  final String scriptHex;
  final int valueZatoshis;
  final int minedHeight;
  final String blockHash;
  final int? blockTime;
  final int? creationFeeZatoshis;
  final bool isCoinbase;

  String get outpoint => '$protocolTxid:$outputIndex';
}

class ZcashTransparentSpendObservation {
  ZcashTransparentSpendObservation({
    required this.spentOutpoint,
    required this.spendingProtocolTxid,
    required this.spentHeight,
    required this.blockHash,
    required this.blockTime,
    required this.feeZatoshis,
  }) {
    final separator = spentOutpoint.lastIndexOf(':');
    if (separator <= 0 ||
        int.tryParse(spentOutpoint.substring(separator + 1)) == null ||
        spentHeight < 0 ||
        blockTime != null && blockTime! <= 0 ||
        feeZatoshis != null &&
            (feeZatoshis! < 0 || feeZatoshis! > maxMoneyZatoshis)) {
      throw const ZcashModelException(
        'transparent spend observation fields are invalid',
      );
    }
    _requireHash(
      spentOutpoint.substring(0, separator),
      'transparent spent outpoint txid',
    );
    _requireHash(spendingProtocolTxid, 'transparent spending txid');
    _requireHash(blockHash, 'transparent spend block hash');
  }

  final String spentOutpoint;
  final String spendingProtocolTxid;
  final int spentHeight;
  final String blockHash;
  final int? blockTime;
  final int? feeZatoshis;
}

class ZcashTransparentRefresh {
  ZcashTransparentRefresh({
    required this.network,
    required this.accountFingerprint,
    required List<String> queriedAddresses,
    required this.chainHeight,
    required this.chainTipHash,
    required Map<int, String> canonicalBlockHashes,
    required List<ZcashTransparentOutputObservation> unspentOutputs,
    List<ZcashTransparentOutputObservation> historicalOutputs = const [],
    required List<ZcashTransparentSpendObservation> observedSpends,
  }) : queriedAddresses = List.unmodifiable(queriedAddresses),
       canonicalBlockHashes = Map.unmodifiable(canonicalBlockHashes),
       unspentOutputs = List.unmodifiable(unspentOutputs),
       historicalOutputs = List.unmodifiable(historicalOutputs),
       observedSpends = List.unmodifiable(observedSpends);

  final ZcashAddressNetwork network;
  final String accountFingerprint;
  final List<String> queriedAddresses;
  final int chainHeight;
  final String chainTipHash;
  final Map<int, String> canonicalBlockHashes;
  final List<ZcashTransparentOutputObservation> unspentOutputs;
  final List<ZcashTransparentOutputObservation> historicalOutputs;
  final List<ZcashTransparentSpendObservation> observedSpends;
}

class ZcashTransparentOutput {
  const ZcashTransparentOutput._({
    required this.address,
    required this.protocolTxid,
    required this.outputIndex,
    required this.scriptHex,
    required this.valueZatoshis,
    required this.minedHeight,
    required this.blockHash,
    required this.blockTime,
    required this.creationFeeZatoshis,
    required this.isCoinbase,
    required this.spendState,
    this.spendingProtocolTxid,
    this.spentHeight,
    this.spentBlockHash,
    this.spentBlockTime,
    this.feeZatoshis,
  });

  factory ZcashTransparentOutput.unspent(
    ZcashTransparentOutputObservation observation,
  ) => ZcashTransparentOutput._(
    address: observation.address,
    protocolTxid: observation.protocolTxid,
    outputIndex: observation.outputIndex,
    scriptHex: observation.scriptHex,
    valueZatoshis: observation.valueZatoshis,
    minedHeight: observation.minedHeight,
    blockHash: observation.blockHash,
    blockTime: observation.blockTime,
    creationFeeZatoshis: observation.creationFeeZatoshis,
    isCoinbase: observation.isCoinbase,
    spendState: ZcashTransparentSpendState.unspent,
  );

  final String address;
  final String protocolTxid;
  final int outputIndex;
  final String scriptHex;
  final int valueZatoshis;
  final int minedHeight;
  final String blockHash;
  final int? blockTime;
  final int? creationFeeZatoshis;
  final bool isCoinbase;
  final ZcashTransparentSpendState spendState;
  final String? spendingProtocolTxid;
  final int? spentHeight;
  final String? spentBlockHash;
  final int? spentBlockTime;
  final int? feeZatoshis;

  String get outpoint => '$protocolTxid:$outputIndex';
  String get txid => reverseTxidByteOrder(protocolTxid);

  AddressUtxo get utxo => AddressUtxo(
    address: address,
    txid: txid,
    outputIndex: outputIndex,
    script: scriptHex,
    satoshis: valueZatoshis,
    height: minedHeight,
  );

  Map<String, Object?> toJson() => {
    'address': address,
    'protocol_txid': protocolTxid,
    'output_index': outputIndex,
    'script_hex': scriptHex,
    'value_zatoshis': valueZatoshis,
    'mined_height': minedHeight,
    'block_hash': blockHash,
    'block_time': blockTime,
    'creation_fee_zatoshis': creationFeeZatoshis,
    'is_coinbase': isCoinbase,
    'spend_state': spendState.name,
    'spending_protocol_txid': spendingProtocolTxid,
    'spent_height': spentHeight,
    'spent_block_hash': spentBlockHash,
    'spent_block_time': spentBlockTime,
    'fee_zatoshis': feeZatoshis,
  };

  factory ZcashTransparentOutput.fromJson(Map<String, Object?> json) {
    final output = ZcashTransparentOutput._(
      address: _requiredString(json, 'address'),
      protocolTxid: _requiredString(json, 'protocol_txid'),
      outputIndex: _requiredInt(json, 'output_index'),
      scriptHex: _requiredString(json, 'script_hex'),
      valueZatoshis: _requiredInt(json, 'value_zatoshis'),
      minedHeight: _requiredInt(json, 'mined_height'),
      blockHash: _requiredString(json, 'block_hash'),
      blockTime: _optionalInt(json, 'block_time'),
      creationFeeZatoshis: _optionalInt(json, 'creation_fee_zatoshis'),
      isCoinbase: _requiredBool(json, 'is_coinbase'),
      spendState: switch (_requiredString(json, 'spend_state')) {
        'unspent' => ZcashTransparentSpendState.unspent,
        'spent' => ZcashTransparentSpendState.spent,
        _ => throw const ZcashModelException(
          'transparent output spend state is unknown',
        ),
      },
      spendingProtocolTxid: _optionalString(json, 'spending_protocol_txid'),
      spentHeight: _optionalInt(json, 'spent_height'),
      spentBlockHash: _optionalString(json, 'spent_block_hash'),
      spentBlockTime: _optionalInt(json, 'spent_block_time'),
      feeZatoshis: _optionalInt(json, 'fee_zatoshis'),
    );
    _validateOutput(
      address: output.address,
      protocolTxid: output.protocolTxid,
      outputIndex: output.outputIndex,
      scriptHex: output.scriptHex,
      valueZatoshis: output.valueZatoshis,
      minedHeight: output.minedHeight,
      blockHash: output.blockHash,
      blockTime: output.blockTime,
      feeZatoshis: output.creationFeeZatoshis,
    );
    output._validateSpendFields();
    return output;
  }

  void _validateSpendFields() {
    if (spendState == ZcashTransparentSpendState.unspent) {
      if (spendingProtocolTxid != null ||
          spentHeight != null ||
          spentBlockHash != null ||
          spentBlockTime != null ||
          feeZatoshis != null) {
        throw const ZcashModelException(
          'an unspent transparent output cannot carry spend metadata',
        );
      }
      return;
    }
    if (spendingProtocolTxid != null) {
      _requireHash(spendingProtocolTxid!, 'transparent spending txid');
    }
    if ((spentHeight == null) != (spentBlockHash == null)) {
      throw const ZcashModelException(
        'transparent spend height and block hash must be paired',
      );
    }
    if (spentHeight != null && spentHeight! < minedHeight ||
        spentBlockTime != null && spentBlockTime! <= 0 ||
        feeZatoshis != null &&
            (feeZatoshis! < 0 || feeZatoshis! > maxMoneyZatoshis)) {
      throw const ZcashModelException(
        'transparent output spend metadata is invalid',
      );
    }
    if (spentBlockHash != null) {
      _requireHash(spentBlockHash!, 'transparent spend block hash');
    }
  }
}

class ZcashTransparentState {
  ZcashTransparentState._({
    required this.network,
    required this.accountFingerprint,
    required List<ZcashTransparentReceiver> receivers,
    List<ZcashTransparentOutput> outputs = const [],
    this.refreshedThroughHeight,
    this.refreshedThroughBlockHash,
  }) : _receivers = List.of(receivers),
       _outputs = {for (final output in outputs) output.outpoint: output};

  factory ZcashTransparentState.empty({
    required ZcashAddressNetwork network,
    required String accountFingerprint,
  }) {
    if (accountFingerprint.isEmpty) {
      throw ArgumentError.value(
        accountFingerprint,
        'accountFingerprint',
        'must not be empty',
      );
    }
    return ZcashTransparentState._(
      network: network,
      accountFingerprint: accountFingerprint,
      receivers: const [],
    );
  }

  factory ZcashTransparentState.fromAccount({
    required ZcashAccountMetadata account,
    required ZcashViewingKeys viewingKeys,
    Iterable<ZcashTransparentReceiver> additionalReceivers = const [],
  }) {
    if (viewingKeys.network != account.network) {
      throw ArgumentError('viewing keys belong to a different network');
    }
    if (viewingKeys.accountIndex != account.accountIndex) {
      throw ArgumentError('viewing keys belong to a different account');
    }
    final transparent = viewingKeys.transparent;
    final address = transparent.defaultExternalAddress;
    final index = transparent.defaultExternalIndex;
    final additional = [...additionalReceivers];
    if (!account.hasTransparent || !transparent.available) {
      if (additional.isNotEmpty) {
        throw ArgumentError(
          'an account without transparent viewing material cannot register '
          'transparent receivers',
        );
      }
      return ZcashTransparentState.empty(
        network: account.network,
        accountFingerprint: account.fingerprint,
      );
    }
    if (address == null || address.isEmpty || index == null || index < 0) {
      throw ArgumentError(
        'available transparent viewing keys must name their default receiver',
      );
    }
    final receivers = [
      ZcashTransparentReceiver(
        address: address,
        scope: ZcashTransparentReceiverScope.external,
        childIndex: index,
      ),
      ...additional,
    ]..sort(_compareReceivers);
    _validateReceivers(receivers);
    return ZcashTransparentState._(
      network: account.network,
      accountFingerprint: account.fingerprint,
      receivers: receivers,
    );
  }

  static const version = 1;

  final ZcashAddressNetwork network;
  final String accountFingerprint;
  final List<ZcashTransparentReceiver> _receivers;
  final Map<String, ZcashTransparentOutput> _outputs;
  int? refreshedThroughHeight;
  String? refreshedThroughBlockHash;

  List<ZcashTransparentReceiver> get receivers => List.unmodifiable(_receivers);

  List<String> get addresses =>
      List.unmodifiable(receivers.map((receiver) => receiver.address));

  void registerAccountReceivers({
    required ZcashAccountMetadata account,
    required ZcashViewingKeys viewingKeys,
    Iterable<ZcashTransparentReceiver> additionalReceivers = const [],
  }) {
    final discovered = ZcashTransparentState.fromAccount(
      account: account,
      viewingKeys: viewingKeys,
      additionalReceivers: additionalReceivers,
    );
    if (discovered.network != network ||
        discovered.accountFingerprint != accountFingerprint) {
      throw const ZcashModelException(
        'discovered transparent receivers belong to a different wallet',
      );
    }
    final combined = <String, ZcashTransparentReceiver>{
      for (final receiver in _receivers) receiver.address: receiver,
    };
    for (final receiver in discovered.receivers) {
      final existing = combined[receiver.address];
      if (existing != null &&
          (existing.scope != receiver.scope ||
              existing.childIndex != receiver.childIndex)) {
        throw const ZcashModelException(
          'a transparent address cannot change its derivation identity',
        );
      }
      combined[receiver.address] = receiver;
    }
    final next = combined.values.toList()..sort(_compareReceivers);
    _validateReceivers(next);
    _receivers
      ..clear()
      ..addAll(next);
  }

  List<ZcashTransparentOutput> get outputs {
    final result = [..._outputs.values]..sort(_compareOutputs);
    return List.unmodifiable(result);
  }

  List<ZcashTransparentOutput> get unspentOutputs => List.unmodifiable(
    outputs.where(
      (output) => output.spendState == ZcashTransparentSpendState.unspent,
    ),
  );

  TransparentCoinSet get coinSet => TransparentCoinSet.fromUtxos(
    utxos: unspentOutputs.map((output) => output.utxo),
    chainHeight: refreshedThroughHeight ?? 0,
    coinbaseOutpoints: {
      for (final output in unspentOutputs)
        if (output.isCoinbase) '${output.txid}:${output.outputIndex}',
    },
  );

  void applyRefresh(ZcashTransparentRefresh refresh) {
    if (refresh.network != network) {
      throw const ZcashModelException(
        'transparent refresh belongs to a different network',
      );
    }
    if (refresh.accountFingerprint != accountFingerprint) {
      throw const ZcashModelException(
        'transparent refresh belongs to a different account',
      );
    }
    final queried = refresh.queriedAddresses.toSet();
    final known = addresses.toSet();
    if (queried.length != refresh.queriedAddresses.length ||
        queried.difference(known).isNotEmpty ||
        known.difference(queried).isNotEmpty) {
      throw const ZcashModelException(
        'transparent refresh did not query the exact receiver inventory',
      );
    }
    _requireHash(refresh.chainTipHash, 'chain tip hash');
    if (refresh.chainHeight < 0 ||
        refresh.canonicalBlockHashes[refresh.chainHeight] !=
            refresh.chainTipHash) {
      throw const ZcashModelException(
        'transparent refresh tip is not bound to its canonical block hash',
      );
    }
    final previousHeight = refreshedThroughHeight;
    final previousHash = refreshedThroughBlockHash;
    if (previousHeight != null &&
        refresh.canonicalBlockHashes[previousHeight] != previousHash) {
      throw ZcashModelException(
        'transparent state reached height $previousHeight at $previousHash, '
        'which is not the canonical block in this refresh. Roll back to the '
        'verified fork before applying replacement-chain outputs.',
      );
    }

    final spends = <String, ZcashTransparentSpendObservation>{};
    for (final spend in refresh.observedSpends) {
      if (spend.spentHeight > refresh.chainHeight ||
          refresh.canonicalBlockHashes[spend.spentHeight] != spend.blockHash) {
        throw const ZcashModelException(
          'transparent spend is not bound to its canonical block',
        );
      }
      if (spends.containsKey(spend.spentOutpoint)) {
        throw const ZcashModelException(
          'transparent refresh returned the same spend twice',
        );
      }
      spends[spend.spentOutpoint] = spend;
    }

    final next = <String, ZcashTransparentOutput>{};
    for (final observation in refresh.unspentOutputs) {
      if (!known.contains(observation.address)) {
        throw const ZcashModelException(
          'transparent refresh returned an output for an unknown receiver',
        );
      }
      if (observation.minedHeight > refresh.chainHeight ||
          refresh.canonicalBlockHashes[observation.minedHeight] !=
              observation.blockHash) {
        throw const ZcashModelException(
          'transparent output is not bound to the canonical creation block',
        );
      }
      if (next.containsKey(observation.outpoint)) {
        throw const ZcashModelException(
          'transparent refresh returned the same outpoint twice',
        );
      }
      if (spends.containsKey(observation.outpoint)) {
        throw const ZcashModelException(
          'transparent refresh calls one outpoint both spent and unspent',
        );
      }
      final existing = _outputs[observation.outpoint];
      if (existing != null &&
          (existing.address != observation.address ||
              existing.scriptHex != observation.scriptHex ||
              existing.valueZatoshis != observation.valueZatoshis ||
              existing.minedHeight != observation.minedHeight ||
              existing.blockHash != observation.blockHash ||
              existing.blockTime != observation.blockTime ||
              existing.isCoinbase != observation.isCoinbase)) {
        throw const ZcashModelException(
          'canonical transparent outpoint changed immutable output data',
        );
      }
      next[observation.outpoint] = ZcashTransparentOutput.unspent(observation);
    }
    for (final observation in refresh.historicalOutputs) {
      if (!known.contains(observation.address)) {
        throw const ZcashModelException(
          'transparent history returned an output for an unknown receiver',
        );
      }
      if (observation.minedHeight > refresh.chainHeight ||
          refresh.canonicalBlockHashes[observation.minedHeight] !=
              observation.blockHash) {
        throw const ZcashModelException(
          'historical transparent output is not bound to its canonical block',
        );
      }
      if (next.containsKey(observation.outpoint)) {
        throw const ZcashModelException(
          'transparent refresh returned the same outpoint twice',
        );
      }
      final spend = spends[observation.outpoint];
      if (spend == null) {
        throw const ZcashModelException(
          'historical transparent output must have an authenticated spend',
        );
      }
      if (spend.spentHeight < observation.minedHeight) {
        throw const ZcashModelException(
          'historical transparent output cannot be spent before creation',
        );
      }
      final existing = _outputs[observation.outpoint];
      if (existing != null &&
          (existing.address != observation.address ||
              existing.scriptHex != observation.scriptHex ||
              existing.valueZatoshis != observation.valueZatoshis ||
              existing.minedHeight != observation.minedHeight ||
              existing.blockHash != observation.blockHash ||
              existing.blockTime != observation.blockTime ||
              existing.isCoinbase != observation.isCoinbase)) {
        throw const ZcashModelException(
          'canonical transparent outpoint changed immutable output data',
        );
      }
      next[observation.outpoint] = ZcashTransparentOutput._(
        address: observation.address,
        protocolTxid: observation.protocolTxid,
        outputIndex: observation.outputIndex,
        scriptHex: observation.scriptHex,
        valueZatoshis: observation.valueZatoshis,
        minedHeight: observation.minedHeight,
        blockHash: observation.blockHash,
        blockTime: observation.blockTime,
        creationFeeZatoshis: observation.creationFeeZatoshis,
        isCoinbase: observation.isCoinbase,
        spendState: ZcashTransparentSpendState.spent,
        spendingProtocolTxid: spend.spendingProtocolTxid,
        spentHeight: spend.spentHeight,
        spentBlockHash: spend.blockHash,
        spentBlockTime: spend.blockTime,
        feeZatoshis: spend.feeZatoshis,
      );
    }
    for (final existing in _outputs.values) {
      if (next.containsKey(existing.outpoint)) continue;
      final spend = spends[existing.outpoint];
      next[existing.outpoint] = ZcashTransparentOutput._(
        address: existing.address,
        protocolTxid: existing.protocolTxid,
        outputIndex: existing.outputIndex,
        scriptHex: existing.scriptHex,
        valueZatoshis: existing.valueZatoshis,
        minedHeight: existing.minedHeight,
        blockHash: existing.blockHash,
        blockTime: existing.blockTime,
        creationFeeZatoshis: existing.creationFeeZatoshis,
        isCoinbase: existing.isCoinbase,
        spendState: ZcashTransparentSpendState.spent,
        spendingProtocolTxid:
            spend?.spendingProtocolTxid ?? existing.spendingProtocolTxid,
        spentHeight: spend?.spentHeight ?? existing.spentHeight,
        spentBlockHash: spend?.blockHash ?? existing.spentBlockHash,
        spentBlockTime: spend?.blockTime ?? existing.spentBlockTime,
        feeZatoshis: spend?.feeZatoshis ?? existing.feeZatoshis,
      );
    }

    _outputs
      ..clear()
      ..addAll(next);
    refreshedThroughHeight = refresh.chainHeight;
    refreshedThroughBlockHash = refresh.chainTipHash;
  }

  void rollbackTo({required int height, required String blockHash}) {
    _requireHash(blockHash, 'transparent rollback block hash');
    final through = refreshedThroughHeight;
    if (height < 0 || through == null || height > through) {
      throw const ZcashModelException(
        'transparent rollback height must be within the refreshed chain',
      );
    }
    final rolledBack = <String, ZcashTransparentOutput>{};
    for (final output in _outputs.values) {
      if (output.minedHeight > height) continue;
      final spendHeight = output.spentHeight;
      if (spendHeight != null && spendHeight > height) {
        rolledBack[output.outpoint] = ZcashTransparentOutput._(
          address: output.address,
          protocolTxid: output.protocolTxid,
          outputIndex: output.outputIndex,
          scriptHex: output.scriptHex,
          valueZatoshis: output.valueZatoshis,
          minedHeight: output.minedHeight,
          blockHash: output.blockHash,
          blockTime: output.blockTime,
          creationFeeZatoshis: output.creationFeeZatoshis,
          isCoinbase: output.isCoinbase,
          spendState: ZcashTransparentSpendState.unspent,
        );
      } else {
        rolledBack[output.outpoint] = output;
      }
    }
    _outputs
      ..clear()
      ..addAll(rolledBack);
    refreshedThroughHeight = height;
    refreshedThroughBlockHash = blockHash;
  }

  Map<String, Object?> toJson() => {
    'transparent_state_version': version,
    'network': network.name,
    'account_fingerprint': accountFingerprint,
    'receivers': receivers.map((receiver) => receiver.toJson()).toList(),
    'outputs': outputs.map((output) => output.toJson()).toList(),
    'refreshed_through_height': refreshedThroughHeight,
    'refreshed_through_block_hash': refreshedThroughBlockHash,
  };

  factory ZcashTransparentState.fromJson(Map<String, Object?> json) {
    if (json['transparent_state_version'] != version) {
      throw const ZcashModelException(
        'transparent state schema version is unsupported',
      );
    }
    final networkValue = _requiredString(json, 'network');
    final ZcashAddressNetwork network;
    try {
      network = ZcashAddressNetwork.fromJson(networkValue);
    } on FormatException {
      throw const ZcashModelException('transparent state network is unknown');
    }
    final receivers = _objectList(
      json,
      'receivers',
    ).map(ZcashTransparentReceiver.fromJson).toList()..sort(_compareReceivers);
    _validateReceivers(receivers);
    final outputs = _objectList(
      json,
      'outputs',
    ).map(ZcashTransparentOutput.fromJson).toList();
    final state = ZcashTransparentState._(
      network: network,
      accountFingerprint: _requiredString(json, 'account_fingerprint'),
      receivers: receivers,
      outputs: outputs,
      refreshedThroughHeight: _optionalInt(json, 'refreshed_through_height'),
      refreshedThroughBlockHash: _optionalString(
        json,
        'refreshed_through_block_hash',
      ),
    );
    if ((state.refreshedThroughHeight == null) !=
        (state.refreshedThroughBlockHash == null)) {
      throw const ZcashModelException(
        'transparent state refresh height and block hash must be paired',
      );
    }
    if (state.refreshedThroughBlockHash != null) {
      _requireHash(state.refreshedThroughBlockHash!, 'refresh block hash');
    }
    if (state.accountFingerprint.isEmpty) {
      throw const ZcashModelException(
        'transparent state account fingerprint must not be empty',
      );
    }
    if (state.outputs.length != outputs.length) {
      throw const ZcashModelException(
        'transparent state contains a duplicate outpoint',
      );
    }
    final addresses = state.addresses.toSet();
    final through = state.refreshedThroughHeight;
    for (final output in state.outputs) {
      if (!addresses.contains(output.address)) {
        throw const ZcashModelException(
          'transparent output belongs to an unregistered receiver',
        );
      }
      if (through == null ||
          output.minedHeight > through ||
          output.spentHeight != null && output.spentHeight! > through) {
        throw const ZcashModelException(
          'transparent output lies beyond the persisted refresh frontier',
        );
      }
    }
    return state;
  }
}

int _compareOutputs(ZcashTransparentOutput a, ZcashTransparentOutput b) {
  final byHeight = a.minedHeight.compareTo(b.minedHeight);
  if (byHeight != 0) return byHeight;
  final byTxid = a.protocolTxid.compareTo(b.protocolTxid);
  return byTxid != 0 ? byTxid : a.outputIndex.compareTo(b.outputIndex);
}

int _compareReceivers(ZcashTransparentReceiver a, ZcashTransparentReceiver b) {
  final byScope = a.scope.index.compareTo(b.scope.index);
  return byScope != 0 ? byScope : a.childIndex.compareTo(b.childIndex);
}

void _validateReceivers(Iterable<ZcashTransparentReceiver> receivers) {
  final addresses = <String>{};
  final derivations = <(ZcashTransparentReceiverScope, int)>{};
  for (final receiver in receivers) {
    if (receiver.address.isEmpty || receiver.childIndex < 0) {
      throw const ZcashModelException(
        'transparent receiver address and child index must be valid',
      );
    }
    if (!addresses.add(receiver.address) ||
        !derivations.add((receiver.scope, receiver.childIndex))) {
      throw const ZcashModelException(
        'transparent receiver inventory contains a duplicate',
      );
    }
  }
}

void _validateOutput({
  required String address,
  required String protocolTxid,
  required int outputIndex,
  required String scriptHex,
  required int valueZatoshis,
  required int minedHeight,
  required String blockHash,
  required int? blockTime,
  int? feeZatoshis,
}) {
  if (address.isEmpty ||
      outputIndex < 0 ||
      valueZatoshis < 0 ||
      valueZatoshis > maxMoneyZatoshis ||
      minedHeight < 0 ||
      blockTime != null && blockTime <= 0) {
    throw const ZcashModelException('transparent output fields are invalid');
  }
  _requireHash(protocolTxid, 'transparent output txid');
  _requireHash(blockHash, 'transparent output block hash');
  _requireEvenHex(scriptHex, 'transparent output script');
  if (feeZatoshis != null &&
      (feeZatoshis < 0 || feeZatoshis > maxMoneyZatoshis)) {
    throw const ZcashModelException(
      'transparent output fee metadata is invalid',
    );
  }
}

void _requireHash(String value, String field) {
  if (value.length != 64) {
    throw ZcashModelException('$field must be 32-byte hex');
  }
  _requireEvenHex(value, field);
}

void _requireEvenHex(String value, String field) {
  if (value.isEmpty ||
      value.length.isOdd ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
    throw ZcashModelException('$field must be even-length hex');
  }
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is String) return value;
  throw ZcashModelException('"$field" must be a string');
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null || value is String) return value as String?;
  throw ZcashModelException('"$field" must be a string or null');
}

int _requiredInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is int) return value;
  throw ZcashModelException('"$field" must be an integer');
}

int? _optionalInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null || value is int) return value as int?;
  throw ZcashModelException('"$field" must be an integer or null');
}

bool _requiredBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is bool) return value;
  throw ZcashModelException('"$field" must be a boolean');
}

List<Map<String, Object?>> _objectList(
  Map<String, Object?> json,
  String field,
) {
  final value = json[field];
  if (value is! List) throw ZcashModelException('"$field" must be a list');
  return value.map((entry) {
    if (entry is Map<String, Object?>) return entry;
    if (entry is Map) return entry.cast<String, Object?>();
    throw ZcashModelException('"$field" entries must be objects');
  }).toList();
}
