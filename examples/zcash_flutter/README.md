# zcash_flutter_example

A Flutter app over `zcash_ffi` and a device check: the library loads from the
package's code asset, reports its capabilities, derives a UFVK and, with
`MAINNET_LIGHTWALLETD`, syncs 200 mainnet blocks.

```sh
flutter test integration_test -d <device> \
  --dart-define=MAINNET_LIGHTWALLETD=zec.rocks:443
```

Runs on Android and the iOS Simulator. The iOS device build
(`flutter build ios --no-codesign`) has not been run on a phone.
