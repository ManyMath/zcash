@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

import 'zcashd_harness.dart';

const _kHarnessSaplingActivationHeight = 1;

void main() {
  ZcashdHarness? harness;

  setUpAll(() async {
    if (!Platform.environment.containsKey('ZCASHD_INTEGRATION')) return;
    harness = await ZcashdHarness.start();
  });

  tearDownAll(() async {
    if (harness == null) return;
    await harness!.shutdown();
    harness = null;
  });

  test('skips live zcashd work unless explicitly enabled', () {
    if (Platform.environment.containsKey('ZCASHD_INTEGRATION')) return;
    expect(harness, isNull);
  });

  test('redacts zcashd diagnostic exception fields', () {
    const rpcPassword = 'rpc-password-that-must-not-leak-1234567890';
    const authHeader = 'Authorization: Basic dXNlcjpzZWNyZXQ=';
    final diagnostic = ZcashdHarnessException(
      'synthetic failure rpcpassword=$rpcPassword $authHeader',
      phase: 'redaction-check',
      rpcPort: 18232,
      launch:
          'docker image electriccoinco/zcashd@sha256:'
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      cause: 'rpcuser=alice rpcpassword=$rpcPassword $authHeader',
      stdoutTail: 'rpcpassword=$rpcPassword',
      stderrTail: authHeader,
    ).toString();

    expect(diagnostic, contains('phase=redaction-check'));
    expect(diagnostic, isNot(contains(rpcPassword)));
    expect(diagnostic, isNot(contains('dXNlcjpzZWNyZXQ')));
    expect(diagnostic, contains('rpcpassword=<redacted>'));
    expect(diagnostic, contains('Authorization: Basic <redacted>'));
  });

  test(
    'starts zcashd, derives an account address, and mines a block',
    () async {
      if (harness == null) return;

      expect(harness!.rpcPort, greaterThan(0));
      expect(harness!.zcashdVersion, isNotEmpty);

      final account = await harness!.client.zGetNewAccount();
      expect(account, greaterThanOrEqualTo(0));

      final address = await harness!.client.zGetAddressForAccount(account);
      expect(address, startsWith('u'));

      final before = await harness!.getBlockCount();
      final hashes = await harness!.mineBlocks(1);
      expect(hashes, hasLength(1));
      expect(hashes.single, matches(RegExp(r'^[0-9a-fA-F]{64}$')));

      final after = await harness!.getBlockCount();
      expect(after, equals(before + 1));
    },
  );

  test('mature coinbase balance becomes spendable', () async {
    if (harness == null) return;

    final proof = await _ensureMatureCoinbaseFunds(harness!);

    expect(
      proof.hashes,
      hasLength(proof.requestedBlocks),
      reason:
          'generated hash count must match requested maturity mining; '
          'requestedBlocks=${proof.requestedBlocks} '
          'observedHashes=${proof.hashes.length} '
          'initialHeight=${proof.initialHeight} '
          'finalHeight=${proof.finalHeight}',
    );
    expect(
      proof.heightDelta,
      equals(proof.requestedBlocks),
      reason:
          'block height delta must prove fresh maturity mining; '
          'requestedBlocks=${proof.requestedBlocks} '
          'heightDelta=${proof.heightDelta} '
          'initialHeight=${proof.initialHeight} '
          'finalHeight=${proof.finalHeight}',
    );
    expect(
      proof.finalSpendable,
      greaterThan(0),
      reason:
          'coinbase funds should be spendable after maturity; '
          'requestedBlocks=${proof.requestedBlocks} '
          'heightDelta=${proof.heightDelta} '
          'initialSpendable=${proof.initialSpendable} '
          'finalSpendable=${proof.finalSpendable}',
    );
  });

  test('shieldcoinbase transaction enters mempool and confirms', () async {
    if (harness == null) return;

    final maturity = await _ensureMatureCoinbaseFunds(harness!);
    final sapling = await _ensureSaplingActive(harness!);
    final toAddress = await _newShieldedAddress(harness!);
    final beforeHeight = await harness!.getBlockCount();

    ShieldCoinbaseResult? shield;
    ZcashOperationStatus? finalStatus;
    List<String> mempoolBeforeMining = const [];
    List<String> mempoolAfterMining = const [];
    List<String> minedHashes = const [];
    Map<String, dynamic> minedBlock = const <String, dynamic>{};
    Map<String, dynamic> minedTx = const <String, dynamic>{};

    try {
      final shieldResult = await harness!.client.zShieldCoinbase(
        '*',
        toAddress,
        feeZatoshis: 100000,
        limit: 1,
      );
      shield = shieldResult;
      expect(
        shieldResult.operationId,
        startsWith('opid-'),
        reason:
            'z_shieldcoinbase should return a concrete operation id; '
            'toAddressPrefix=${_addressPrefix(toAddress)} '
            'rpcPort=${harness!.rpcPort} version=${harness!.zcashdVersion}',
      );

      final operationStatus = await harness!.client.waitForOperation(
        shieldResult.operationId,
        timeout: const Duration(minutes: 2),
      );
      finalStatus = operationStatus;
      final shieldTxid = operationStatus.txid ?? '';
      expect(
        shieldTxid,
        matches(RegExp(r'^[0-9a-fA-F]{64}$')),
        reason:
            'successful z_shieldcoinbase operation must expose txid; '
            'opid=${shieldResult.operationId} status=${operationStatus.status} '
            'result=${operationStatus.result}',
      );

      mempoolBeforeMining = await _rawMempoolTxids(harness!);
      expect(
        mempoolBeforeMining,
        contains(shieldTxid),
        reason:
            'shieldcoinbase txid must enter mempool before mining; '
            'opid=${shieldResult.operationId} status=${operationStatus.status} '
            'txid=$shieldTxid mempool=$mempoolBeforeMining '
            'rpcPort=${harness!.rpcPort}',
      );

      minedHashes = await harness!.mineBlocks(1);
      final minedHash = minedHashes.single;
      final afterHeight = await harness!.getBlockCount();
      mempoolAfterMining = await _rawMempoolTxids(harness!);
      minedBlock = await _readBlock(harness!, minedHash);
      minedTx = await _readTransaction(harness!, shieldTxid);

      expect(
        afterHeight,
        equals(beforeHeight + 1),
        reason:
            'confirmation mining should advance exactly one block; '
            'beforeHeight=$beforeHeight afterHeight=$afterHeight '
            'minedHash=$minedHash txid=$shieldTxid',
      );
      expect(
        mempoolAfterMining,
        isNot(contains(shieldTxid)),
        reason:
            'shieldcoinbase txid should leave mempool after mining; '
            'txid=$shieldTxid minedHash=$minedHash '
            'mempoolAfterMining=$mempoolAfterMining',
      );
      expect(
        _blockTxids(minedBlock),
        contains(shieldTxid),
        reason:
            'mined block must list shieldcoinbase txid; '
            'txid=$shieldTxid minedHash=$minedHash block=$minedBlock',
      );
      expect(
        minedTx['blockhash'],
        equals(minedHash),
        reason:
            'verbose raw transaction should point at the mined block; '
            'txid=$shieldTxid minedHash=$minedHash tx=$minedTx',
      );
      expect(
        _numericField(minedTx, 'confirmations'),
        equals(1),
        reason:
            'shieldcoinbase tx should have exactly one confirmation; '
            'txid=$shieldTxid minedHash=$minedHash tx=$minedTx',
      );
    } on Object catch (error) {
      final currentHeight = await _safeHeight(harness!);
      fail(
        'shieldcoinbase mempool-to-confirmation proof failed; '
        'matureInitialHeight=${maturity.initialHeight} '
        'matureFinalHeight=${maturity.finalHeight} '
        'saplingInitialHeight=${sapling.initialHeight} '
        'saplingFinalHeight=${sapling.finalHeight} '
        'saplingActivationHeight=${sapling.activationHeight} '
        'saplingStatus=${sapling.status} '
        'currentHeight=$currentHeight beforeHeight=$beforeHeight '
        'opid=${_tryOperationId(shield)} status=${_tryStatus(finalStatus)} '
        'txid=${_tryTxid(finalStatus)} '
        'mempoolBeforeMining=$mempoolBeforeMining '
        'minedHashes=$minedHashes mempoolAfterMining=$mempoolAfterMining '
        'minedBlockHash=${minedBlock['hash'] ?? minedBlock['blockhash']} '
        'minedBlockHeight=${minedBlock['height']} '
        'confirmations=${minedTx['confirmations']} '
        'rpcPort=${harness!.rpcPort} version=${harness!.zcashdVersion} '
        'error=$error\n'
        '${harness!.diagnosticSummary(phase: 'shieldcoinbase-confirmation')}',
      );
    }
  });
}

