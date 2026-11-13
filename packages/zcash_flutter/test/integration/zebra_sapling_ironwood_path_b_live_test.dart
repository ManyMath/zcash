@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

import 'harness.dart';
import 'lightwalletd_harness.dart';

// Proves the ordinary post-NU6.3 Path B on a staged chain:
// transparent -> Sapling below activation, then Sapling -> Ironwood above it.
// This is intentionally gated on real node, server, native, and proving
// artifacts. A missing prerequisite skips the whole contract; once enabled,
// every failed prerequisite is fatal and no test returns early.
void main() {
  final schedule = ZebraConsensusSchedule.stagedNu63(activationHeight: 130);
  final nu63Activation = schedule.nativeRegtestNu63ActivationHeight!;
  const maturityHeight = 101;

  final zebraBin = Platform.environment['ZEBRA_BIN'] ?? '';
  final lightwalletdBin = Platform.environment['LIGHTWALLETD_BIN'] ?? '';
  final ffiLib = Platform.environment['ZCASH_FFI_LIB'] ?? '';
  final spendParams = Platform.environment['ZCASH_SAPLING_SPEND_PARAMS'] ?? '';
  final outputParams =
      Platform.environment['ZCASH_SAPLING_OUTPUT_PARAMS'] ?? '';
  final enabled =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
      Platform.environment.containsKey('LIGHTWALLETD_INTEGRATION') &&
      zebraBin.isNotEmpty &&
      lightwalletdBin.isNotEmpty &&
      ffiLib.isNotEmpty &&
      spendParams.isNotEmpty &&
      outputParams.isNotEmpty;

  ZebraHarness? zebra;
  LightwalletdHarness? lightwalletd;
  ZcashFfiBindings? ffi;
  Directory? parameterCache;
  SaplingProvingParameters? provingParameters;
  ZcashAccountMetadata? account;
  String? saplingAddress;
  int? sourceHeight;
  int? sourceValue;
  String? sourceTxid;

  setUpAll(() async {
    if (!enabled) return;

    for (final prerequisite in {
      'ZEBRA_BIN': zebraBin,
      'LIGHTWALLETD_BIN': lightwalletdBin,
      'ZCASH_FFI_LIB': ffiLib,
      'ZCASH_SAPLING_SPEND_PARAMS': spendParams,
      'ZCASH_SAPLING_OUTPUT_PARAMS': outputParams,
    }.entries) {
      if (FileSystemEntity.typeSync(prerequisite.value) !=
          FileSystemEntityType.file) {
        fail('${prerequisite.key} does not name a regular file');
      }
    }

    ffi = ZcashFfiBindings.open(ffiLib);
    account = deriveNativeAccountMetadata(
      seedHex: _testSeedHex,
      network: ZcashNetwork.regtest,
      bindings: ffi,
    );
    saplingAddress = _accountSaplingAddress(ffi!, account!.ufvk);

    parameterCache = await Directory.systemTemp.createTemp(
      'zcash-path-b-params-',
    );
    provingParameters =
        await SaplingProvingParameterCache(cacheRoot: parameterCache!).resolve(
          source: FileSaplingParameterSource(
            manifest: officialSaplingParameterManifestV1,
            spendFile: File(spendParams),
            outputFile: File(outputParams),
          ),
        );
    expect(
      provingParameters!.version,
      officialSaplingParameterManifestV1.version,
    );

    zebra = await ZebraHarness.start(
      zebraBinary: zebraBin,
      schedule: schedule,
      minerAddress: kIronwoodProofMinerAddress,
    );
    await zebra!.mineBlocks(maturityHeight);
    final tip = await zebra!.client.getBlockCount();
    expect(tip, lessThan(nu63Activation));
    final coin = await _oneMatureCoin(zebra!, tip);

    final source = buildNativeSaplingTransaction(
      network: ZcashNetwork.regtest,
      targetHeight: tip + 1,
      regtestNu63ActivationHeight: nu63Activation,
      seedHex: _testSeedHex,
      inputs: [
        TransparentBuildInput(
          txid: coin.txid,
          vout: coin.outputIndex,
          valueZatoshis: coin.satoshis,
          secretKeyHex: kIronwoodProofMinerSecretKeyHex,
        ),
      ],
      outputs: [SaplingBuildOutput(address: saplingAddress!)],
      spendParamsPath: provingParameters!.spendParamsPath,
      outputParamsPath: provingParameters!.outputParamsPath,
      allowExperimentalSaplingBuild: true,
      bindings: ffi,
    );
    expect(source.consensusBranchId, 'nu6.2');
    expect(source.hasRealProofs, isTrue);
    expect(source.transparentVin, 1);
    expect(source.saplingSpends, 0);
    expect(
      source.saplingOutputs,
      2,
      reason: 'ZIP 317 pads a one-output Sapling bundle to two actions',
    );
    expect(source.transparentInputZatoshis, coin.satoshis);
    expect(source.totalSpentZatoshis, 0);
    expect(
      source.transparentInputZatoshis,
      source.totalOutputZatoshis + source.feeZatoshis,
    );

    sourceTxid = await zebra!.client.sendRawTransaction(source.transactionHex);
    expect(sourceTxid, source.txid);
    await _mineAcceptedTransaction(zebra!, sourceTxid!);
    sourceHeight = await zebra!.client.getBlockCount();
    sourceValue = source.totalOutputZatoshis;
    expect(sourceHeight, lessThan(nu63Activation));

    await _mineTo(zebra!, nu63Activation + 2);
    expect(await zebra!.client.getBlockCount(), greaterThan(nu63Activation));
    lightwalletd = await LightwalletdHarness.start(
      backend: LightwalletdBackend.zebra(rpcPort: zebra!.rpcPort),
    );
    await lightwalletd!.waitForSyncHeight(
      await zebra!.client.getBlockCount(),
      readBackendHeight: zebra!.client.getBlockCount,
    );
  });

  tearDownAll(() async {
    final server = lightwalletd;
    lightwalletd = null;
    if (server != null) await server.shutdown();
    final node = zebra;
    zebra = null;
    if (node != null) await node.shutdown();
    final cache = parameterCache;
    parameterCache = null;
    if (cache != null && await cache.exists()) {
      await cache.delete(recursive: true);
    }
  });

  test(
    'migrates a pre-activation Sapling note through Path B and spends the '
    'restored Ironwood note back to Sapling',
    () async {
      if (zebra == null ||
          lightwalletd == null ||
          ffi == null ||
          provingParameters == null ||
          account == null ||
          saplingAddress == null ||
          sourceHeight == null ||
          sourceValue == null ||
          sourceTxid == null) {
        fail('live Path B setup did not complete');
      }

      final node = zebra!;
      final server = lightwalletd!;
      final bindings = ffi!;
      final metadata = account!;
      final sourceProtocolTxid = reverseTxidByteOrder(sourceTxid!);

      final wallet = ZcashWalletSyncState.atBirthday(
        network: ZcashAddressNetwork.regtest,
        accountFingerprint: metadata.fingerprint,
        cursor: ZcashLightwalletdSyncCursor.fromTreeState(
          treeStateFromLightwalletd(
            await server.client.getTreeStateAtHeight(sourceHeight! - 1),
          ),
        ),
      );
      var sync = _openWitnessSync(
        wallet: wallet,
        zebra: node,
        lightwalletd: server,
        ffi: bindings,
        ufvk: metadata.ufvk,
      );
      final initialRanges = <ZcashSyncAdvanced>[];
      expect(
        await sync.syncToTip(onAdvanced: initialRanges.add),
        isA<ZcashSyncCaughtUp>(),
      );
      expect(initialRanges, isNotEmpty);
      final sourceNote = wallet.sapling.notes.singleWhere(
        (note) => note.tx == sourceProtocolTxid,
      );
      expect(sourceNote.height, sourceHeight);
      expect(sourceNote.value, sourceValue);
      expect(sourceNote.pool, 'sapling');
      expect(sourceNote.nullifier, isNotNull);
      expect(sourceNote.recipient, saplingAddress);
      expect(sourceNote.rseed, isNotNull);
      expect(sourceNote.witness, isNotNull);
      expect(
        SaplingNoteSet.fromScan(
          notes: wallet.sapling.notes,
          spends: wallet.sapling.spends,
        ).spendable,
        contains(sourceNote),
      );

      expect(
        initialRanges.last.scan.ironwoodAnchor,
        isNull,
        reason:
            'a scan reports no root for a size-zero tree; the explicit '
            'consensus empty-tree root is required for the first output',
      );
      final initialScan = _walletScan(
        wallet,
        saplingAnchor: initialRanges.last.scan.saplingAnchor,
        ironwoodAnchor: orchardFamilyEmptyTreeRootHex,
      );
      expect(initialScan.saplingAnchor, isNotNull);
      expect(initialScan.ironwoodAnchor, isNotNull);

      final tip = await node.client.getBlockCount();
      final targetHeight = tip + 1;
      final expiryHeight = targetHeight + 40;
      final decoded = decodeNativeAddress(
        address: kIronwoodProofUnifiedAddress,
        network: ZcashNetwork.regtest,
        bindings: bindings,
      );
      final inventory = inventoryUnifiedAddressReceivers(
        address: kIronwoodProofUnifiedAddress,
        network: ZcashNetwork.regtest,
        bindings: bindings,
      );
      final amount = sourceNote.value ~/ 2;
      final routed = resolveProposalOutput(
        recipient: ProposalRecipient(
          address: kIronwoodProofUnifiedAddress,
          amountZatoshis: amount,
        ),
        address: decoded,
        unifiedReceivers: inventory,
        network: ZcashAddressNetwork.regtest,
        targetHeight: targetHeight,
        transactionExpiryHeight: expiryHeight,
        currentUnixTime: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      );
      expect(routed.encodedAddress, kIronwoodProofUnifiedAddress);
      expect(routed.receiverAddress, kIronwoodProofUnifiedAddress);
      expect(routed.selectedReceiver, ZcashAddressReceiverType.orchard);
      expect(routed.actualOutputPool, ProposalOutputPool.ironwood);
      expect(routed.amountZatoshis, amount);

      final preActivationTarget = nu63Activation - 1;
      final preActivationOutput = resolveProposalOutput(
        recipient: ProposalRecipient(
          address: kIronwoodProofUnifiedAddress,
          amountZatoshis: amount,
        ),
        address: decoded,
        unifiedReceivers: inventory,
        network: ZcashAddressNetwork.regtest,
        targetHeight: preActivationTarget,
        transactionExpiryHeight: preActivationTarget + 40,
        currentUnixTime: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        () => prepareNativeSaplingPayment(
          scan: initialScan,
          output: preActivationOutput,
          saplingChangeAddress: saplingAddress!,
          targetHeight: preActivationTarget,
          expiryHeight: preActivationTarget + 40,
          provingParameters: provingParameters!,
          network: ZcashNetwork.regtest,
          seedHex: _testSeedHex,
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalIronwoodBuild: true,
          bindings: bindings,
        ),
        throwsA(
          isA<StateError>()
              .having(
                (error) => error.toString(),
                'category',
                contains('ironwood_not_active'),
              )
              .having(
                (error) => error.toString(),
                'activation',
                contains('not active'),
              ),
        ),
        reason: 'Path B is a post-NU6.3 route and must fail below activation',
      );

      expect(
        () => prepareNativeSaplingPayment(
          scan: ZcashScanResult(
            scannedBlocks: initialScan.scannedBlocks,
            discoveredNotes: initialScan.discoveredNotes,
            totalValue: initialScan.totalValue,
            notes: initialScan.notes,
            spends: initialScan.spends,
            saplingAnchor: initialScan.saplingAnchor,
          ),
          output: routed,
          saplingChangeAddress: saplingAddress!,
          targetHeight: targetHeight,
          expiryHeight: expiryHeight,
          provingParameters: provingParameters!,
          network: ZcashNetwork.regtest,
          seedHex: _testSeedHex,
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalIronwoodBuild: true,
          bindings: bindings,
        ),
        throwsA(
          isA<IronwoodSendException>().having(
            (error) => error.refusal,
            'refusal',
            IronwoodSendRefusal.noIronwoodAnchor,
          ),
        ),
        reason: 'a Sapling anchor cannot stand in for the destination tree',
      );

      final prepared = prepareNativeSaplingPayment(
        scan: initialScan,
        output: routed,
        saplingChangeAddress: saplingAddress!,
        targetHeight: targetHeight,
        expiryHeight: expiryHeight,
        provingParameters: provingParameters!,
        network: ZcashNetwork.regtest,
        seedHex: _testSeedHex,
        regtestNu63ActivationHeight: nu63Activation,
        allowExperimentalIronwoodBuild: true,
        bindings: bindings,
      );
      final built = prepared.transaction;
      expect(prepared.plan.notes, [sourceNote]);
      expect(prepared.plan.amountZatoshis, amount);
      expect(prepared.plan.changeAddress, saplingAddress);
      expect(prepared.plan.feeZatoshis, built.feeZatoshis);
      expect(
        prepared.plan.inputZatoshis,
        prepared.plan.amountZatoshis +
            prepared.plan.feeZatoshis +
            prepared.plan.changeZatoshis,
      );
      expect(prepared.plan.changeZatoshis, greaterThan(0));
      expect(built.version, 'v6');
      expect(built.consensusBranchId, 'nu6.3');
      expect(built.feeRule, 'zip317');
      expect(built.isConsensusValid, isTrue);
      expect(built.saplingSpends, 1);
      expect(built.saplingInputZatoshis, sourceNote.value);
      expect(built.saplingOutputs, 2);
      expect(built.nonIronwoodOutputZatoshis, prepared.plan.changeZatoshis);
      expect(
        built.ironwoodActions,
        2,
        reason: 'ZIP 317 also pads a one-output Ironwood bundle to two actions',
      );
      expect(built.ironwoodSpends, 0);
      expect(built.ironwoodOutputZatoshis, amount);
      expect(built.ironwoodChangeZatoshis, 0);
      expect(built.totalInputZatoshis, sourceNote.value);

      final pathBTxid = await node.client.sendRawTransaction(
        built.transactionHex,
      );
      expect(pathBTxid, built.txid);
      await _mineAcceptedTransaction(node, pathBTxid);
      final pathBHeight = await node.client.getBlockCount();
      expect(pathBHeight, greaterThan(nu63Activation));

      await server.waitForSyncHeight(
        pathBHeight,
        readBackendHeight: node.client.getBlockCount,
      );
      final paymentRanges = <ZcashSyncAdvanced>[];
      expect(
        await sync.syncToTip(onAdvanced: paymentRanges.add),
        isA<ZcashSyncCaughtUp>(),
      );
      expect(paymentRanges, hasLength(1));
      final paymentScan = paymentRanges.single.scan;
      final pathBProtocolTxid = reverseTxidByteOrder(pathBTxid);
      expect(
        wallet.sapling.spends
            .singleWhere((spend) => spend.nullifier == sourceNote.nullifier)
            .tx,
        pathBProtocolTxid,
      );
      final change = wallet.sapling.notes.singleWhere(
        (note) => note.tx == pathBProtocolTxid,
      );
      expect(change.pool, 'sapling');
      expect(change.value, prepared.plan.changeZatoshis);
      expect(change.recipient, saplingAddress);
      expect(change.witness, isNotNull);
      final destination = wallet.ironwood.notes.singleWhere(
        (note) => note.tx == pathBProtocolTxid,
      );
      expect(destination.pool, 'ironwood');
      expect(destination.value, amount);
      expect(destination.noteVersion, 'v3');
      expect(destination.recipient, isNotNull);
      expect(destination.rseed, isNotNull);
      expect(destination.rho, isNotNull);
      expect(destination.nullifier, isNotNull);
      expect(destination.witness, isNotNull);

      final restored = ZcashWalletSyncState.fromJson(
        (jsonDecode(jsonEncode(wallet.toJson())) as Map)
            .cast<String, Object?>(),
      );
      final restoredSapling = SaplingNoteSet.fromScan(
        notes: restored.sapling.notes,
        spends: restored.sapling.spends,
      );
      expect(restoredSapling.spent.single.note.nullifier, sourceNote.nullifier);
      expect(restoredSapling.spendable.single.value, change.value);
      final restoredIronwood = IronwoodNoteSet.fromScan(
        notes: restored.ironwood.notes,
        spends: restored.ironwood.spends,
      );
      expect(restoredIronwood.spendable, hasLength(1));
      expect(restoredIronwood.spendable.single.value, amount);
      expect(restoredIronwood.spendable.single.witness, destination.witness);

      final spendScan = _walletScan(
        restored,
        saplingAnchor: paymentScan.saplingAnchor,
        ironwoodAnchor: paymentScan.ironwoodAnchor,
      );
      final spendAmount = amount ~/ 2;
      final saplingOutput = resolveProposalOutput(
        recipient: ProposalRecipient(
          address: saplingAddress!,
          amountZatoshis: spendAmount,
        ),
        address: decodeNativeAddress(
          address: saplingAddress!,
          network: ZcashNetwork.regtest,
          bindings: bindings,
        ),
        network: ZcashAddressNetwork.regtest,
        targetHeight: pathBHeight + 1,
        transactionExpiryHeight: pathBHeight + 41,
        currentUnixTime: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      );
      expect(saplingOutput.encodedAddress, saplingAddress);
      expect(saplingOutput.receiverAddress, saplingAddress);
      expect(saplingOutput.selectedReceiver, ZcashAddressReceiverType.sapling);
      expect(saplingOutput.actualOutputPool, ProposalOutputPool.sapling);
      final spend = prepareNativeIronwoodPayment(
        network: ZcashNetwork.regtest,
        scan: spendScan,
        output: saplingOutput,
        ironwoodChangeAddress: kIronwoodProofUnifiedAddress,
        targetHeight: pathBHeight + 1,
        expiryHeight: pathBHeight + 41,
        seedHex: _testSeedHex,
        regtestNu63ActivationHeight: nu63Activation,
        provingParameters: provingParameters!,
        allowExperimentalIronwoodBuild: true,
        bindings: bindings,
      );
      expect(spend.plan.notes, [restoredIronwood.spendable.single]);
      expect(spend.plan.amountZatoshis, spendAmount);
      expect(spend.transaction.version, 'v6');
      expect(spend.transaction.consensusBranchId, 'nu6.3');
      expect(spend.transaction.feeRule, 'zip317');
      expect(spend.transaction.spendsIronwood, isTrue);
      expect(spend.transaction.isConsensusValid, isTrue);
      expect(spend.transaction.ironwoodInputZatoshis, amount);
      expect(spend.transaction.saplingOutputs, 2);
      expect(spend.transaction.nonIronwoodOutputZatoshis, spendAmount);
      expect(
        spend.transaction.ironwoodOutputZatoshis,
        spend.plan.changeZatoshis,
      );
      expect(spend.transaction.ironwoodChangeZatoshis, 0);
      expect(
        spend.plan.inputZatoshis,
        spend.plan.amountZatoshis +
            spend.plan.feeZatoshis +
            spend.plan.changeZatoshis,
      );

      final spendTxid = await node.client.sendRawTransaction(
        spend.transactionHex,
      );
      expect(spendTxid, spend.transaction.txid);
      await _mineAcceptedTransaction(node, spendTxid);
      final spendHeight = await node.client.getBlockCount();
      await server.waitForSyncHeight(
        spendHeight,
        readBackendHeight: node.client.getBlockCount,
      );

      sync = _openWitnessSync(
        wallet: restored,
        zebra: node,
        lightwalletd: server,
        ffi: bindings,
        ufvk: metadata.ufvk,
      );
      expect(await sync.syncToTip(), isA<ZcashSyncCaughtUp>());
      final finalSet = IronwoodNoteSet.fromScan(
        notes: restored.ironwood.notes,
        spends: restored.ironwood.spends,
      );
      expect(
        finalSet.spent.single.note.nullifier,
        destination.nullifier,
        reason:
            'the note recovered and restored from the Path B transaction was '
            'accepted as an Ironwood spend and observed spent',
      );
      expect(finalSet.spent.single.spend!.tx, reverseTxidByteOrder(spendTxid));
      expect(finalSet.spendable.single.value, spend.plan.changeZatoshis);
      final finalSapling = restored.sapling.notes.singleWhere(
        (note) => note.tx == reverseTxidByteOrder(spendTxid),
      );
      expect(finalSapling.pool, 'sapling');
      expect(finalSapling.value, spendAmount);
      expect(finalSapling.witness, isNotNull);
      expect(
        () => ZcashWalletSyncState.fromJson(
          (jsonDecode(jsonEncode(restored.toJson())) as Map)
              .cast<String, Object?>(),
        ),
        returnsNormally,
      );
    },
    skip: enabled
        ? false
        : 'needs ZEBRA_INTEGRATION, LIGHTWALLETD_INTEGRATION and regular-file '
              'ZEBRA_BIN, LIGHTWALLETD_BIN, ZCASH_FFI_LIB, '
              'ZCASH_SAPLING_SPEND_PARAMS, and ZCASH_SAPLING_OUTPUT_PARAMS',
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

ZcashChainSync _openWitnessSync({
  required ZcashWalletSyncState wallet,
  required ZebraHarness zebra,
  required LightwalletdHarness lightwalletd,
  required ZcashFfiBindings ffi,
  required String ufvk,
}) => wallet.syncThrough(
  network: 'regtest',
  includeSaplingWitnesses: true,
  includeOrchardWitnesses: true,
  rangeSize: 100,
  chainTip: zebra.client.getBlockCount,
  fetchRange: (start, end) => _fetchRange(lightwalletd, start: start, end: end),
  fetchTreeState: (height) async => treeStateFromLightwalletd(
    await lightwalletd.client.getTreeStateAtHeight(height),
  ),
  servedBlockHashAt: (height) async {
    try {
      return (await _fetchRange(
        lightwalletd,
        start: height,
        end: height,
      )).lastBlockHash;
    } on Object {
      return null;
    }
  },
  scan: (envelope) async => ZcashScanResult.fromJson(
    _nativeOk(ffi.scanCompactBlocksRaw(ufvk, 'regtest', envelope.encode())),
    allowExperimentalOrchardNotes: true,
  ),
);

Future<ZcashLightwalletdScanSource> _fetchRange(
  LightwalletdHarness lightwalletd, {
  required int start,
  required int end,
}) async {
  final range = BlockRange()
    ..start = (BlockID()..height = Int64(start))
    ..end = (BlockID()..height = Int64(end));
  return ZcashLightwalletdScanSource(
    await lightwalletd.fetchCompactBlockRange(range).toList(),
  );
}

ZcashScanResult _walletScan(
  ZcashWalletSyncState wallet, {
  required String? saplingAnchor,
  required String? ironwoodAnchor,
}) {
  final notes = [
    ...wallet.sapling.notes,
    ...wallet.orchard.notes,
    ...wallet.ironwood.notes,
  ];
  final spends = [
    ...wallet.sapling.spends,
    ...wallet.orchard.spends,
    ...wallet.ironwood.spends,
  ];
  return ZcashScanResult(
    scannedBlocks: 0,
    discoveredNotes: notes.length,
    totalValue: notes.fold(0, (sum, note) => sum + note.value),
    notes: notes,
    spends: spends,
    saplingAnchor: saplingAnchor,
    ironwoodAnchor: ironwoodAnchor,
  );
}

Future<AddressUtxo> _oneMatureCoin(ZebraHarness zebra, int tip) async {
  final utxos = await zebra.client.getAddressUtxos([
    kIronwoodProofMinerAddress,
  ]);
  final mature = utxos.where((utxo) => utxo.height <= tip - 100).toList();
  if (mature.isEmpty) {
    throw StateError('no mature coinbase output exists at height $tip');
  }
  return mature.first;
}

String _accountSaplingAddress(ZcashFfiBindings ffi, String ufvk) {
  final result = _nativeOk(ffi.ufvkToAddress(ufvk, 'regtest', 0));
  final addresses = (result['addresses'] as Map).cast<String, Object?>();
  final address = addresses['sapling'];
  if (address is! String || !address.startsWith('zregtestsapling')) {
    throw StateError('the test account has no regtest Sapling receiver');
  }
  return address;
}

Future<void> _mineTo(ZebraHarness zebra, int height) async {
  final current = await zebra.client.getBlockCount();
  if (current < height) await zebra.mineBlocks(height - current);
}

Future<void> _waitForTemplateTransaction(
  ZebraHarness zebra,
  String txid, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final expected = txid.toLowerCase();
  final deadline = DateTime.now().add(timeout);
  var mempoolCount = 0;
  var templateCount = 0;
  var seenInMempool = false;
  while (DateTime.now().isBefore(deadline)) {
    final mempool = await zebra.client.getRawMempool();
    final template = await zebra.client.getBlockTemplate();
    final templateTxids = <String>{
      for (final transaction in template.transactions)
        for (final key in const ['hash', 'txid'])
          if (transaction[key] is String)
            (transaction[key] as String).toLowerCase(),
    };
    mempoolCount = mempool.length;
    templateCount = template.transactions.length;
    seenInMempool = mempool.any(
      (candidate) => candidate.toLowerCase() == expected,
    );
    if (templateTxids.contains(expected)) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError(
    'accepted transaction did not reach a block template before timeout '
    '(seenInMempool=$seenInMempool, mempoolCount=$mempoolCount, '
    'templateTransactionCount=$templateCount)',
  );
}

Future<void> _mineAcceptedTransaction(ZebraHarness zebra, String txid) async {
  await _waitForTemplateTransaction(zebra, txid);
  final hash = (await zebra.mineBlocks(1)).single;
  final mined = await zebra.client.getBlock(hash);
  if (!mined.transactions.any(
    (candidate) => candidate.toLowerCase() == txid.toLowerCase(),
  )) {
    throw StateError(
      'a transaction present in the selected template was absent from the '
      'mined block',
    );
  }
}

Map<String, Object?> _nativeOk(String raw) {
  final decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
  if (decoded['status'] != 'ok') {
    throw StateError(
      'native call failed [${decoded['category']}]: ${decoded['error']}',
    );
  }
  return decoded;
}

const _testSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
