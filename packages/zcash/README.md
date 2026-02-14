# zcash

Dart clients for the [Zebra](https://github.com/ZcashFoundation/zebra) 3.0
JSON-RPC API and the [lightwalletd](https://github.com/zcash/lightwalletd) gRPC
API.

```dart
final zebra = ZebraClient(); // localhost:8232
final chain = await zebra.getBlockchainInfo();
print('${chain.chain} at ${chain.blocks}');
zebra.close();

final lwd = LightwalletdClient(host: 'mainnet.lightwalletd.com', port: 9067);
print((await lwd.getLatestBlock()).height);
await lwd.close();
```

Zebra serves RPC once `listen_addr` is set under `[rpc]` in `zebra.toml`.
`example/zcash_example.dart` takes an optional host and port.

The protos in `proto/` come from
[zcash/lightwallet-protocol](https://github.com/zcash/lightwallet-protocol).
To regenerate `lib/src/grpc/`:

```sh
protoc --dart_out=grpc:lib/src/grpc/ --proto_path=proto/ \
  proto/compact_formats.proto proto/service.proto
```

`LIGHTWALLETD_INTEGRATION=1 LIGHTWALLETD_ADDR=localhost:9067 dart test` adds
the live lightwalletd tests.
