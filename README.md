# zcash

Dart client for the [Zebra](https://github.com/ZcashFoundation/zebra) 3.0 JSON-RPC API.

```dart
final zebra = ZebraClient(); // localhost:8232
final chain = await zebra.getBlockchainInfo();
print('${chain.chain} at ${chain.blocks}');
zebra.close();
```

Zebra serves RPC once `listen_addr` is set under `[rpc]` in `zebra.toml`.
`example/zcash_example.dart` takes an optional host and port.
