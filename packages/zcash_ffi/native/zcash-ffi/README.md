# zcash-ffi

C ABI over the librustzcash crates, used by `zcash_ffi`. Most exports return
a JSON string (`{"ffi_result_version":1,"status":"ok"|"error",...}`); the
caller frees every returned string with `zcash_ffi_free_string`.
`tests/abi_surface.rs` lists the exported symbols.

Features:

| Feature | Default | Enables |
|---|---|---|
| `ironwood-note-discovery` | yes | Ironwood notes in compact-block scans |
| `ironwood-tx-build` | yes | `zcash_ffi_build_ironwood_transaction` |
| `orchard-note-discovery` | no | Orchard notes in compact-block scans |
| `transparent-tx-build` | no | `zcash_ffi_build_transparent_transaction` |
| `sapling-spend-build` | no | `zcash_ffi_build_sapling_transaction`, Sapling witnesses |
| `orchard-tx-build` | no | `zcash_ffi_build_orchard_transaction` (before NU6.3 only) |
| `deterministic-build-rng` | no | accepts `rng_seed` in build requests (tests only) |
Minimum Rust version: 1.89.
