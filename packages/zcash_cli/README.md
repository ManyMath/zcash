# zcash_cli

Developer CLI over `zcash_flutter`, kept out of the published package. It
uses a fixed development seed on regtest unless `--seed` is given.

```sh
dart run zcash_cli capabilities --json
dart run zcash_cli address <addr> --network regtest
dart run zcash_cli derive --network regtest
dart run zcash_cli scan blocks.json --json
```

The tests shell out to `dart run zcash_cli`, which builds `zcash_flutter`'s
code asset through its build hook the way a dependent package does.
