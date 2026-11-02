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
