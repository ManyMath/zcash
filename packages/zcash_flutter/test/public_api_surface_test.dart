@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:zcash_flutter/src/ffi/zcash_native_assets.dart';

void main() {
  test('documented zcashNative* wrappers resolve as public symbols', () {
    final surface = <Function>[
      zcashNativeVersion,
      zcashNativeCapabilities,
      zcashNativeDecodeAddress,
      zcashNativeDecodeTransaction,
      zcashNativeTransactionTxid,
      zcashNativeUfvkToAddress,
      zcashNativeUfvkToDiversifierSearch,
      zcashNativeTransparentAddress,
      zcashNativeValidateKey,
      zcashNativeSeedToAccountUfvk,
      zcashNativeSeedToAccountMetadata,
      zcashNativeSeedToViewingKeys,
      zcashNativeSeedToTransparentXpub,
      zcashNativeSeedToSaplingSpendingKey,
      zcashNativeScanCompactBlocks,
      zcashNativeBuildTransparentTransaction,
      zcashNativeBuildSaplingTransaction,
    ];

    expect(surface, hasLength(17));
    expect(
      surface.toSet(),
      hasLength(surface.length),
      reason: 'native wrapper tear-offs should be distinct',
    );
  });
}