class _MaturityProof {
  final int requestedBlocks;
  final int initialHeight;
  final Object initialSpendable;
  final List<String> hashes;
  final int finalHeight;
  final int finalSpendable;

  const _MaturityProof({
    required this.requestedBlocks,
    required this.initialHeight,
    required this.initialSpendable,
    required this.hashes,
    required this.finalHeight,
    required this.finalSpendable,
  });

  int get heightDelta => finalHeight - initialHeight;
}

Future<_MaturityProof> _ensureMatureCoinbaseFunds(ZcashdHarness harness) async {
  const maturityBlocks = 101;
  final initialHeight = await harness.getBlockCount();
  final initialSpendable = await _tryReadSpendableBalance(
    harness,
    phase: 'pre-maturity',
    initialHeight: initialHeight,
    requestedBlocks: maturityBlocks,
  );

  if (initialHeight < 100 && initialSpendable is int) {
    expect(
      initialSpendable,
      equals(0),
      reason:
          'pre-maturity spendable balance should be zero; '
          'initialHeight=$initialHeight initialSpendable=$initialSpendable',
    );
  }

  try {
    final shouldMine = initialSpendable is! int || initialSpendable <= 0;
    final requestedBlocks = shouldMine ? maturityBlocks : 0;
    final hashes = shouldMine
        ? await harness
              .mineBlocks(maturityBlocks)
              .timeout(
                const Duration(minutes: 2),
                onTimeout: () => throw TimeoutException(
                  'timed out during maturity mining step; '
                  'requestedBlocks=$maturityBlocks initialHeight=$initialHeight '
                  'rpcPort=${harness.rpcPort} version=${harness.zcashdVersion}',
                ),
              )
        : <String>[];
    final finalHeight = await harness.getBlockCount();
    final finalSpendable = await _readSpendableBalance(
      harness,
      phase: 'post-maturity',
      initialHeight: initialHeight,
      requestedBlocks: requestedBlocks,
    );
    return _MaturityProof(
      requestedBlocks: requestedBlocks,
      initialHeight: initialHeight,
      initialSpendable: initialSpendable,
      hashes: hashes,
      finalHeight: finalHeight,
      finalSpendable: finalSpendable,
    );
  } on Object catch (error) {
    final currentHeight = await _safeHeight(harness);
    final currentBalance = await _safeBalance(harness);
    fail(
      'mature coinbase balance proof failed; '
      'requestedBlocks=$maturityBlocks initialHeight=$initialHeight '
      'currentHeight=$currentHeight initialSpendable=$initialSpendable '
      'currentSpendable=$currentBalance rpcPort=${harness.rpcPort} '
      'version=${harness.zcashdVersion} error=$error\n'
      '${harness.diagnosticSummary(phase: 'maturity-mining')}',
    );
  }
}

