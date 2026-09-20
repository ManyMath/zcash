import 'dart:math';

import 'package:zcash_ffi/zcash_ffi.dart';

class DeviceCheck {
  DeviceCheck({this.lightwalletd, this.syncBlocks = 200});

  final String? lightwalletd;
  final int syncBlocks;

  String nativeVersion() => ZcashFfiBindings.instance.version();

  NativeCapabilitySnapshot capabilities() =>
      nativeCapabilities(bindings: ZcashFfiBindings.instance);

  String freshMainnetUfvk() {
    final seedHex = List<int>.generate(
      32,
      (_) => Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return deriveNativeAccountMetadata(
      seedHex: seedHex,
      network: ZcashNetwork.mainnet,
    ).ufvk;
  }

  Future<SyncMeasurement> mainnetSync() async {
    final server = lightwalletd!;
    final separator = server.lastIndexOf(':');
    final client = LightwalletdClient(
      host: server.substring(0, separator),
      port: int.parse(server.substring(separator + 1)),
    );
    try {
      final tip = await client.getTipHeight();
      final birthday = tip - syncBlocks + 1;
      final wallet = ZcashWalletSyncState.atBirthday(
        cursor: ZcashLightwalletdSyncCursor.fromTreeState(
          treeStateFromLightwalletd(
            await client.getTreeStateAtHeight(birthday - 1),
          ),
        ),
        accountFingerprint: 'device-check',
      );
      final watch = Stopwatch()..start();
      final outcome = await openNativeLightwalletdSync(
        client: client,
        wallet: wallet,
        ufvk: freshMainnetUfvk(),
        network: ZcashNetwork.mainnet,
      ).syncToTip();
      watch.stop();
      return SyncMeasurement(
        caughtUp: outcome is ZcashSyncCaughtUp,
        blocks: wallet.cursor.nextHeight - birthday,
        elapsed: watch.elapsed,
      );
    } finally {
      await client.close();
    }
  }
}

class SyncMeasurement {
  const SyncMeasurement({
    required this.caughtUp,
    required this.blocks,
    required this.elapsed,
  });

  final bool caughtUp;
  final int blocks;
  final Duration elapsed;

  double get blocksPerSecond => blocks / (elapsed.inMilliseconds / 1000);

  @override
  String toString() =>
      '$blocks blocks in ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s '
      '(${blocksPerSecond.toStringAsFixed(0)} blocks/s)';
}
