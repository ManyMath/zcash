@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

import 'lightwalletd_harness.dart';
import 'zcashd_harness.dart';

const _kSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const _kNetwork = 'regtest';
const _kShieldFeeZatoshis = 100000;
const _kSaplingActivationHeight = 1;

void main() {
  final live =
      Platform.environment.containsKey('ZCASHD_INTEGRATION') &&
      Platform.environment.containsKey('LIGHTWALLETD_INTEGRATION');
  ZcashdHarness? zcashd;
  LightwalletdHarness? lightwalletd;

  setUpAll(() async {
    if (!live) return;
    zcashd = await ZcashdHarness.start();
  });

  tearDownAll(() async {
    final lwd = lightwalletd;
    lightwalletd = null;
    if (lwd != null) await lwd.shutdown();
    final z = zcashd;
    zcashd = null;
    if (z != null) await z.shutdown();
  });

  test('skips live zcashd/lightwalletd scan unless explicitly enabled', () {
    if (live) return;
    expect(zcashd, isNull);
    expect(lightwalletd, isNull);
  });

  test('requires a Sapling receiver before creating a shield operation', () {
    expect(
      () => _requireSaplingReceiver(
        const _DerivedAddressSet(
          ua: 'uregtest-public-prefix-only',
          sapling: null,
          orchard: 'uorchard-public-prefix-only',
          transparent: null,
        ),
        ufvk: 'uview-secret-that-must-not-leak',
      ),
      throwsA(
        isA<LightwalletdScanProofException>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains('missing Sapling receiver'),
            contains('phase=derive-sapling-address'),
            isNot(contains('uview-secret-that-must-not-leak')),
          ),
        ),
      ),
    );
  });

  test('rejects empty or inverted compact-block scan ranges', () {
    expect(
      () => _heightRange(9, 8),
      throwsA(
        isA<LightwalletdScanProofException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('empty compact block range'), contains('9..8')),
        ),
      ),
    );
  });

  test(
    'zero-note scanner results include counts and heights without secrets',
    () {
      expect(
        () => _requireDiscoveredNote(
          const ZcashScanResult(
            scannedBlocks: 2,
            discoveredNotes: 0,
            totalValue: 0,
            notes: [],
          ),
          scannedHeights: const [120, 121],
          rangeStart: 120,
          rangeEnd: 121,
          ufvk: 'uview-secret-that-must-not-leak',
          saplingAddress: 'ztestsapling1fulladdressmustnotleak',
        ),
        throwsA(
          isA<LightwalletdScanProofException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('zero-note scanner result'),
              contains('scannedBlocks=2'),
              contains('discoveredNotes=0'),
              contains('streamedCompactBlockHeights=[120, 121]'),
              isNot(contains('uview-secret-that-must-not-leak')),
              isNot(contains('ztestsapling1fulladdressmustnotleak')),
            ),
          ),
        ),
      );
    },
  );

  test('malformed scanner payload errors do not dump payload contents', () {
    expect(
      () => ZcashScanResult.fromRawJson('not-json-with-secret'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('malformed JSON'),
            isNot(contains('not-json-with-secret')),
          ),
        ),
      ),
    );
  });

  test('lightwalletd launch prerequisites require safe selectors', () {
    final message = lightwalletdLaunchPrerequisiteMessage();

    expect(
      message,
      allOf(
        contains('LIGHTWALLETD_BIN'),
        contains('LIGHTWALLETD_DOCKER_IMAGE'),
        contains('digest-pinned Docker image'),
        isNot(
          contains(
            'pullable Docker '
            'image',
          ),
        ),
        isNot(contains('LIGHTWALLETD_ADDR')),
      ),
    );
  });

  test('proof diagnostics redact UFVKs, RPC passwords, and full addresses', () {
    const ufvk = 'uview-secret-that-must-not-leak';
    const rpcPassword = 'rpc-password-that-must-not-leak';
    const address = 'ztestsapling1fulladdressmustnotleak';
    final diagnostic = LightwalletdScanProofException(
      'synthetic failure mentions $ufvk $rpcPassword $address',
      phase: 'redaction-check',
      zcashdRpcPort: 18232,
      lightwalletdGrpcPort: 19067,
      operationId: 'opid-redaction',
      operationStatus: 'failed',
      operationTxid: 'unavailable',
      latestBackendHeight: 42,
      latestLightwalletdHeight: 41,
      streamedCompactBlockHeights: const [40, 41],
      scannerSummary: 'notes=0 value=0',
      redactSensitive: const [ufvk, rpcPassword, address],
    ).toString();

    expect(diagnostic, contains('phase=redaction-check'));
    expect(diagnostic, contains('opid-redaction'));
    expect(diagnostic, isNot(contains(ufvk)));
    expect(diagnostic, isNot(contains(rpcPassword)));
    expect(diagnostic, isNot(contains(address)));
    expect(diagnostic, contains('<redacted>'));
  });

  test(
    'discovers a z_shieldcoinbase Sapling note through lightwalletd compact blocks',
    () async {
      if (!live) return;
      final z = zcashd!;

      String? ufvk;
      String? saplingAddress;
      ShieldCoinbaseResult? shield;
      ZcashOperationStatus? operationStatus;
      int? preShieldHeight;
      int? confirmedHeight;
      LightwalletdSyncSnapshot? sync;
      List<int> compactHeights = const [];
      ZcashScanResult? scanResult;

      try {
        ufvk = _deriveUfvk(_kSeedHex, _kNetwork);
        final addressSet = _deriveAddressSet(ufvk, _kNetwork);
        saplingAddress = _requireSaplingReceiver(addressSet, ufvk: ufvk);

        final maturity = await _ensureMatureCoinbaseFunds(z);
        final sapling = await _ensureSaplingActive(z);
        preShieldHeight = await z.getBlockCount();

        shield = await z.client.zShieldCoinbase(
          '*',
          saplingAddress,
          feeZatoshis: _kShieldFeeZatoshis,
          limit: 1,
        );
        operationStatus = await z.client.waitForOperation(
          shield.operationId,
          timeout: const Duration(minutes: 2),
        );
        final txid = operationStatus.txid;
        expect(
          txid,
          matches(RegExp(r'^[0-9a-fA-F]{64}$')),
          reason:
              'shield operation must expose a txid before scan; '
              'opid=${shield.operationId} status=${operationStatus.status} '
              'zcashdRpcPort=${z.rpcPort} version=${z.zcashdVersion}',
        );

        await z.mineBlocks(1);
        confirmedHeight = await z.getBlockCount();
        expect(
          confirmedHeight,
          equals(preShieldHeight + 1),
          reason:
              'shield confirmation mining should advance exactly one block; '
              'preShieldHeight=$preShieldHeight confirmedHeight=$confirmedHeight '
              'opid=${shield.operationId} txid=$txid',
        );

        lightwalletd = await LightwalletdHarness.start(
          backend: LightwalletdBackend.zcashd(
            rpcPort: z.rpcPort,
            rpcUser: z.rpcUser,
            rpcPassword: z.rpcPassword,
          ),
        );
        final lwd = lightwalletd!;
        sync = await lwd.waitForSyncHeight(
          confirmedHeight,
          readBackendHeight: z.getBlockCount,
          timeout: const Duration(minutes: 2),
        );

        final range = _heightRange(confirmedHeight, confirmedHeight);
        final compactBlocks = await lwd.fetchCompactBlockRange(range).toList();
        compactHeights = compactBlocks
            .map((block) => block.height.toInt())
            .toList(growable: false);
        expect(
          compactHeights,
          contains(confirmedHeight),
          reason:
              'lightwalletd compact stream must include the mined shield tx height; '
              'confirmedHeight=$confirmedHeight compactHeights=$compactHeights '
              'backendHeight=${sync.backendHeight} '
              'lightwalletdHeight=${sync.lightwalletdHeight}',
        );

        scanResult = scanCompactBlocks(
          ufvk: ufvk,
          network: _kNetwork,
          blocks: compactBlocks.map(
            (block) => CompactBlockScanInput.fromBytes(
              block.writeToBuffer(),
              height: block.height.toInt(),
            ),
          ),
        );
        final note = _requireDiscoveredNote(
          scanResult,
          scannedHeights: compactHeights,
          rangeStart: confirmedHeight,
          rangeEnd: confirmedHeight,
          ufvk: ufvk,
          saplingAddress: saplingAddress,
        );

        expect(note.height, equals(confirmedHeight));
        expect(note.value, greaterThan(0));
        expect(note.pool, equals('sapling'));
        expect(
          scanResult.totalValue,
          greaterThan(0),
          reason:
              'scanner should report a positive note value; '
              'scan=${_scanSummary(scanResult)} compactHeights=$compactHeights',
        );

        expect(maturity.finalSpendable, greaterThan(0));
        expect(
          sapling.finalHeight,
          greaterThanOrEqualTo(sapling.initialHeight),
        );
      } on Object catch (error) {
        final lwd = lightwalletd;
        final safeError = _redact(error.toString(), [
          ?ufvk,
          ?saplingAddress,
          z.rpcPassword,
        ]);
        fail(
          'live lightwalletd note-discovery proof failed; '
          'zcashdRpcPort=${z.rpcPort} zcashdVersion=${z.zcashdVersion} '
          'lightwalletdLaunch=${lwd?.launch ?? 'not-started'} '
          'lightwalletdGrpcPort=${lwd?.grpcPort ?? -1} '
          'preShieldHeight=$preShieldHeight confirmedHeight=$confirmedHeight '
          'opid=${shield?.operationId ?? 'unavailable'} '
          'status=${operationStatus?.status ?? 'unavailable'} '
          'txid=${operationStatus?.txid ?? 'unavailable'} '
          'backendHeight=${sync?.backendHeight ?? 'unavailable'} '
          'lightwalletdHeight=${sync?.lightwalletdHeight ?? 'unavailable'} '
          'streamedCompactBlockHeights=$compactHeights '
          'scannerSummary=${_scanSummary(scanResult)} '
          'saplingAddressPrefix=${_prefix(saplingAddress)} '
          'error=$safeError\n'
          '${z.diagnosticSummary(phase: 'lightwalletd-scan-zcashd')}\n'
          '${lwd?.diagnosticSummary(phase: 'lightwalletd-scan') ?? ''}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

class LightwalletdScanProofException implements Exception {
  final String message;
  final String phase;
  final int? zcashdRpcPort;
  final int? lightwalletdGrpcPort;
  final String? operationId;
  final String? operationStatus;
  final String? operationTxid;
  final int? latestBackendHeight;
  final int? latestLightwalletdHeight;
  final List<int> streamedCompactBlockHeights;
  final String? scannerSummary;
  final Iterable<String> redactSensitive;

  const LightwalletdScanProofException(
    this.message, {
    required this.phase,
    this.zcashdRpcPort,
    this.lightwalletdGrpcPort,
    this.operationId,
    this.operationStatus,
    this.operationTxid,
    this.latestBackendHeight,
    this.latestLightwalletdHeight,
    this.streamedCompactBlockHeights = const [],
    this.scannerSummary,
    this.redactSensitive = const [],
  });

  @override
  String toString() {
    final parts = <String>[
      'LightwalletdScanProofException: $message',
      'phase=$phase',
      if (zcashdRpcPort != null) 'zcashdRpcPort=$zcashdRpcPort',
      if (lightwalletdGrpcPort != null)
        'lightwalletdGrpcPort=$lightwalletdGrpcPort',
      if (operationId != null) 'opid=$operationId',
      if (operationStatus != null) 'status=$operationStatus',
      if (operationTxid != null) 'txid=$operationTxid',
      if (latestBackendHeight != null) 'backendHeight=$latestBackendHeight',
      if (latestLightwalletdHeight != null)
        'lightwalletdHeight=$latestLightwalletdHeight',
      if (streamedCompactBlockHeights.isNotEmpty)
        'streamedCompactBlockHeights=$streamedCompactBlockHeights',
      if (scannerSummary != null) 'scannerSummary=$scannerSummary',
    ];
    return _redactProofDiagnostics(parts.join('\n'), redactSensitive);
  }
}

class _DerivedAddressSet {
  final String ua;
  final String? sapling;
  final String? orchard;
  final String? transparent;

  const _DerivedAddressSet({
    required this.ua,
    required this.sapling,
    required this.orchard,
    required this.transparent,
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

String _deriveUfvk(String seedHex, String network) {
  final raw = ZcashFfiBindings.instance.seedToAccountUfvk(seedHex, network, 0);
  return _requiredFfiString(raw, 'ufvk', context: 'seed_to_account_ufvk');
}

_DerivedAddressSet _deriveAddressSet(String ufvk, String network) {
  final raw = ZcashFfiBindings.instance.ufvkToAddress(ufvk, network, 0);
  final json = _ffiObject(raw, context: 'ufvk_to_address', redact: [ufvk]);
  return _DerivedAddressSet(
    ua: _requiredString(json, 'ua', context: 'ufvk_to_address'),
    sapling: _optionalString(json, 'sapling', context: 'ufvk_to_address'),
    orchard: _optionalString(json, 'orchard', context: 'ufvk_to_address'),
    transparent: _optionalString(
      json,
      'transparent',
      context: 'ufvk_to_address',
    ),
  );
}

String _requireSaplingReceiver(_DerivedAddressSet set, {required String ufvk}) {
  final sapling = set.sapling;
  if (sapling != null && sapling.isNotEmpty) return sapling;
  throw LightwalletdScanProofException(
    'derived UFVK address set is missing Sapling receiver; '
    'uaPrefix=${_prefix(set.ua)} orchardPresent=${set.orchard != null} '
    'transparentPresent=${set.transparent != null}',
    phase: 'derive-sapling-address',
    redactSensitive: [ufvk, set.ua, ?sapling],
  );
}

BlockRange _heightRange(int startHeight, int endHeight) {
  if (startHeight > endHeight) {
    throw LightwalletdScanProofException(
      'empty compact block range $startHeight..$endHeight',
      phase: 'build-compact-block-range',
      streamedCompactBlockHeights: [startHeight, endHeight],
    );
  }
  return BlockRange()
    ..start = (BlockID()..height = Int64(startHeight))
    ..end = (BlockID()..height = Int64(endHeight));
}

ZcashScannedNote _requireDiscoveredNote(
  ZcashScanResult result, {
  required List<int> scannedHeights,
  required int rangeStart,
  required int rangeEnd,
  required String ufvk,
  required String saplingAddress,
}) {
  final matchingNotes = result.notes
      .where(
        (note) =>
            note.value > 0 &&
            note.height >= rangeStart &&
            note.height <= rangeEnd,
      )
      .toList(growable: false);
  if (result.discoveredNotes > 0 &&
      result.totalValue > 0 &&
      matchingNotes.isNotEmpty) {
    return matchingNotes.first;
  }
  throw LightwalletdScanProofException(
    'zero-note scanner result or no note in confirmed range; '
    'range=$rangeStart..$rangeEnd scannedBlocks=${result.scannedBlocks} '
    'discoveredNotes=${result.discoveredNotes} totalValue=${result.totalValue}',
    phase: 'scan-compact-blocks',
    streamedCompactBlockHeights: scannedHeights,
    scannerSummary: _scanSummary(result),
    redactSensitive: [ufvk, saplingAddress],
  );
}

Future<_MaturityProof> _ensureMatureCoinbaseFunds(ZcashdHarness harness) async {
  const maturityBlocks = 101;
  final initialHeight = await harness.getBlockCount();
  final initialSpendable = await _tryReadSpendableBalance(harness);
  final shouldMine = initialSpendable is! int || initialSpendable <= 0;
  final requestedBlocks = shouldMine ? maturityBlocks : 0;
  try {
    final hashes = shouldMine
        ? await harness
              .mineBlocks(maturityBlocks)
              .timeout(const Duration(minutes: 2))
        : <String>[];
    final finalHeight = await harness.getBlockCount();
    final finalSpendable = await _readSpendableBalance(harness);
    if (finalSpendable <= 0) {
      throw LightwalletdScanProofException(
        'mature coinbase balance stayed zero after mining',
        phase: 'maturity-mining',
        zcashdRpcPort: harness.rpcPort,
        latestBackendHeight: finalHeight,
      );
    }
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
    throw LightwalletdScanProofException(
      'mature coinbase balance proof failed; requestedBlocks=$maturityBlocks '
      'initialHeight=$initialHeight currentHeight=$currentHeight '
      'initialSpendable=$initialSpendable currentSpendable=$currentBalance '
      'error=$error\n${harness.diagnosticSummary(phase: 'maturity-mining')}',
      phase: 'maturity-mining',
      zcashdRpcPort: harness.rpcPort,
    );
  }
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
      _upgradeActivationHeight(initialSapling) ?? _kSaplingActivationHeight;
  final blocksToMine = activationHeight > initialHeight
      ? activationHeight - initialHeight
      : 0;
  try {
    final hashes = blocksToMine > 0
        ? await harness
              .mineBlocks(blocksToMine)
              .timeout(const Duration(minutes: 3))
        : <String>[];
    final finalHeight = await harness.getBlockCount();
    final finalInfo = await harness.getBlockchainInfo();
    final finalSapling = _upgradeInfo(finalInfo, 'Sapling');
    if (!_upgradeIsActive(finalSapling, finalHeight) &&
        finalHeight < activationHeight) {
      throw LightwalletdScanProofException(
        'Sapling did not become active before shield operation',
        phase: 'sapling-activation',
        zcashdRpcPort: harness.rpcPort,
        latestBackendHeight: finalHeight,
      );
    }
    return _ActivationProof(
      initialHeight: initialHeight,
      finalHeight: finalHeight,
      activationHeight: activationHeight,
      status: _upgradeStatus(finalSapling),
      hashes: hashes,
    );
  } on Object catch (error) {
    final currentHeight = await _safeHeight(harness);
    throw LightwalletdScanProofException(
      'Sapling activation mining failed before shield operation; '
      'initialHeight=$initialHeight currentHeight=$currentHeight '
      'activationHeight=$activationHeight blocksToMine=$blocksToMine '
      'error=$error\n${harness.diagnosticSummary(phase: 'sapling-activation')}',
      phase: 'sapling-activation',
      zcashdRpcPort: harness.rpcPort,
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

Future<Object> _tryReadSpendableBalance(ZcashdHarness harness) async {
  try {
    return await _readSpendableBalance(
      harness,
      timeout: const Duration(seconds: 5),
    );
  } on Object catch (error) {
    return 'unavailable: $error';
  }
}

Future<int> _readSpendableBalance(
  ZcashdHarness harness, {
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
    'timed out reading spendable balance; lastError=$lastError',
  );
}

Future<Object> _safeHeight(ZcashdHarness harness) async {
  try {
    return await harness.getBlockCount();
  } on Object catch (error) {
    return 'unavailable: $error';
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

String _requiredFfiString(String raw, String key, {required String context}) =>
    _requiredString(_ffiObject(raw, context: context), key, context: context);

Map<String, Object?> _ffiObject(
  String raw, {
  required String context,
  Iterable<String> redact = const [],
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (error) {
    throw StateError('$context returned malformed JSON: ${error.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw StateError('$context returned non-object JSON');
  }
  final ffiError = decoded['error'];
  if (ffiError != null) {
    throw StateError(
      '$context failed: ${_redact(ffiError.toString(), redact)}',
    );
  }
  return decoded;
}

String _requiredString(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw StateError('$context missing non-empty "$key" string');
}

String? _optionalString(
  Map<String, Object?> json,
  String key, {
  required String context,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw StateError('$context has invalid "$key" string');
}

String _scanSummary(ZcashScanResult? result) {
  if (result == null) return 'unavailable';
  final noteSummary = result.notes
      .map((note) => '${note.pool}:${note.height}:${note.value}')
      .join(',');
  return 'scannedBlocks=${result.scannedBlocks} '
      'discoveredNotes=${result.discoveredNotes} '
      'totalValue=${result.totalValue} notes=[$noteSummary]';
}

String _prefix(String? value) {
  if (value == null || value.isEmpty) return 'unavailable';
  return value.length <= 12 ? value : value.substring(0, 12);
}

String _redactProofDiagnostics(String input, Iterable<String> sensitiveValues) {
  return _redact(input, sensitiveValues)
      .replaceAll(RegExp(r'rpcpassword=[^\s]+'), 'rpcpassword=<redacted>')
      .replaceAll(RegExp(r'rpcuser=[^\s]+'), 'rpcuser=<redacted>')
      .replaceAll(
        RegExp(r'Authorization:\s*Basic\s+[^\s]+', caseSensitive: false),
        'Authorization: Basic <redacted>',
      );
}

String _redact(String input, Iterable<String> sensitiveValues) {
  var redacted = input;
  for (final value in sensitiveValues) {
    if (value.isNotEmpty) redacted = redacted.replaceAll(value, '<redacted>');
  }
  return redacted;
}
