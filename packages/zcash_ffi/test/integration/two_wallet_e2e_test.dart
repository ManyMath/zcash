@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

import 'lightwalletd_harness.dart';
import 'zcashd_harness.dart';

const _walletASeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const _walletBSeedHex =
    '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f'
    '606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f';
const _network = 'regtest';
const _shieldFeeZatoshis = 100000;
const _aToBAmountZatoshis = 1000000;
const _saplingActivationHeight = 1;

void main() {
  final live =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
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

  test('skips guarded two-wallet E2E unless explicit local gates are set', () {
    if (live) return;
    expect(zcashd, isNull);
    expect(lightwalletd, isNull);
  });

  test(
    'requires B to expose a Sapling receiver instead of Orchard-only UA',
    () {
      expect(
        () => _requireSaplingReceiver(
          const _DerivedAddressSet(
            ua: 'uregtest-public-prefix-only',
            sapling: null,
            orchard: 'uorchard-public-prefix-only',
            transparent: null,
          ),
          label: 'wallet-b',
          ufvk: 'uview-secret-that-must-not-leak',
        ),
        throwsA(
          isA<TwoWalletE2eException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('missing Sapling receiver'),
              contains('phase=derive-wallet-b'),
              contains('wallet=wallet-b'),
              isNot(contains('uview-secret-that-must-not-leak')),
            ),
          ),
        ),
      );
    },
  );

  test('rejects empty or inverted compact-block scan ranges', () {
    expect(
      () => _heightRange(9, 8),
      throwsA(
        isA<TwoWalletE2eException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('empty compact block range'), contains('9..8')),
        ),
      ),
    );
  });

  test('zero-note scan diagnostics expose counts and redact secrets', () {
    expect(
      () => _requireDiscoveredNote(
        const ZcashScanResult(
          scannedBlocks: 2,
          discoveredNotes: 0,
          totalValue: 0,
          notes: [],
        ),
        walletLabel: 'wallet-b',
        scannedHeights: const [120, 121],
        rangeStart: 120,
        rangeEnd: 121,
        minValueZatoshis: _aToBAmountZatoshis,
        ufvk: 'uview-secret-that-must-not-leak',
        saplingAddress: 'ztestsapling1fulladdressmustnotleak',
      ),
      throwsA(
        isA<TwoWalletE2eException>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains('zero-note scanner result'),
            contains('wallet=wallet-b'),
            contains('scannedBlocks=2'),
            contains('discoveredNotes=0'),
            contains('streamedCompactBlockHeights=[120, 121]'),
            isNot(contains('uview-secret-that-must-not-leak')),
            isNot(contains('ztestsapling1fulladdressmustnotleak')),
          ),
        ),
      ),
    );
  });

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

  test(
    'proof diagnostics redact seeds, UFVKs, zkeys, RPC passwords, and addresses',
    () {
      const seed = _walletASeedHex;
      const ufvk = 'uview-secret-that-must-not-leak';
      const zkey = 'secret-extended-key-regtest1secretthatmustnotleak';
      const rpcPassword = 'rpc-password-that-must-not-leak';
      const address = 'zregtestsapling1fulladdressmustnotleak';
      final diagnostic = TwoWalletE2eException(
        'synthetic failure mentions $seed $ufvk $zkey $rpcPassword $address',
        phase: 'redaction-check',
        walletLabel: 'wallet-a',
        zcashdRpcPort: 18232,
        lightwalletdGrpcPort: 19067,
        operationId: 'opid-redaction',
        operationStatus: 'failed',
        operationTxid: 'txid-redaction',
        backendHeight: 42,
        lightwalletdHeight: 41,
        compactBlockRange: '40..41',
        streamedCompactBlockHeights: const [40, 41],
        scannerSummary: 'notes=0 value=0',
        redactSensitive: const [seed, ufvk, zkey, rpcPassword, address],
      ).toString();

      expect(diagnostic, contains('phase=redaction-check'));
      expect(diagnostic, contains('opid-redaction'));
      expect(diagnostic, isNot(contains(seed)));
      expect(diagnostic, isNot(contains(ufvk)));
      expect(diagnostic, isNot(contains(zkey)));
      expect(diagnostic, isNot(contains(rpcPassword)));
      expect(diagnostic, isNot(contains(address)));
      expect(diagnostic, contains('<redacted>'));
    },
  );

  test(
    'mines, shields to A, scans A, sends A to B, and scans B via localhost',
    () async {
      if (!live) return;
      final z = zcashd!;

      var phase = 'derive-wallets';
      _WalletMaterial? walletA;
      _WalletMaterial? walletB;
      ZImportKeyResult? importResult;
      ShieldCoinbaseResult? shieldResult;
      ZcashOperationStatus? shieldStatus;
      ZcashOperationStatus? sendStatus;
      String? sendOperationId;
      _MaturityProof? maturity;
      _ActivationProof? saplingActivation;
      _PrivateBalanceProof? privateBalance;
      int? preShieldHeight;
      int? shieldConfirmedHeight;
      int? sendConfirmedHeight;
      LightwalletdSyncSnapshot? scanASync;
      LightwalletdSyncSnapshot? scanBSync;
      List<int> scanACompactHeights = const [];
      List<int> scanBCompactHeights = const [];
      ZcashScanResult? scanAResult;
      ZcashScanResult? scanBResult;

      try {
        walletA = _deriveWallet(
          label: 'wallet-a',
          seedHex: _walletASeedHex,
          includeSaplingSpendingKey: true,
        );
        walletB = _deriveWallet(
          label: 'wallet-b',
          seedHex: _walletBSeedHex,
          includeSaplingSpendingKey: false,
        );
        _phaseLog(phase, {
          'walletAAddressPrefix': _prefix(walletA.saplingAddress),
          'walletBAddressPrefix': _prefix(walletB.saplingAddress),
          'walletAZkeyPrefix': _safePrefix(walletA.saplingSpendingKey),
        });

        phase = 'import-wallet-a';
        importResult = await z.client.zImportKey(
          walletA.saplingSpendingKey!,
          rescan: 'no',
        );
        _assertSaplingImportResult(
          importResult,
          walletA: walletA,
          rpcPort: z.rpcPort,
        );
        _phaseLog(phase, {
          'rpcPort': z.rpcPort,
          'result': importResult.safeSummary,
        });

        phase = 'maturity-mining';
        maturity = await _ensureMatureCoinbaseFunds(z);
        _phaseLog(phase, {
          'requestedBlocks': maturity.requestedBlocks,
          'initialHeight': maturity.initialHeight,
          'finalHeight': maturity.finalHeight,
          'finalSpendable': maturity.finalSpendable,
        });

        phase = 'sapling-activation';
        saplingActivation = await _ensureSaplingActive(z);
        _phaseLog(phase, {
          'initialHeight': saplingActivation.initialHeight,
          'finalHeight': saplingActivation.finalHeight,
          'activationHeight': saplingActivation.activationHeight,
          'status': saplingActivation.status,
        });

        phase = 'shield-to-A';
        preShieldHeight = await z.getBlockCount();
        shieldResult = await z.client.zShieldCoinbase(
          '*',
          walletA.saplingAddress,
          feeZatoshis: _shieldFeeZatoshis,
          limit: 1,
        );
        shieldStatus = await z.client.waitForOperation(
          shieldResult.operationId,
          timeout: const Duration(minutes: 2),
        );
        _requireTxid(
          shieldStatus,
          phase: phase,
          operationId: shieldResult.operationId,
        );
        await z.mineBlocks(1);
        shieldConfirmedHeight = await z.getBlockCount();
        _phaseLog(phase, {
          'opid': shieldResult.operationId,
          'status': shieldStatus.status,
          'txid': shieldStatus.txid,
          'preHeight': preShieldHeight,
          'confirmedHeight': shieldConfirmedHeight,
        });

        phase = 'start-lightwalletd';
        lightwalletd = await LightwalletdHarness.start(
          backend: LightwalletdBackend.zcashd(
            rpcPort: z.rpcPort,
            rpcUser: z.rpcUser,
            rpcPassword: z.rpcPassword,
          ),
        );
        final lwd = lightwalletd!;
        _phaseLog(phase, {
          'zcashdRpcPort': z.rpcPort,
          'lightwalletdGrpcPort': lwd.grpcPort,
          'lightwalletdHttpPort': lwd.httpPort,
        });

        phase = 'scan-A';
        scanASync = await lwd.waitForSyncHeight(
          shieldConfirmedHeight,
          readBackendHeight: z.getBlockCount,
          timeout: const Duration(minutes: 2),
        );
        final scanARange = _heightRange(
          shieldConfirmedHeight,
          shieldConfirmedHeight,
        );
        final scanACompactBlocks = await lwd
            .fetchCompactBlockRange(scanARange)
            .toList();
        scanACompactHeights = _compactHeights(scanACompactBlocks);
        scanAResult = _scanWalletCompactBlocks(walletA, scanACompactBlocks);
        final walletANote = _requireDiscoveredNote(
          scanAResult,
          walletLabel: walletA.label,
          scannedHeights: scanACompactHeights,
          rangeStart: shieldConfirmedHeight,
          rangeEnd: shieldConfirmedHeight,
          minValueZatoshis: 1,
          ufvk: walletA.ufvk,
          saplingAddress: walletA.saplingAddress,
        );
        expect(walletANote.pool, equals('sapling'));
        expect(walletANote.height, equals(shieldConfirmedHeight));
        _phaseLog(phase, {
          'backendHeight': scanASync.backendHeight,
          'lightwalletdHeight': scanASync.lightwalletdHeight,
          'compactHeights': scanACompactHeights,
          'scannerSummary': _scanSummary(scanAResult),
        });

        phase = 'wait-wallet-a-spendability';
        privateBalance = await _waitForPrivateBalance(
          z,
          minZatoshis:
              _aToBAmountZatoshis + ZcashdWalletClient.defaultFeeZatoshis,
          timeout: const Duration(minutes: 2),
        );
        _phaseLog(phase, {
          'attempts': privateBalance.attempts,
          'privateBalance': privateBalance.privateZatoshis,
          'totalBalance': privateBalance.totalZatoshis,
        });

        phase = 'send-A-to-B';
        sendOperationId = await z.client.zSendMany(
          walletA.saplingAddress,
          [
            ZSendRecipient(
              address: walletB.saplingAddress,
              amountZatoshis: _aToBAmountZatoshis,
            ),
          ],
          minConf: 1,
          privacyPolicy: PrivacyPolicy.fullPrivacy,
        );
        sendStatus = await z.client.waitForOperation(
          sendOperationId,
          timeout: const Duration(minutes: 2),
        );
        _requireTxid(sendStatus, phase: phase, operationId: sendOperationId);
        await z.mineBlocks(1);
        sendConfirmedHeight = await z.getBlockCount();
        _phaseLog(phase, {
          'opid': sendOperationId,
          'status': sendStatus.status,
          'txid': sendStatus.txid,
          'confirmedHeight': sendConfirmedHeight,
          'fromAddressPrefix': _prefix(walletA.saplingAddress),
          'toAddressPrefix': _prefix(walletB.saplingAddress),
          'minConf': 1,
          'privacyPolicy': PrivacyPolicy.fullPrivacy.rpcValue,
        });

        phase = 'scan-B';
        scanBSync = await lwd.waitForSyncHeight(
          sendConfirmedHeight,
          readBackendHeight: z.getBlockCount,
          timeout: const Duration(minutes: 2),
        );
        final scanBRange = _heightRange(
          sendConfirmedHeight,
          sendConfirmedHeight,
        );
        final scanBCompactBlocks = await lwd
            .fetchCompactBlockRange(scanBRange)
            .toList();
        scanBCompactHeights = _compactHeights(scanBCompactBlocks);
        scanBResult = _scanWalletCompactBlocks(walletB, scanBCompactBlocks);
        final walletBNote = _requireDiscoveredNote(
          scanBResult,
          walletLabel: walletB.label,
          scannedHeights: scanBCompactHeights,
          rangeStart: sendConfirmedHeight,
          rangeEnd: sendConfirmedHeight,
          minValueZatoshis: _aToBAmountZatoshis,
          ufvk: walletB.ufvk,
          saplingAddress: walletB.saplingAddress,
        );
        expect(walletBNote.pool, equals('sapling'));
        expect(walletBNote.height, equals(sendConfirmedHeight));
        expect(walletBNote.value, equals(_aToBAmountZatoshis));
        expect(
          scanBResult.totalValue,
          greaterThanOrEqualTo(_aToBAmountZatoshis),
        );
        _phaseLog(phase, {
          'backendHeight': scanBSync.backendHeight,
          'lightwalletdHeight': scanBSync.lightwalletdHeight,
          'compactHeights': scanBCompactHeights,
          'scannerSummary': _scanSummary(scanBResult),
        });
      } on Object catch (error) {
        final lwd = lightwalletd;
        final safeError = _redact(error.toString(), [
          _walletASeedHex,
          _walletBSeedHex,
          ?walletA?.ufvk,
          ?walletB?.ufvk,
          ?walletA?.saplingSpendingKey,
          ?walletA?.saplingAddress,
          ?walletB?.saplingAddress,
          z.rpcPassword,
        ]);
        fail(
          TwoWalletE2eException(
            'guarded two-wallet E2E failed: $safeError',
            phase: phase,
            walletLabel: walletB?.label ?? walletA?.label,
            zcashdRpcPort: z.rpcPort,
            zcashdVersion: z.zcashdVersion,
            lightwalletdGrpcPort: lwd?.grpcPort,
            lightwalletdHttpPort: lwd?.httpPort,
            operationId:
                sendOperationId ?? shieldResult?.operationId ?? 'unavailable',
            operationStatus:
                sendStatus?.status ?? shieldStatus?.status ?? 'unavailable',
            operationTxid: sendStatus?.txid ?? shieldStatus?.txid,
            backendHeight: scanBSync?.backendHeight ?? scanASync?.backendHeight,
            lightwalletdHeight:
                scanBSync?.lightwalletdHeight ?? scanASync?.lightwalletdHeight,
            compactBlockRange: _latestRange(
              scanBCompactHeights.isNotEmpty
                  ? scanBCompactHeights
                  : scanACompactHeights,
            ),
            streamedCompactBlockHeights: scanBCompactHeights.isNotEmpty
                ? scanBCompactHeights
                : scanACompactHeights,
            scannerSummary:
                'walletA=${_scanSummary(scanAResult)}; '
                'walletB=${_scanSummary(scanBResult)}',
            walletAAddressPrefix: _prefix(walletA?.saplingAddress),
            walletBAddressPrefix: _prefix(walletB?.saplingAddress),
            walletAZkeyPrefix: _safePrefix(walletA?.saplingSpendingKey),
            importResult: importResult?.safeSummary,
            privateBalance: privateBalance?.safeSummary,
            preShieldHeight: preShieldHeight,
            shieldConfirmedHeight: shieldConfirmedHeight,
            sendConfirmedHeight: sendConfirmedHeight,
            harnessDiagnostics:
                '${z.diagnosticSummary(phase: phase)}\n'
                '${lwd?.diagnosticSummary(phase: phase) ?? ''}',
            redactSensitive: [
              _walletASeedHex,
              _walletBSeedHex,
              ?walletA?.ufvk,
              ?walletB?.ufvk,
              ?walletA?.saplingSpendingKey,
              ?walletA?.saplingAddress,
              ?walletB?.saplingAddress,
              z.rpcPassword,
            ],
          ).toString(),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

class TwoWalletE2eException implements Exception {
  final String message;
  final String phase;
  final String? walletLabel;
  final int? zcashdRpcPort;
  final String? zcashdVersion;
  final int? lightwalletdGrpcPort;
  final int? lightwalletdHttpPort;
  final String? operationId;
  final String? operationStatus;
  final String? operationTxid;
  final int? backendHeight;
  final int? lightwalletdHeight;
  final String? compactBlockRange;
  final List<int> streamedCompactBlockHeights;
  final String? scannerSummary;
  final String? walletAAddressPrefix;
  final String? walletBAddressPrefix;
  final String? walletAZkeyPrefix;
  final String? importResult;
  final String? privateBalance;
  final int? preShieldHeight;
  final int? shieldConfirmedHeight;
  final int? sendConfirmedHeight;
  final String? harnessDiagnostics;
  final Iterable<String> redactSensitive;

  const TwoWalletE2eException(
    this.message, {
    required this.phase,
    this.walletLabel,
    this.zcashdRpcPort,
    this.zcashdVersion,
    this.lightwalletdGrpcPort,
    this.lightwalletdHttpPort,
    this.operationId,
    this.operationStatus,
    this.operationTxid,
    this.backendHeight,
    this.lightwalletdHeight,
    this.compactBlockRange,
    this.streamedCompactBlockHeights = const [],
    this.scannerSummary,
    this.walletAAddressPrefix,
    this.walletBAddressPrefix,
    this.walletAZkeyPrefix,
    this.importResult,
    this.privateBalance,
    this.preShieldHeight,
    this.shieldConfirmedHeight,
    this.sendConfirmedHeight,
    this.harnessDiagnostics,
    this.redactSensitive = const [],
  });

  @override
  String toString() {
    final parts = <String>[
      'TwoWalletE2eException: $message',
      'phase=$phase',
      if (walletLabel != null) 'wallet=$walletLabel',
      if (zcashdRpcPort != null) 'zcashdRpcPort=$zcashdRpcPort',
      if (zcashdVersion != null) 'zcashdVersion=$zcashdVersion',
      if (lightwalletdGrpcPort != null)
        'lightwalletdGrpcPort=$lightwalletdGrpcPort',
      if (lightwalletdHttpPort != null)
        'lightwalletdHttpPort=$lightwalletdHttpPort',
      if (operationId != null) 'opid=$operationId',
      if (operationStatus != null) 'status=$operationStatus',
      if (operationTxid != null) 'txid=$operationTxid',
      if (backendHeight != null) 'backendHeight=$backendHeight',
      if (lightwalletdHeight != null) 'lightwalletdHeight=$lightwalletdHeight',
      if (compactBlockRange != null) 'compactBlockRange=$compactBlockRange',
      if (streamedCompactBlockHeights.isNotEmpty)
        'streamedCompactBlockHeights=$streamedCompactBlockHeights',
      if (scannerSummary != null) 'scannerSummary=$scannerSummary',
      if (walletAAddressPrefix != null)
        'walletAAddressPrefix=$walletAAddressPrefix',
      if (walletBAddressPrefix != null)
        'walletBAddressPrefix=$walletBAddressPrefix',
      if (walletAZkeyPrefix != null) 'walletAZkeyPrefix=$walletAZkeyPrefix',
      if (importResult != null) 'importResult=$importResult',
      if (privateBalance != null) 'privateBalance=$privateBalance',
      if (preShieldHeight != null) 'preShieldHeight=$preShieldHeight',
      if (shieldConfirmedHeight != null)
        'shieldConfirmedHeight=$shieldConfirmedHeight',
      if (sendConfirmedHeight != null)
        'sendConfirmedHeight=$sendConfirmedHeight',
      if (harnessDiagnostics != null && harnessDiagnostics!.isNotEmpty)
        harnessDiagnostics!,
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

class _WalletMaterial {
  final String label;
  final String seedHex;
  final String ufvk;
  final String ua;
  final String saplingAddress;
  final String? orchardAddress;
  final String? transparentAddress;
  final String? saplingSpendingKey;

  const _WalletMaterial({
    required this.label,
    required this.seedHex,
    required this.ufvk,
    required this.ua,
    required this.saplingAddress,
    required this.orchardAddress,
    required this.transparentAddress,
    required this.saplingSpendingKey,
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

class _PrivateBalanceProof {
  final int attempts;
  final int privateZatoshis;
  final int transparentZatoshis;
  final int totalZatoshis;

  const _PrivateBalanceProof({
    required this.attempts,
    required this.privateZatoshis,
    required this.transparentZatoshis,
    required this.totalZatoshis,
  });

  String get safeSummary =>
      'attempts=$attempts private=$privateZatoshis '
      'transparent=$transparentZatoshis total=$totalZatoshis';
}

_WalletMaterial _deriveWallet({
  required String label,
  required String seedHex,
  required bool includeSaplingSpendingKey,
}) {
  final ufvk = _deriveUfvk(seedHex, _network, label: label);
  final addressSet = _deriveAddressSet(ufvk, _network, label: label);
  final saplingAddress = _requireSaplingReceiver(
    addressSet,
    label: label,
    ufvk: ufvk,
  );
  final zkey = includeSaplingSpendingKey
      ? _deriveSaplingSpendingKey(seedHex, _network, label: label)
      : null;
  if (zkey != null && !zkey.startsWith('secret-extended-key-regtest')) {
    throw TwoWalletE2eException(
      'Sapling spending key must use zcashd regtest HRP; '
      'keyPrefix=${_safePrefix(zkey)}',
      phase: 'derive-$label',
      walletLabel: label,
      walletAZkeyPrefix: _safePrefix(zkey),
      redactSensitive: [seedHex, ufvk, zkey, saplingAddress],
    );
  }
  return _WalletMaterial(
    label: label,
    seedHex: seedHex,
    ufvk: ufvk,
    ua: addressSet.ua,
    saplingAddress: saplingAddress,
    orchardAddress: addressSet.orchard,
    transparentAddress: addressSet.transparent,
    saplingSpendingKey: zkey,
  );
}

String _deriveUfvk(String seedHex, String network, {required String label}) {
  final raw = ZcashFfiBindings.instance.seedToAccountUfvk(seedHex, network, 0);
  return _requiredFfiString(
    raw,
    'ufvk',
    context: 'seed_to_account_ufvk/$label',
    redact: [seedHex],
  );
}

String _deriveSaplingSpendingKey(
  String seedHex,
  String network, {
  required String label,
}) {
  final raw = ZcashFfiBindings.instance.seedToSaplingSpendingKey(
    seedHex,
    network,
    0,
  );
  return _requiredFfiString(
    raw,
    'sapling_spending_key',
    context: 'seed_to_sapling_spending_key/$label',
    redact: [seedHex],
  );
}

_DerivedAddressSet _deriveAddressSet(
  String ufvk,
  String network, {
  required String label,
}) {
  final raw = ZcashFfiBindings.instance.ufvkToAddress(ufvk, network, 0);
  final json = _ffiObject(
    raw,
    context: 'ufvk_to_address/$label',
    redact: [ufvk],
  );
  return _DerivedAddressSet(
    ua: _requiredString(json, 'ua', context: 'ufvk_to_address/$label'),
    sapling: _optionalString(
      json,
      'sapling',
      context: 'ufvk_to_address/$label',
    ),
    orchard: _optionalString(
      json,
      'orchard',
      context: 'ufvk_to_address/$label',
    ),
    transparent: _optionalString(
      json,
      'transparent',
      context: 'ufvk_to_address/$label',
    ),
  );
}

String _requireSaplingReceiver(
  _DerivedAddressSet set, {
  required String label,
  required String ufvk,
}) {
  final sapling = set.sapling;
  if (sapling != null && sapling.isNotEmpty) return sapling;
  throw TwoWalletE2eException(
    'derived UFVK address set is missing Sapling receiver; '
    'uaPrefix=${_prefix(set.ua)} orchardPresent=${set.orchard != null} '
    'transparentPresent=${set.transparent != null}',
    phase: 'derive-$label',
    walletLabel: label,
    redactSensitive: [ufvk, set.ua, ?sapling],
  );
}

void _assertSaplingImportResult(
  ZImportKeyResult result, {
  required _WalletMaterial walletA,
  required int rpcPort,
}) {
  if (result.keyType != null &&
      !result.keyType!.toLowerCase().contains('sapling')) {
    throw TwoWalletE2eException(
      'z_importkey returned non-Sapling type: ${result.safeSummary}',
      phase: 'import-wallet-a',
      walletLabel: walletA.label,
      zcashdRpcPort: rpcPort,
      importResult: result.safeSummary,
      walletAZkeyPrefix: _safePrefix(walletA.saplingSpendingKey),
      walletAAddressPrefix: _prefix(walletA.saplingAddress),
      redactSensitive: [
        walletA.seedHex,
        walletA.ufvk,
        walletA.saplingSpendingKey!,
        walletA.saplingAddress,
      ],
    );
  }
  final address = result.address;
  if (address != null &&
      !address.startsWith('zregtestsapling') &&
      !address.startsWith('ztestsapling')) {
    throw TwoWalletE2eException(
      'z_importkey returned a non-Sapling address prefix: ${_prefix(address)}',
      phase: 'import-wallet-a',
      walletLabel: walletA.label,
      zcashdRpcPort: rpcPort,
      importResult: result.safeSummary,
      walletAZkeyPrefix: _safePrefix(walletA.saplingSpendingKey),
      walletAAddressPrefix: _prefix(walletA.saplingAddress),
      redactSensitive: [
        walletA.seedHex,
        walletA.ufvk,
        walletA.saplingSpendingKey!,
        walletA.saplingAddress,
        address,
      ],
    );
  }
}

BlockRange _heightRange(int startHeight, int endHeight) {
  if (startHeight > endHeight) {
    throw TwoWalletE2eException(
      'empty compact block range $startHeight..$endHeight',
      phase: 'build-compact-block-range',
      compactBlockRange: '$startHeight..$endHeight',
      streamedCompactBlockHeights: [startHeight, endHeight],
    );
  }
  return BlockRange()
    ..start = (BlockID()..height = Int64(startHeight))
    ..end = (BlockID()..height = Int64(endHeight));
}

List<int> _compactHeights(List<CompactBlock> blocks) =>
    blocks.map((block) => block.height.toInt()).toList(growable: false);

ZcashScanResult _scanWalletCompactBlocks(
  _WalletMaterial wallet,
  List<CompactBlock> blocks,
) => scanCompactBlocks(
  ufvk: wallet.ufvk,
  network: _network,
  blocks: blocks.map(
    (block) => CompactBlockScanInput.fromBytes(
      block.writeToBuffer(),
      height: block.height.toInt(),
    ),
  ),
);

ZcashScannedNote _requireDiscoveredNote(
  ZcashScanResult result, {
  required String walletLabel,
  required List<int> scannedHeights,
  required int rangeStart,
  required int rangeEnd,
  required int minValueZatoshis,
  required String ufvk,
  required String saplingAddress,
}) {
  final matchingNotes = result.notes
      .where(
        (note) =>
            note.value >= minValueZatoshis &&
            note.height >= rangeStart &&
            note.height <= rangeEnd &&
            note.pool == 'sapling',
      )
      .toList(growable: false);
  if (result.discoveredNotes > 0 &&
      result.totalValue >= minValueZatoshis &&
      matchingNotes.isNotEmpty) {
    return matchingNotes.first;
  }
  throw TwoWalletE2eException(
    'zero-note scanner result or no Sapling note in confirmed range; '
    'range=$rangeStart..$rangeEnd scannedBlocks=${result.scannedBlocks} '
    'discoveredNotes=${result.discoveredNotes} totalValue=${result.totalValue} '
    'minValueZatoshis=$minValueZatoshis',
    phase: 'scan-$walletLabel',
    walletLabel: walletLabel,
    compactBlockRange: '$rangeStart..$rangeEnd',
    streamedCompactBlockHeights: scannedHeights,
    scannerSummary: _scanSummary(result),
    redactSensitive: [ufvk, saplingAddress],
  );
}

void _requireTxid(
  ZcashOperationStatus status, {
  required String phase,
  required String operationId,
}) {
  final txid = status.txid;
  if (txid != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(txid)) return;
  throw TwoWalletE2eException(
    'operation completed without a txid',
    phase: phase,
    operationId: operationId,
    operationStatus: status.status,
    operationTxid: txid,
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
      throw TwoWalletE2eException(
        'mature coinbase balance stayed zero after mining',
        phase: 'maturity-mining',
        zcashdRpcPort: harness.rpcPort,
        backendHeight: finalHeight,
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
    throw TwoWalletE2eException(
      'mature coinbase balance proof failed; requestedBlocks=$maturityBlocks '
      'initialHeight=$initialHeight currentHeight=$currentHeight '
      'initialSpendable=$initialSpendable currentSpendable=$currentBalance '
      'error=$error',
      phase: 'maturity-mining',
      zcashdRpcPort: harness.rpcPort,
      harnessDiagnostics: harness.diagnosticSummary(phase: 'maturity-mining'),
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
      _upgradeActivationHeight(initialSapling) ?? _saplingActivationHeight;
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
      throw TwoWalletE2eException(
        'Sapling did not become active before shield operation',
        phase: 'sapling-activation',
        zcashdRpcPort: harness.rpcPort,
        backendHeight: finalHeight,
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
    throw TwoWalletE2eException(
      'Sapling activation mining failed before shield operation; '
      'initialHeight=$initialHeight currentHeight=$currentHeight '
      'activationHeight=$activationHeight blocksToMine=$blocksToMine '
      'error=$error',
      phase: 'sapling-activation',
      zcashdRpcPort: harness.rpcPort,
      harnessDiagnostics: harness.diagnosticSummary(
        phase: 'sapling-activation',
      ),
    );
  }
}

Future<_PrivateBalanceProof> _waitForPrivateBalance(
  ZcashdHarness harness, {
  required int minZatoshis,
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  var attempts = 0;
  ZcashTotalBalance? lastBalance;
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    attempts += 1;
    try {
      final balance = await harness.client.zGetTotalBalance(minConf: 1);
      lastBalance = balance;
      if (balance.privateZatoshis >= minZatoshis) {
        return _PrivateBalanceProof(
          attempts: attempts,
          privateZatoshis: balance.privateZatoshis,
          transparentZatoshis: balance.transparentZatoshis,
          totalZatoshis: balance.totalZatoshis,
        );
      }
    } on Object catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw TwoWalletE2eException(
    'wallet A private balance was not recognized as spendable; '
    'minZatoshis=$minZatoshis attempts=$attempts '
    'lastPrivate=${lastBalance?.privateZatoshis ?? 'unavailable'} '
    'lastTotal=${lastBalance?.totalZatoshis ?? 'unavailable'} '
    'lastError=${lastError ?? 'none'}',
    phase: 'wait-wallet-a-spendability',
    zcashdRpcPort: harness.rpcPort,
    privateBalance: lastBalance == null
        ? null
        : 'private=${lastBalance.privateZatoshis} '
              'transparent=${lastBalance.transparentZatoshis} '
              'total=${lastBalance.totalZatoshis}',
    harnessDiagnostics: harness.diagnosticSummary(
      phase: 'wait-wallet-a-spendability',
    ),
  );
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

String _requiredFfiString(
  String raw,
  String key, {
  required String context,
  Iterable<String> redact = const [],
}) => _requiredString(
  _ffiObject(raw, context: context, redact: redact),
  key,
  context: context,
);

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

String? _latestRange(List<int> heights) {
  if (heights.isEmpty) return null;
  return '${heights.first}..${heights.last}';
}

String _prefix(String? value) {
  if (value == null || value.isEmpty) return 'unavailable';
  final end = value.length < 12 ? value.length : 12;
  return '${value.substring(0, end)}…(${value.length} chars)';
}

String _safePrefix(String? value) => _prefix(value);

String _redactProofDiagnostics(String input, Iterable<String> sensitiveValues) {
  return _redact(input, sensitiveValues)
      .replaceAll(RegExp(r'rpcpassword=[^\s]+'), 'rpcpassword=<redacted>')
      .replaceAll(RegExp(r'rpcuser=[^\s]+'), 'rpcuser=<redacted>')
      .replaceAll(
        RegExp(r'Authorization:\s*Basic\s+[^\s]+', caseSensitive: false),
        'Authorization: Basic <redacted>',
      )
      .replaceAll(
        RegExp(
          r'secret-extended-key-(?:main|test|regtest)[0-9a-z]+',
          caseSensitive: false,
        ),
        'secret-extended-key-<redacted>',
      )
      .replaceAll(
        RegExp(r'uview(?:test)?[0-9a-z]+', caseSensitive: false),
        'uview<redacted>',
      )
      .replaceAll(
        RegExp(r'z(?:regtest|test)sapling[0-9a-z]+', caseSensitive: false),
        'zsapling<redacted>',
      );
}

String _redact(String input, Iterable<String> sensitiveValues) {
  var redacted = input;
  for (final value in sensitiveValues) {
    if (value.isNotEmpty) redacted = redacted.replaceAll(value, '<redacted>');
  }
  return redacted;
}

void _phaseLog(String phase, Map<String, Object?> fields) {
  final suffix = fields.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  // ignore: avoid_print
  print('two-wallet-e2e phase=$phase $suffix');
}
