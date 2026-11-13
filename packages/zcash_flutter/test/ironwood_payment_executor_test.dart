import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

const _anchor =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

class _Backend implements IronwoodPaymentBackend {
  final List<IronwoodPaymentNativeRequest> quotes = [];
  final List<IronwoodPaymentNativeRequest> builds = [];

  @override
  IronwoodFeeQuote quote(IronwoodPaymentNativeRequest request) {
    quotes.add(request);
    final input =
        request.ironwoodSpends.fold<int>(
          0,
          (sum, spend) => sum + spend.valueZatoshis,
        ) +
        request.saplingSpends.fold<int>(
          0,
          (sum, spend) => sum + spend.valueZatoshis,
        );
    final nonIronwood = request.outputs.fold(
      0,
      (sum, output) => sum + output.valueZatoshis,
    );
    final additionalIronwood = request.additionalIronwoodOutputs.fold(
      0,
      (sum, output) => sum + (output.valueZatoshis ?? 0),
    );
    return IronwoodFeeQuote(
      network: ZcashAddressNetwork.regtest,
      feeZatoshis: 10000,
      feeRule: 'zip317',
      consensusBranchId: 'nu6.3',
      totalInputZatoshis: input,
      nonIronwoodOutputZatoshis: nonIronwood,
      maxIronwoodOutputZatoshis:
          input - nonIronwood - additionalIronwood - 10000,
      ironwoodSpends: request.ironwoodSpends.length,
      orchardSpends: 0,
      saplingSpends: request.saplingSpends.length,
      transparentInputs: 0,
    );
  }

  @override
  IronwoodBuildResult build(IronwoodPaymentNativeRequest request) {
    builds.add(request);
    final input =
        request.ironwoodSpends.fold<int>(
          0,
          (sum, spend) => sum + spend.valueZatoshis,
        ) +
        request.saplingSpends.fold<int>(
          0,
          (sum, spend) => sum + spend.valueZatoshis,
        );
    final nonIronwood = request.outputs.fold(
      0,
      (sum, output) => sum + output.valueZatoshis,
    );
    final additionalIronwood = request.additionalIronwoodOutputs.fold(
      0,
      (sum, output) => sum + (output.valueZatoshis ?? 0),
    );
    final transparent = request.outputs.where(
      (output) => output.address.startsWith('t'),
    );
    final sapling = request.outputs.where(
      (output) => output.address.startsWith('z'),
    );
    return IronwoodBuildResult(
      network: ZcashAddressNetwork.regtest,
      transactionHex: 'ff' * 20,
      txid: 'ee' * 32,
      version: 'v6',
      expiryHeight: request.expiryHeight!,
      feeZatoshis: 10000,
      feeRule: 'zip317',
      proofValidity: 'real',
      ironwoodAnchor: request.anchorHex,
      ironwoodAnchorSource: 'anchor',
      vin: 0,
      vout: transparent.length,
      saplingSpends: request.saplingSpends.length,
      saplingOutputs: sapling.isEmpty ? 0 : 2,
      ironwoodActions: 1,
      ironwoodSpends: request.ironwoodSpends.length,
      ironwoodOutputs:
          1 +
          request.additionalIronwoodOutputs.length +
          (request.ironwoodChangeZatoshis == null ? 0 : 1),
      ironwoodChangeOutputs: request.ironwoodChangeZatoshis == null ? 0 : 1,
      totalInputZatoshis: input,
      saplingInputZatoshis: request.saplingSpends.fold<int>(
        0,
        (sum, spend) => sum + spend.valueZatoshis,
      ),
      ironwoodInputZatoshis: request.ironwoodSpends.fold<int>(
        0,
        (sum, spend) => sum + spend.valueZatoshis,
      ),
      ironwoodChangeZatoshis: request.ironwoodChangeZatoshis ?? 0,
      nonIronwoodOutputZatoshis: nonIronwood,
      ironwoodOutputZatoshis:
          request.ironwoodOutput.valueZatoshis! + additionalIronwood,
      rng: 'system',
    );
  }
}

