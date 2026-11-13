## Unreleased

- Build host, Android and iOS native assets with a validated production-wallet
  Cargo feature profile, and expose a runtime capability assertion for apps.
- Allow `code_assets` 1.2.1 through 2.x so applications can resolve
  `zcash_flutter` alongside native packages that have not moved to 2.x. The
  build hook only uses APIs available in 1.2.1.

## 0.0.3

- Moved the build hook dependencies to `hooks: ^2.2.0` and
  `code_assets: ^2.0.0` (from `^1.0.2` and `^1.0.0`). An app can now depend on
  this package together with `tract_flutter`, whose `tract` dependency needs
  `hooks` 2; with 0.0.2 pub could not resolve the two together. The build hook
  in `hook/build.dart` needed no source change.

## 0.0.2

- Removed the `zcash_tool` executable. It continues as the unpublished
  `zcash_cli` package in the repository.
- Added the Flutter example app and device check under `example/`.

## 0.0.1

First release, continuing the unpublished `zcash_ffi` package under its new
name.

- `dart:ffi` bindings to the bundled `zcash-ffi` crate: BIP 39 mnemonics, key
  derivation, address parsing, mining helpers, compact-block scanning, note
  memos and compiled-capability reporting.
- Transparent, Sapling, Orchard and Ironwood transaction building, shielding
  and broadcast behind the crate's feature flags.
- Native wallet sync from lightwalletd.
- A build hook that compiles the crate with cargo as a code asset for the
  host, Android and iOS. `ZCASH_FFI_MANIFEST_DIR` overrides the crate,
  `ZCASH_FFI_CARGO_PROFILE` selects `release` or `debug`, and `ZCASH_FFI_LIB`
  overrides the library at runtime.
- The `zcash_tool` CLI.
