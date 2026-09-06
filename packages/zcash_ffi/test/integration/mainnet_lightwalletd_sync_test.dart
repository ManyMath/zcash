@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

// Needs MAINNET_LIGHTWALLETD=<host:port> (TLS, e.g. zec.rocks:443).
// MAINNET_SYNC_BLOCKS, MAINNET_RANGE_SIZE and ZCASH_FFI_LIB are optional.
void main() {
  const nu63MainnetActivation = 3428143;

  final server = Platform.environment['MAINNET_LIGHTWALLETD'] ?? '';
  final blocks =
      int.tryParse(Platform.environment['MAINNET_SYNC_BLOCKS'] ?? '') ?? 1000;
  final rangeSize =
      int.tryParse(Platform.environment['MAINNET_RANGE_SIZE'] ?? '') ?? 100;
  final enabled = server.isNotEmpty;

  LightwalletdClient? client;

  setUpAll(() {
    if (!enabled) return;
    final separator = server.lastIndexOf(':');
    client = LightwalletdClient(
      host: server.substring(0, separator),
      port: int.parse(server.substring(separator + 1)),
    );
  });

  tearDownAll(() async {
    await client?.close();
  });

  test(
    'the served chain is past NU6.3 and the server can see Ironwood',
    () async {
      final tip = await client!.getTipHeight();
      expect(tip, greaterThan(nu63MainnetActivation));

      final block = await client!.getBlockRangeByHeight(tip, tip).single;
      expect(
        block.chainMetadata.ironwoodCommitmentTreeSize,
        greaterThan(0),
        reason:
            'a zero Ironwood tree size on mainnet after activation is a server '
            'that cannot see the pool, answering with a proto3 default',
      );
    },
    skip: enabled ? false : 'set MAINNET_LIGHTWALLETD to run',
  );

  test(
    'a fresh wallet syncs $blocks mainnet blocks to the tip and resumes '
    'where it stopped',
    () async {
      final seed = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      final seedHex = seed
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final ufvk = deriveNativeAccountMetadata(
        seedHex: seedHex,
        network: ZcashNetwork.mainnet,
      ).ufvk;

      final tip = await client!.getTipHeight();
      final birthday = tip - blocks + 1;
      final wallet = ZcashWalletSyncState.atBirthday(
        cursor: ZcashLightwalletdSyncCursor.fromTreeState(
          treeStateFromLightwalletd(
            await client!.getTreeStateAtHeight(birthday - 1),
          ),
        ),
        accountFingerprint: 'mainnet-smoke',
      );

      final ranges = <CompactBlockScanRange>[];
      final timings = ZcashSyncTimings();
      final synced = Stopwatch()..start();
      final outcome = await openNativeLightwalletdSync(
        client: client!,
        wallet: wallet,
        ufvk: ufvk,
        network: ZcashNetwork.mainnet,
        rangeSize: rangeSize,
        timings: timings,
      ).syncToTip(onAdvanced: (advanced) => ranges.add(advanced.range));
      synced.stop();

      expect(outcome, isA<ZcashSyncCaughtUp>());
      expect(ranges.first.start, birthday);
      expect(wallet.cursor.nextHeight, greaterThan(tip));
      expect(wallet.balance().totalZatoshis, 0);

      final restored = ZcashWalletSyncState.fromJson(
        jsonDecode(jsonEncode(wallet.toJson())) as Map<String, Object?>,
      );
      expect(restored.cursor.nextHeight, wallet.cursor.nextHeight);

      final fetched = Stopwatch()..start();
      var servedBlocks = 0;
      for (final range in ranges) {
        servedBlocks += await client!
            .getBlockRangeByHeight(range.start, range.end)
            .length;
      }
      fetched.stop();

      final scannedBlocks = wallet.cursor.nextHeight - birthday;
      expect(servedBlocks, scannedBlocks);
      final seconds = synced.elapsedMilliseconds / 1000;
      final fetchSeconds = fetched.elapsedMilliseconds / 1000;
      print(
        'mainnet sync via $server: $scannedBlocks blocks in '
        '${seconds.toStringAsFixed(1)} s '
        '(${(scannedBlocks / seconds).toStringAsFixed(0)} blocks/s) over '
        '${ranges.length} ranges; re-fetching the same blocks alone took '
        '${fetchSeconds.toStringAsFixed(1)} s, leaving '
        '${(seconds - fetchSeconds).toStringAsFixed(1)} s for checking, '
        'scanning and applying. Inside the sync: $timings',
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: enabled ? false : 'set MAINNET_LIGHTWALLETD to run',
  );
}
