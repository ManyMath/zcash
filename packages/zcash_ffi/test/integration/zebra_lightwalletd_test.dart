@TestOn('vm')
library;

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

import 'harness.dart';
import 'lightwalletd_harness.dart';

void main() {
  final live =
      Platform.environment.containsKey('ZEBRA_INTEGRATION') &&
      Platform.environment.containsKey('LIGHTWALLETD_INTEGRATION');
  ZebraHarness? zebra;
  LightwalletdHarness? lightwalletd;

  setUpAll(() async {
    if (!live) return;
    zebra = await ZebraHarness.start();
    lightwalletd = await LightwalletdHarness.start(
      backend: LightwalletdBackend.zebra(rpcPort: zebra!.rpcPort),
    );
  });

  tearDownAll(() async {
    final lwd = lightwalletd;
    lightwalletd = null;
    if (lwd != null) await lwd.shutdown();
    final z = zebra;
    zebra = null;
    if (z != null) await z.shutdown();
  });

  test('skips live Zebra/lightwalletd work unless explicitly enabled', () {
    if (live) return;
    expect(zebra, isNull);
    expect(lightwalletd, isNull);
  });

  test('redacts RPC credentials from diagnostics', () {
    final redacted = LightwalletdHarness.redactForDiagnostics(
      'rpcuser=alice rpcpassword=super-secret-token-1234567890 '
      '--rpcpassword another-secret-token-1234567890 '
      'Authorization: Basic dXNlcjpzZWNyZXQ=',
    );

    expect(redacted, isNot(contains('alice')));
    expect(redacted, isNot(contains('super-secret')));
    expect(redacted, isNot(contains('another-secret')));
    expect(redacted, isNot(contains('dXNlcjpzZWNyZXQ')));
    expect(redacted, contains('rpcpassword=<redacted>'));
    expect(redacted, contains('Authorization: Basic <redacted>'));
  });

  test('reads Zebra compact blocks through managed lightwalletd', () async {
    if (!live) return;
    final z = zebra!;
    final lwd = lightwalletd!;

    final before = await z.client.getBlockCount();
    final mining = await _tryMineBlocks(z, 3);
    final backendHeight = await z.client.getBlockCount();
    if (mining.mined) {
      expect(backendHeight, equals(before + 3));
    } else {
      expect(backendHeight, equals(before));
    }

    try {
      final synced = await lwd.waitForSyncHeight(
        backendHeight,
        readBackendHeight: z.client.getBlockCount,
      );
      expect(synced.backendHeight, greaterThanOrEqualTo(backendHeight));
      expect(synced.lightwalletdHeight, greaterThanOrEqualTo(backendHeight));

      final info = await lwd.client.getInfo();
      expect(info.version, isNotEmpty);
      expect(info.blockHeight.toInt(), greaterThanOrEqualTo(backendHeight));

      final latest = await lwd.client.getLatestBlock();
      expect(latest.height.toInt(), greaterThanOrEqualTo(backendHeight));

      final startHeight = mining.mined ? backendHeight - 2 : backendHeight;
      final range = BlockRange()
        ..start = (BlockID()..height = Int64(startHeight))
        ..end = (BlockID()..height = Int64(backendHeight));
      final blocks = await lwd.fetchCompactBlockRange(range).toList();
      expect(blocks, hasLength(backendHeight - startHeight + 1));
      expect(blocks.first.height.toInt(), equals(startHeight));
      expect(blocks.last.height.toInt(), equals(backendHeight));
    } on Object catch (error) {
      fail(
        'Zebra lightwalletd compact-block proof failed; '
        'backendHeight=$backendHeight zebraRpcPort=${z.rpcPort} '
        'lightwalletdGrpcPort=${lwd.grpcPort} mining=${mining.status} '
        'error=$error\n'
        '${lwd.diagnosticSummary(phase: 'compact-block-proof')}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

class _MiningAttempt {
  final bool mined;
  final String status;

  const _MiningAttempt._(this.mined, this.status);

  factory _MiningAttempt.mined(int count) =>
      _MiningAttempt._(true, 'mined:$count');

  factory _MiningAttempt.skipped(String reason) =>
      _MiningAttempt._(false, 'skipped:$reason');
}

Future<_MiningAttempt> _tryMineBlocks(ZebraHarness harness, int count) async {
  try {
    await harness.mineBlocks(count);
    return _MiningAttempt.mined(count);
  } on Object catch (error) {
    final text = error.toString();
    if (text.contains('libzcash_ffi') || text.contains('ZCASH_FFI_LIB')) {
      return _MiningAttempt.skipped('missing-ffi-library');
    }
    rethrow;
  }
}
