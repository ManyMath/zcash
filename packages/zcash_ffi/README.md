# zcash_ffi

`dart:ffi` bindings over the `zcash-ffi` crate (`native/zcash-ffi`): key
derivation, compact-block scanning, transaction building and lightwalletd sync.
Re-exports `package:zcash`.

The build hook compiles the crate with cargo as a code asset for the host,
Android and iOS, so a Rust toolchain from [rustup](https://rustup.rs) must be
on `PATH`. `ZCASH_FFI_LIB` overrides the library at runtime (for feature
builds), `ZCASH_FFI_MANIFEST_DIR` overrides the crate directory at build time
and `ZCASH_FFI_CARGO_PROFILE` selects `release` (the default) or `debug`.

```sh
dart run zcash_tool capabilities --json
dart run zcash_tool address <addr> --network regtest
dart run zcash_tool derive --network regtest
dart run zcash_tool scan blocks.json --json
```