class _ParameterSource implements SaplingParameterSource {
  const _ParameterSource(this.bytes);

  final Map<String, List<int>> bytes;

  @override
  Stream<List<int>> open(SaplingParameterArtifact artifact) =>
      Stream.value(bytes[artifact.fileName]!);
}

ZcashScanResult _scan() => ZcashScanResult(
  scannedBlocks: 1,
  discoveredNotes: 1,
  totalValue: 100000,
  notes: [
    ZcashScannedNote(
      height: 200,
      tx: 'aa' * 32,
      output: 0,
      value: 100000,
      pool: 'ironwood',
      nullifier: 'bb' * 32,
      commitmentPosition: 0,
      recipient: 'uregtest1change',
      rseed: '11' * 32,
      rho: '22' * 32,
      noteVersion: 'v3',
      witness: '33' * 40,
    ),
  ],
  ironwoodAnchor: _anchor,
);

ZcashScanResult _saplingScan() => ZcashScanResult(
  scannedBlocks: 1,
  discoveredNotes: 1,
  totalValue: 100000,
  notes: [
    ZcashScannedNote(
      height: 200,
      tx: 'dd' * 32,
      output: 0,
      value: 100000,
      pool: 'sapling',
      nullifier: 'ee' * 32,
      commitmentPosition: 0,
      recipient: 'zregtest-wallet-note',
      rseed: '11' * 32,
      witness: '33' * 40,
    ),
  ],
  saplingAnchor: 'aa' * 32,
  ironwoodAnchor: _anchor,
);

ZcashAddressMetadata _metadata(ZcashAddressReceiverType type) =>
    ZcashAddressMetadata(
      network: ZcashAddressNetwork.regtest,
      receiverType: type,
      pool: type == ZcashAddressReceiverType.sapling
          ? ZcashAddressPool.sapling
          : ZcashAddressPool.transparent,
      receivers: ZcashAddressReceiverPresence(
        sprout: false,
        orchard: false,
        sapling: type == ZcashAddressReceiverType.sapling,
        transparent: type == ZcashAddressReceiverType.p2pkh,
        transparentKind: type == ZcashAddressReceiverType.p2pkh
            ? 'p2pkh'
            : null,
        unknown: 0,
        total: 1,
      ),
    );

ProposalOutput _directOutput(
  String address,
  ZcashAddressReceiverType receiver,
) => resolveProposalOutput(
  recipient: ProposalRecipient(address: address, amountZatoshis: 50000),
  address: _metadata(receiver),
  network: ZcashAddressNetwork.regtest,
  targetHeight: 301,
  transactionExpiryHeight: 340,
  currentUnixTime: 1000,
);

