# zcash

Dart packages for Zcash wallets, backed by a Rust FFI crate.

- `packages/zcash`: pure Dart models, node clients (Zebra, zcashd,
  lightwalletd) and the generated lightwalletd protobuf types.
- `packages/zcash_ffi`: `dart:ffi` bindings, build hooks and the `zcash_tool`
  CLI over `packages/zcash_ffi/native/zcash-ffi`.
- `examples/zcash_flutter`: a Flutter app and device check.

## Build and test

```sh
dart pub get
dart run melos bootstrap
dart run melos run analyze
dart run melos run test

cd packages/zcash_ffi/native/zcash-ffi
cargo test --release                 # default features
cargo test --release --all-features
cargo clippy --all-targets --all-features
```
## Live suites

The suites in `packages/zcash_ffi/test/integration` skip unless enabled. They
run a regtest chain from local binaries:

```sh
export ZEBRA_INTEGRATION=1 LIGHTWALLETD_INTEGRATION=1
export ZEBRA_BIN=/path/to/zebrad              # zebrad 6.2.2
export LIGHTWALLETD_BIN=/path/to/lightwalletd # lightwalletd 0.5.2
export ZCASH_FFI_LIB=/path/to/libzcash_ffi.dylib
export ZCASH_SAPLING_SPEND_PARAMS=/path/to/sapling-spend.params
export ZCASH_SAPLING_OUTPUT_PARAMS=/path/to/sapling-output.params
cd packages/zcash_ffi && dart test -j 1 test/integration/zebra_ironwood_live_test.dart
```

Build `ZCASH_FFI_LIB` with
`cargo build --release --features "orchard-tx-build orchard-note-discovery sapling-spend-build"`.
The Sapling parameters are the concatenated `sapling-spend-{1..5}.params` from
the `wagyu-zcash-parameters-{1..5}` crates (sha256 `8e48ffd2…c13`) and
`sapling-output-1.params` from `wagyu-zcash-parameters-6` (sha256 `2f0ebbcb…0e4`).