class _ActivationProof {
  final int initialHeight;
  final int finalHeight;
  final int? activationHeight;
  final String status;
  final List<String> hashes;

  const _ActivationProof({
    required this.initialHeight,
    required this.finalHeight,
    required this.activationHeight,
    required this.status,
    required this.hashes,
  });
}

Future<_ActivationProof> _ensureSaplingActive(ZcashdHarness harness) async {
  final initialHeight = await harness.getBlockCount();
  final initialInfo = await harness.getBlockchainInfo();
  final initialSapling = _upgradeInfo(initialInfo, 'Sapling');
  if (_upgradeIsActive(initialSapling, initialHeight)) {
    return _ActivationProof(
      initialHeight: initialHeight,
      finalHeight: initialHeight,
      activationHeight: _upgradeActivationHeight(initialSapling),
      status: _upgradeStatus(initialSapling),
      hashes: const [],
    );
  }

  final activationHeight =
      _upgradeActivationHeight(initialSapling) ??
      _kHarnessSaplingActivationHeight;
  if (initialHeight >= activationHeight) {
    return _ActivationProof(
      initialHeight: initialHeight,
      finalHeight: initialHeight,
      activationHeight: activationHeight,
      status: _upgradeStatus(initialSapling),
      hashes: const [],
    );
  }

  final blocksToMine = activationHeight - initialHeight;
  try {
    final hashes = await harness
        .mineBlocks(blocksToMine)
        .timeout(
          const Duration(minutes: 3),
          onTimeout: () => throw TimeoutException(
            'timed out mining to Sapling activation; '
            'initialHeight=$initialHeight activationHeight=$activationHeight '
            'blocksToMine=$blocksToMine rpcPort=${harness.rpcPort} '
            'version=${harness.zcashdVersion}',
          ),
        );
    final finalHeight = await harness.getBlockCount();
    final finalInfo = await harness.getBlockchainInfo();
    final finalSapling = _upgradeInfo(finalInfo, 'Sapling');
    expect(
      _upgradeIsActive(finalSapling, finalHeight) ||
          finalHeight >= activationHeight,
      isTrue,
      reason:
          'Sapling must be active before shieldcoinbase; '
          'initialHeight=$initialHeight finalHeight=$finalHeight '
          'activationHeight=$activationHeight finalSapling=$finalSapling',
    );
    return _ActivationProof(
      initialHeight: initialHeight,
      finalHeight: finalHeight,
      activationHeight: activationHeight,
      status: _upgradeStatus(finalSapling),
      hashes: hashes,
    );
  } on Object catch (error) {
    final currentHeight = await _safeHeight(harness);
    fail(
      'Sapling activation mining failed before shieldcoinbase; '
      'initialHeight=$initialHeight currentHeight=$currentHeight '
      'activationHeight=$activationHeight blocksToMine=$blocksToMine '
      'rpcPort=${harness.rpcPort} version=${harness.zcashdVersion} '
      'error=$error\n'
      '${harness.diagnosticSummary(phase: 'sapling-activation')}',
    );
  }
}

