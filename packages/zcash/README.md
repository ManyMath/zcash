# zcash

Pure Dart Zcash models and node clients: `ZebraClient` (JSON-RPC),
`ZcashdWalletClient` (JSON-RPC) and `LightwalletdClient` (gRPC), plus the value
objects the native layer in `zcash_flutter` produces and consumes. No `dart:ffi`.

```dart
import 'package:zcash/zcash.dart';

Future<void> main() async {
  final zebra = ZebraClient(); // localhost:8232
  final info = await zebra.getBlockchainInfo();
  print('${info.chain} ${info.blocks}');
  zebra.close();
}
```

`proto/` holds the lightwalletd protocol from
[zcash/lightwallet-protocol](https://github.com/zcash/lightwallet-protocol) at
`dd0ea2c3c5827a433e62c2f936b89efa2dec5a9a` (v0.4.1), plus the NU6.3 Ironwood
fields (`PoolType.IRONWOOD`, `TreeState.ironwoodTree`,
`ShieldedProtocol.ironwood`, `ChainMetadata.ironwoodCommitmentTreeSize`,
`CompactTx.ironwoodActions`) numbered as in `zcash_client_backend` 0.25.

`lib/src/grpc` is generated from `proto/`; do not edit it. Regenerate from the
repository root with `protoc_plugin` activated:

```sh
protoc --dart_out=grpc:packages/zcash/lib/src/grpc \
  --proto_path=packages/zcash/proto compact_formats.proto service.proto
```