void main() {
  test(
    'executes Sapling source to resolved Ironwood with Sapling change',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'zcash-sapling-path-b-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final spend = utf8.encode('spend fixture');
      final outputBytes = utf8.encode('output fixture');
      final manifest = SaplingParameterManifest(
        version: 'path-b-test-v1',
        spend: SaplingParameterArtifact(
          fileName: 'sapling-spend.params',
          expectedBytes: spend.length,
          sha256Hex: sha256.convert(spend).toString(),
        ),
        output: SaplingParameterArtifact(
          fileName: 'sapling-output.params',
          expectedBytes: outputBytes.length,
          sha256Hex: sha256.convert(outputBytes).toString(),
        ),
      );
      final parameters =
          await SaplingProvingParameterCache(
            cacheRoot: temp,
            manifest: manifest,
          ).resolve(
            source: _ParameterSource({
              manifest.spend.fileName: spend,
              manifest.output.fileName: outputBytes,
            }),
          );
      const encoded = 'uregtest1-exact-sapling-funded-recipient';
      final routed = resolveProposalOutput(
        recipient: ProposalRecipient(address: encoded, amountZatoshis: 50000),
        address: const ZcashAddressMetadata(
          network: ZcashAddressNetwork.regtest,
          receiverType: ZcashAddressReceiverType.unified,
          pool: ZcashAddressPool.orchard,
          receivers: ZcashAddressReceiverPresence(
            sprout: false,
            orchard: true,
            sapling: false,
            transparent: false,
            unknown: 0,
            total: 1,
          ),
        ),
        unifiedReceivers: const ZcashUnifiedAddressReceiverInventory(
          network: ZcashAddressNetwork.regtest,
          receivers: [
            ZcashUnifiedAddressReceiver(
              index: 0,
              kind: ZcashAddressReceiverType.orchard,
              pool: ZcashAddressPool.orchard,
            ),
          ],
          counts: ZcashUnifiedAddressReceiverCounts(
            orchard: 1,
            sapling: 0,
            transparent: 0,
            p2pkh: 0,
            p2sh: 0,
            unknown: 0,
            total: 1,
          ),
        ),
        network: ZcashAddressNetwork.regtest,
        targetHeight: 301,
        transactionExpiryHeight: 340,
        currentUnixTime: 1000,
      );
      final backend = _Backend();

      final prepared = prepareNativeSaplingPayment(
        scan: _saplingScan(),
        output: routed,
        saplingChangeAddress: 'zregtest-wallet-change',
        targetHeight: 301,
        expiryHeight: 340,
        network: ZcashNetwork.regtest,
        provingParameters: parameters,
        backend: backend,
      );

      expect(routed.encodedAddress, encoded);
      expect(routed.receiverAddress, encoded);
      expect(routed.selectedReceiver, ZcashAddressReceiverType.orchard);
      expect(routed.actualOutputPool, ProposalOutputPool.ironwood);
      expect(backend.quotes, isNotEmpty);
      expect(backend.builds.single.saplingSpends, hasLength(1));
      expect(backend.builds.single.ironwoodSpends, isEmpty);
      expect(backend.builds.single.ironwoodOutput.address, encoded);
      expect(backend.builds.single.ironwoodOutput.valueZatoshis, 50000);
      expect(
        backend.builds.single.outputs.single.address,
        'zregtest-wallet-change',
      );
      expect(backend.builds.single.outputs.single.valueZatoshis, 40000);
      expect(backend.builds.single.provingParameters, same(parameters));
      expect(prepared.transaction.saplingOutputs, 2);
      expect(prepared.plan.feeZatoshis, prepared.transaction.feeZatoshis);
      expect(
        prepared.plan.inputZatoshis,
        prepared.plan.amountZatoshis +
            prepared.plan.feeZatoshis +
            prepared.plan.changeZatoshis,
      );

      final pending = IronwoodPendingSendState()
        ..addPreparedSaplingPayment(prepared, createdHeight: 300);
      final restoredPending = IronwoodPendingSendState.fromJson(
        (jsonDecode(jsonEncode(pending.toJson())) as Map)
            .cast<String, Object?>(),
      );
      expect(restoredPending.reservedSaplingNullifiersAt(301), {'ee' * 32});
      expect(
        restoredPending.requireBroadcastableSaplingPayment(prepared),
        isA<IronwoodPendingSendRecord>(),
      );

      expect(
        () => prepareNativeSaplingPayment(
          scan: _saplingScan(),
          output: routed,
          saplingChangeAddress: 'zregtest-wallet-change',
          targetHeight: 301,
          expiryHeight: 340,
          network: ZcashNetwork.regtest,
          provingParameters: parameters,
          reservations: restoredPending,
          backend: _Backend(),
        ),
        throwsA(
          isA<SaplingSendException>().having(
            (error) => error.refusal,
            'refusal',
            SaplingSendRefusal.notesInFlight,
          ),
        ),
      );
    },
  );

  test('executes an Orchard UA receiver as an actual Ironwood output', () {
    const encoded = 'uregtest1-exact-user-address';
    final output = resolveProposalOutput(
      recipient: ProposalRecipient(address: encoded, amountZatoshis: 50000),
      address: const ZcashAddressMetadata(
        network: ZcashAddressNetwork.regtest,
        receiverType: ZcashAddressReceiverType.unified,
        pool: ZcashAddressPool.orchard,
        receivers: ZcashAddressReceiverPresence(
          sprout: false,
          orchard: true,
          sapling: false,
          transparent: false,
          unknown: 0,
          total: 1,
        ),
      ),
      unifiedReceivers: const ZcashUnifiedAddressReceiverInventory(
        network: ZcashAddressNetwork.regtest,
        receivers: [
          ZcashUnifiedAddressReceiver(
            index: 0,
            kind: ZcashAddressReceiverType.orchard,
            pool: ZcashAddressPool.orchard,
          ),
        ],
        counts: ZcashUnifiedAddressReceiverCounts(
          orchard: 1,
          sapling: 0,
          transparent: 0,
          p2pkh: 0,
          p2sh: 0,
          unknown: 0,
          total: 1,
        ),
      ),
      network: ZcashAddressNetwork.regtest,
      targetHeight: 301,
      transactionExpiryHeight: 340,
      currentUnixTime: 1000,
    );
    final backend = _Backend();
    final prepared = prepareNativeIronwoodPayment(
      scan: _scan(),
      output: output,
      ironwoodChangeAddress: 'unused-for-Ironwood-destination',
      targetHeight: 301,
      expiryHeight: 340,
      network: ZcashNetwork.regtest,
      backend: backend,
    );

    expect(output.encodedAddress, encoded);
    expect(output.receiverAddress, encoded);
    expect(output.selectedReceiver, ZcashAddressReceiverType.orchard);
    expect(output.actualOutputPool, ProposalOutputPool.ironwood);
    expect(backend.builds.single.outputs, isEmpty);
    expect(backend.builds.single.ironwoodOutput.address, encoded);
    expect(backend.builds.single.ironwoodOutput.valueZatoshis, 50000);
    expect(backend.builds.single.ironwoodChangeZatoshis, 40000);
    expect(
      prepared.plan.inputZatoshis,
      prepared.plan.amountZatoshis +
          prepared.plan.feeZatoshis +
          prepared.plan.changeZatoshis,
    );
  });

  test('selects notes once for a mixed multi-recipient payment', () async {
    final temp = await Directory.systemTemp.createTemp('zcash-multi-payment-');
    addTearDown(() => temp.delete(recursive: true));
    final spend = utf8.encode('spend fixture');
    final outputBytes = utf8.encode('output fixture');
    final manifest = SaplingParameterManifest(
      version: 'multi-payment-test-v1',
      spend: SaplingParameterArtifact(
        fileName: 'sapling-spend.params',
        expectedBytes: spend.length,
        sha256Hex: sha256.convert(spend).toString(),
      ),
      output: SaplingParameterArtifact(
        fileName: 'sapling-output.params',
        expectedBytes: outputBytes.length,
        sha256Hex: sha256.convert(outputBytes).toString(),
      ),
    );
    final parameters =
        await SaplingProvingParameterCache(
          cacheRoot: temp,
          manifest: manifest,
        ).resolve(
          source: _ParameterSource({
            manifest.spend.fileName: spend,
            manifest.output.fileName: outputBytes,
          }),
        );
    const encoded = 'uregtest1-multi-ironwood-recipient';
    final ironwood = resolveProposalOutput(
      recipient: ProposalRecipient(address: encoded, amountZatoshis: 30000),
      address: const ZcashAddressMetadata(
        network: ZcashAddressNetwork.regtest,
        receiverType: ZcashAddressReceiverType.unified,
        pool: ZcashAddressPool.orchard,
        receivers: ZcashAddressReceiverPresence(
          sprout: false,
          orchard: true,
          sapling: false,
          transparent: false,
          unknown: 0,
          total: 1,
        ),
      ),
      unifiedReceivers: const ZcashUnifiedAddressReceiverInventory(
        network: ZcashAddressNetwork.regtest,
        receivers: [
          ZcashUnifiedAddressReceiver(
            index: 0,
            kind: ZcashAddressReceiverType.orchard,
            pool: ZcashAddressPool.orchard,
          ),
        ],
        counts: ZcashUnifiedAddressReceiverCounts(
          orchard: 1,
          sapling: 0,
          transparent: 0,
          p2pkh: 0,
          p2sh: 0,
          unknown: 0,
          total: 1,
        ),
      ),
      network: ZcashAddressNetwork.regtest,
      targetHeight: 301,
      transactionExpiryHeight: 340,
      currentUnixTime: 1000,
    );
    final transparent = resolveProposalOutput(
      recipient: ProposalRecipient(
        address: 'tmMultiTransparentReceiver',
        amountZatoshis: 20000,
      ),
      address: _metadata(ZcashAddressReceiverType.p2pkh),
      network: ZcashAddressNetwork.regtest,
      targetHeight: 301,
      transactionExpiryHeight: 340,
      currentUnixTime: 1000,
    );
    final sapling = resolveProposalOutput(
      recipient: ProposalRecipient(
        address: 'zregtestMultiSaplingReceiver',
        amountZatoshis: 10000,
        memo: Uint8List.fromList([4, 5]),
      ),
      address: _metadata(ZcashAddressReceiverType.sapling),
      network: ZcashAddressNetwork.regtest,
      targetHeight: 301,
      transactionExpiryHeight: 340,
      currentUnixTime: 1000,
    );
    final repeatedIronwood = resolveProposalOutput(
      recipient: ProposalRecipient(
        address: encoded,
        amountZatoshis: 20000,
        memo: Uint8List.fromList([1, 2, 3]),
      ),
      address: const ZcashAddressMetadata(
        network: ZcashAddressNetwork.regtest,
        receiverType: ZcashAddressReceiverType.unified,
        pool: ZcashAddressPool.orchard,
        receivers: ZcashAddressReceiverPresence(
          sprout: false,
          orchard: true,
          sapling: false,
          transparent: false,
          unknown: 0,
          total: 1,
        ),
      ),
      unifiedReceivers: const ZcashUnifiedAddressReceiverInventory(
        network: ZcashAddressNetwork.regtest,
        receivers: [
          ZcashUnifiedAddressReceiver(
            index: 0,
            kind: ZcashAddressReceiverType.orchard,
            pool: ZcashAddressPool.orchard,
          ),
        ],
        counts: ZcashUnifiedAddressReceiverCounts(
          orchard: 1,
          sapling: 0,
          transparent: 0,
          p2pkh: 0,
          p2sh: 0,
          unknown: 0,
          total: 1,
        ),
      ),
      network: ZcashAddressNetwork.regtest,
      targetHeight: 301,
      transactionExpiryHeight: 340,
      currentUnixTime: 1000,
    );
    final backend = _Backend();

    final prepared = prepareNativeIronwoodPayments(
      scan: _scan(),
      outputs: [ironwood, repeatedIronwood, sapling, transparent],
      ironwoodChangeAddress: 'uregtest1-wallet-change',
      targetHeight: 301,
      expiryHeight: 340,
      network: ZcashNetwork.regtest,
      provingParameters: parameters,
      backend: backend,
    );

    expect(prepared.plan.outputs, [
      ironwood,
      repeatedIronwood,
      sapling,
      transparent,
    ]);
    expect(prepared.plan.amountZatoshis, 80000);
    expect(prepared.plan.inputZatoshis, 100000);
    expect(prepared.plan.feeZatoshis, 10000);
    expect(prepared.plan.changeZatoshis, 10000);
    expect(backend.builds, hasLength(1));
    expect(backend.builds.single.outputs.map((output) => output.address), [
      sapling.receiverAddress,
      transparent.receiverAddress,
    ]);
    expect(
      backend.builds.single.ironwoodOutput.address,
      ironwood.receiverAddress,
    );
    expect(
      backend.builds.single.additionalIronwoodOutputs.single.address,
      encoded,
    );
    expect(
      backend.builds.single.additionalIronwoodOutputs.single.memoHex,
      '010203',
    );
    expect(backend.builds.single.outputs.first.memoHex, '0405');
    expect(backend.builds.single.ironwoodChangeZatoshis, 10000);
  });

  for (final destination in [
    (
      name: 'transparent',
      address: 'tmExactTransparentReceiver',
      receiver: ZcashAddressReceiverType.p2pkh,
      pool: ProposalOutputPool.transparent,
    ),
    (
      name: 'Sapling',
      address: 'zregtestExactSaplingReceiver',
      receiver: ZcashAddressReceiverType.sapling,
      pool: ProposalOutputPool.sapling,
    ),
  ]) {
    test('executes Ironwood to ${destination.name} with Ironwood change', () {
      final backend = _Backend();
      final output = _directOutput(destination.address, destination.receiver);
      final prepared = prepareNativeIronwoodPayment(
        scan: _scan(),
        output: output,
        ironwoodChangeAddress: 'uregtest1-wallet-change',
        targetHeight: 301,
        expiryHeight: 340,
        network: ZcashNetwork.regtest,
        backend: backend,
      );

      expect(output.encodedAddress, destination.address);
      expect(output.receiverAddress, destination.address);
      expect(output.selectedReceiver, destination.receiver);
      expect(output.actualOutputPool, destination.pool);
      expect(backend.quotes, isNotEmpty);
      expect(backend.builds.single.outputs.single.address, destination.address);
      expect(backend.builds.single.outputs.single.valueZatoshis, 50000);
      expect(
        backend.builds.single.ironwoodOutput.address,
        'uregtest1-wallet-change',
      );
      expect(backend.builds.single.ironwoodOutput.valueZatoshis, 40000);
      expect(
        prepared.plan.inputZatoshis,
        prepared.plan.amountZatoshis +
            prepared.plan.feeZatoshis +
            prepared.plan.changeZatoshis,
      );
    });
  }

  test('passes one resolved parameter pair through quote and build', () async {
    final temp = await Directory.systemTemp.createTemp('zcash-builder-params-');
    addTearDown(() => temp.delete(recursive: true));
    final spend = utf8.encode('spend fixture');
    final outputBytes = utf8.encode('output fixture');
    final manifest = SaplingParameterManifest(
      version: 'builder-test-v1',
      spend: SaplingParameterArtifact(
        fileName: 'sapling-spend.params',
        expectedBytes: spend.length,
        sha256Hex: sha256.convert(spend).toString(),
      ),
      output: SaplingParameterArtifact(
        fileName: 'sapling-output.params',
        expectedBytes: outputBytes.length,
        sha256Hex: sha256.convert(outputBytes).toString(),
      ),
    );
    final parameters =
        await SaplingProvingParameterCache(
          cacheRoot: temp,
          manifest: manifest,
        ).resolve(
          source: _ParameterSource({
            manifest.spend.fileName: spend,
            manifest.output.fileName: outputBytes,
          }),
        );
    final backend = _Backend();

    prepareNativeIronwoodPayment(
      scan: _scan(),
      output: _directOutput(
        'zregtestExactSaplingReceiver',
        ZcashAddressReceiverType.sapling,
      ),
      ironwoodChangeAddress: 'uregtest1-wallet-change',
      targetHeight: 301,
      expiryHeight: 340,
      network: ZcashNetwork.regtest,
      provingParameters: parameters,
      backend: backend,
    );

    for (final request in [...backend.quotes, ...backend.builds]) {
      expect(request.provingParameters, same(parameters));
      expect(
        request.provingParameters!.spendParamsPath,
        parameters.spendParamsPath,
      );
      expect(
        request.provingParameters!.outputParamsPath,
        parameters.outputParamsPath,
      );
    }
  });
}