Map<String, dynamic>? _upgradeInfo(
  Map<String, dynamic> blockchainInfo,
  String upgradeName,
) {
  final upgrades = blockchainInfo['upgrades'];
  if (upgrades is! Map) return null;
  for (final value in upgrades.values) {
    if (value is! Map) continue;
    final upgrade = Map<String, dynamic>.from(value);
    if (upgrade['name'] == upgradeName) return upgrade;
  }
  return null;
}

bool _upgradeIsActive(Map<String, dynamic>? upgrade, int currentHeight) {
  if (upgrade == null) return false;
  if (upgrade['status'] == 'active') return true;
  final activationHeight = _upgradeActivationHeight(upgrade);
  return activationHeight != null && currentHeight >= activationHeight;
}

int? _upgradeActivationHeight(Map<String, dynamic>? upgrade) {
  if (upgrade == null) return null;
  final value = upgrade['activationheight'];
  if (value is num) return value.toInt();
  return null;
}

String _upgradeStatus(Map<String, dynamic>? upgrade) {
  final status = upgrade?['status'];
  return status is String ? status : 'unknown';
}

Future<Object> _safeHeight(ZcashdHarness harness) async {
  try {
    return await harness.getBlockCount();
  } on Object catch (error) {
    return 'unavailable: $error';
  }
}

Future<Object> _tryReadSpendableBalance(
  ZcashdHarness harness, {
  required String phase,
  required int initialHeight,
  required int requestedBlocks,
}) async {
  try {
    return await _readSpendableBalance(
      harness,
      phase: phase,
      initialHeight: initialHeight,
      requestedBlocks: requestedBlocks,
      timeout: const Duration(seconds: 5),
    );
  } on Object catch (error) {
    return 'unavailable: $error';
  }
}

