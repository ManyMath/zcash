import 'package:zcash_ffi/zcash_ffi.dart';

// Bytes 0x00..0x3f: a deterministic dev seed, not a published vector.
const _testSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';

Future<void> main() async {
  final t = await deriveTransparentAddress(
    seedHex: _testSeedHex,
    network: ZcashNetwork.regtest,
    accountIndex: 0,
    childIndex: 0,
  );
  print(t);
}
