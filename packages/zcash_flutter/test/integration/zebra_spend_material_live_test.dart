@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

import 'harness.dart';
import 'lightwalletd_harness.dart';

const _seedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const _accountFingerprint = 'spend-material-live-account-0';

void main() {
  const nu63Activation = 130;
  final ffiPath = Platform.environment['ZCASH_FFI_LIB'] ?? '';
  final enabled =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
      Platform.environment.containsKey('LIGHTWALLETD_INTEGRATION') &&
      ffiPath.isNotEmpty;

  test(
    'sync → serialize → restore → acquire → build → broadcast → mine → observe',
    () async {
      final ffi = ZcashFfiBindings.open(ffiPath);
      requireProductionWalletNativeCapabilities(
        nativeCapabilities(bindings: ffi),
      );
      ZebraHarness? zebra;
      LightwalletdHarness? lightwalletd;
      try {
        zebra = await ZebraHarness.start(
          nu63ActivationHeight: nu63Activation,
          minerAddress: kIronwoodProofMinerAddress,
        );
        await zebra.mineBlocks(101);
        await _mineTo(zebra, nu63Activation + 2);
        lightwalletd = await LightwalletdHarness.start(
          backend: LightwalletdBackend.zebra(rpcPort: zebra.rpcPort),
        );

        final metadata = deriveNativeAccountMetadata(
          seedHex: _seedHex,
          network: ZcashNetwork.regtest,
          bindings: ffi,
        );
        final tipBeforeShield = await zebra.client.getBlockCount();
        final shielding = prepareNativeShieldingSend(
          network: ZcashNetwork.regtest,
          destination: ShieldingDestination.ironwood,
          coins: await _oneMatureCoin(zebra, tipBeforeShield),
          toAddress: kIronwoodProofUnifiedAddress,
          targetHeight: tipBeforeShield + 1,
          signingKeyForCoin: (_) => kIronwoodProofMinerSecretKeyHex,
          ironwoodAnchor: IronwoodAnchorSource.tree(
            (await zebra.client.getTreeState(
                  '$tipBeforeShield',
                )).ironwood?.finalState ??
                '',
          ),
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalBuild: true,
          bindings: ffi,
        );
        await zebra.client.sendRawTransaction(shielding.transactionHex);
        await zebra.mineBlocks(1);
        final shieldHeight = await zebra.client.getBlockCount();
        await lightwalletd.waitForSyncHeight(
          shieldHeight,
          readBackendHeight: zebra.client.getBlockCount,
        );

        final prior = await zebra.client.getTreeState('${shieldHeight - 1}');
        final wallet = ZcashWalletSyncState.atBirthday(
          cursor: ZcashLightwalletdSyncCursor.fromTreeState(prior),
          accountFingerprint: _accountFingerprint,
        );
        await openNativeLightwalletdSync(
          client: lightwalletd.client,
          wallet: wallet,
          ufvk: metadata.ufvk,
          network: ZcashNetwork.regtest,
          bindings: ffi,
        ).syncToTip();
        expect(wallet.ironwood.notes, hasLength(1));
        expect(wallet.ironwood.notes.single.witness, isNull);

        final restored = ZcashWalletSyncState.fromJson(
          (jsonDecode(jsonEncode(wallet.toJson())) as Map)
              .cast<String, Object?>(),
        );
        final anchorHeight = await zebra.client.getBlockCount();
        final request = ZcashSpendMaterialRequest.ironwood(
          accountFingerprint: restored.accountFingerprint,
          notes: restored.ironwood.notes,
          anchorHeight: anchorHeight,
        );
        final source = NativeLightwalletdSpendMaterialSource(
          client: lightwalletd.client,
          ufvk: metadata.ufvk,
          network: ZcashNetwork.regtest,
          bindings: ffi,
        );
        final material = await acquireNativeSpendMaterial(
          wallet: restored,
          request: request,
          source: source,
        );

        final note = material.notes.single;
        final prepared = prepareNativeIronwoodSend(
          network: ZcashNetwork.regtest,
          scan: material.scan,
          toAddress: kIronwoodProofUnifiedAddress,
          amountZatoshis: note.value ~/ 2,
          targetHeight: anchorHeight + 1,
          seedHex: _seedHex,
          regtestNu63ActivationHeight: nu63Activation,
          allowExperimentalIronwoodBuild: true,
          bindings: ffi,
        );
        restored.pendingIronwoodSends.addPrepared(
          prepared,
          actualDestinationPool: IronwoodDestinationPool.ironwood,
          createdHeight: anchorHeight,
        );
        final durableBeforeBroadcast = ZcashWalletSyncState.fromJson(
          (jsonDecode(jsonEncode(restored.toJson())) as Map)
              .cast<String, Object?>(),
        );
        final receipt = await broadcastIronwoodSend(
          send: prepared,
          pendingSends: durableBeforeBroadcast.pendingIronwoodSends,
          chainHeight: anchorHeight,
          submit: zebra.client.sendRawTransaction,
          isRejection: (error) => error is ZebraRpcException,
        );
        final minedHash = (await zebra.mineBlocks(1)).single;
        expect(
          (await zebra.client.getBlock(minedHash)).transactions,
          contains(receipt.txid),
        );

        final spendHeight = await zebra.client.getBlockCount();
        await lightwalletd.waitForSyncHeight(
          spendHeight,
          readBackendHeight: zebra.client.getBlockCount,
        );
        final observationCursor = ZcashLightwalletdSyncCursor.fromTreeState(
          await source.fetchTreeState(anchorHeight),
        );
        final observedRange = await source.fetchRange(
          anchorHeight + 1,
          spendHeight,
        );
        final observation = await source.scan(
          observationCursor.scanInputFor(
            observedRange,
            network: 'regtest',
            watchedNullifiers: ZcashWatchedNullifiers.forPool('ironwood', [
              note.nullifier!,
            ]),
          ),
        );
        expect(receipt.isConfirmedBy(observation), isTrue);
        durableBeforeBroadcast.pendingIronwoodSends.reconcileWithScan(
          scan: observation,
          canonicalBlockHashAt: (height) => height == spendHeight
              ? blockHashFromDisplayedHash(minedHash)
              : null,
          scannedBlockHashAt: (height) {
            for (final block in observedRange.blocks) {
              if (block.height.toInt() == height) {
                return ZcashLightwalletdScanSource([block]).lastBlockHash;
              }
            }
            return null;
          },
        );
        expect(
          durableBeforeBroadcast
              .pendingIronwoodSends
              .records
              .single
              .isConfirmed,
          isTrue,
        );
      } finally {
        await lightwalletd?.shutdown();
        await zebra?.shutdown();
      }
    },
    skip: enabled
        ? false
        : 'needs ZEBRA_INTEGRATION, LIGHTWALLETD_INTEGRATION, ZCASH_FFI_LIB, '
              'an Ironwood-aware ZEBRA_BIN, and LIGHTWALLETD_BIN or a '
              'digest-pinned LIGHTWALLETD_DOCKER_IMAGE',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _mineTo(ZebraHarness zebra, int height) async {
  final current = await zebra.client.getBlockCount();
  if (current < height) await zebra.mineBlocks(height - current);
}

Future<TransparentCoinSet> _oneMatureCoin(
  ZebraHarness zebra,
  int chainHeight,
) async {
  final utxos = await zebra.client.getAddressUtxos([
    kIronwoodProofMinerAddress,
  ]);
  final all = TransparentCoinSet.fromUtxos(
    utxos: utxos,
    chainHeight: chainHeight,
    coinbaseOutpoints: {
      for (final utxo in utxos) '${utxo.txid}:${utxo.outputIndex}',
    },
  );
  final chosen = all.spendable.first.utxo;
  return TransparentCoinSet.fromUtxos(
    utxos: [chosen],
    chainHeight: chainHeight,
    coinbaseOutpoints: {'${chosen.txid}:${chosen.outputIndex}'},
  );
}
