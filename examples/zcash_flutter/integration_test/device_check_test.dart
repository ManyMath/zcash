import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';
import 'package:zcash_flutter_example/device_check.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const server = String.fromEnvironment('MAINNET_LIGHTWALLETD');
  final check = DeviceCheck(lightwalletd: server.isEmpty ? null : server);

  test('the native library loads from the package code asset', () {
    expect(check.nativeVersion(), isNotEmpty);
  });

  test('the shipped build reports Ironwood supported', () {
    final caps = check.capabilities();
    expect(
      caps.statusFor(NativeCapability.ironwoodNoteDiscovery),
      CapabilityStatus.supported,
    );
    expect(
      caps.statusFor(NativeCapability.ironwoodTransactionBuild),
      CapabilityStatus.supported,
    );
  });

  test('a mainnet UFVK derives on the device', () {
    expect(check.freshMainnetUfvk(), startsWith('uview1'));
  });

  test(
    'a fresh wallet syncs mainnet blocks to the tip',
    () async {
      final measured = await check.mainnetSync();
      expect(measured.caughtUp, isTrue);
      expect(measured.blocks, greaterThanOrEqualTo(check.syncBlocks));
      // ignore: avoid_print
      print('device mainnet sync via $server: $measured');
    },
    skip: server.isEmpty ? 'pass --dart-define=MAINNET_LIGHTWALLETD' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