Future<int> _readSpendableBalance(
  ZcashdHarness harness, {
  required String phase,
  required int initialHeight,
  required int requestedBlocks,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      return await harness.client.getBalance();
    } on Object catch (getBalanceError) {
      lastError = getBalanceError;
      try {
        return (await harness.client.zGetTotalBalance()).totalZatoshis;
      } on Object catch (totalBalanceError) {
        lastError = '$getBalanceError; fallback=$totalBalanceError';
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  throw TimeoutException(
    'timed out reading spendable balance during $phase; '
    'requestedBlocks=$requestedBlocks initialHeight=$initialHeight '
    'rpcPort=${harness.rpcPort} version=${harness.zcashdVersion} '
    'lastError=$lastError',
  );
}

Future<String> _newShieldedAddress(ZcashdHarness harness) async {
  final account = await harness.client.zGetNewAccount();
  const receiverAttempts = <List<String>>[
    ['orchard', 'sapling'],
    ['sapling'],
  ];
  Object? lastError;
  for (final receivers in receiverAttempts) {
    try {
      final address = await harness.client.zGetAddressForAccount(
        account,
        receiverTypes: receivers,
      );
      expect(
        address,
        isNot(startsWith('t')),
        reason:
            'shieldcoinbase destination must include a shielded receiver; '
            'account=$account receiverTypes=$receivers '
            'addressPrefix=${_addressPrefix(address)}',
      );
      return address;
    } on Object catch (error) {
      lastError = error;
    }
  }
  fail(
    'failed to derive shielded-capable receiving address; '
    'account=$account attempts=$receiverAttempts rpcPort=${harness.rpcPort} '
    'version=${harness.zcashdVersion} lastError=$lastError\n'
    '${harness.diagnosticSummary(phase: 'derive-shielded-address')}',
  );
}

Future<List<String>> _rawMempoolTxids(ZcashdHarness harness) async {
  final result = await harness.client.getRawMempool();
  if (result is List) return result.map((value) => value as String).toList();
  throw StateError('getrawmempool result was not a list: $result');
}

Future<Map<String, dynamic>> _readBlock(
  ZcashdHarness harness,
  String blockHash,
) async {
  final result = await harness.client.getBlock(blockHash);
  if (result is Map) return Map<String, dynamic>.from(result);
  throw StateError('getblock result for $blockHash was not an object: $result');
}

Future<Map<String, dynamic>> _readTransaction(
  ZcashdHarness harness,
  String txid,
) async {
  final result = await harness.client.getRawTransaction(txid, verbosity: 1);
  if (result is Map) return Map<String, dynamic>.from(result);
  throw StateError(
    'getrawtransaction verbose result for $txid was not an object: $result',
  );
}

List<String> _blockTxids(Map<String, dynamic> block) {
  final tx = block['tx'];
  if (tx is List) return tx.map((value) => value as String).toList();
  throw StateError('getblock result missing tx list: $block');
}

int _numericField(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is num) return value.toInt();
  throw StateError('Expected numeric $field in $json');
}

String _addressPrefix(String address) {
  if (address.length <= 12) return address;
  return address.substring(0, 12);
}

String _tryOperationId(ShieldCoinbaseResult? result) {
  try {
    return result?.operationId ?? 'unavailable';
  } on Object {
    return 'unavailable';
  }
}

String _tryStatus(ZcashOperationStatus? status) {
  try {
    return status?.status ?? 'unavailable';
  } on Object {
    return 'unavailable';
  }
}

String _tryTxid(ZcashOperationStatus? status) {
  try {
    return status?.txid ?? 'unavailable';
  } on Object {
    return 'unavailable';
  }
}

Future<Object> _safeBalance(ZcashdHarness harness) async {
  try {
    return await harness.client.getBalance();
  } on Object catch (getBalanceError) {
    try {
      return (await harness.client.zGetTotalBalance()).totalZatoshis;
    } on Object catch (totalBalanceError) {
      return 'unavailable: $getBalanceError; fallback=$totalBalanceError';
    }
  }
}
