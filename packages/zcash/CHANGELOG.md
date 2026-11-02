## 0.0.8

First release of the pure Dart package.

- `ZebraClient` and `ZcashdWalletClient` over JSON-RPC, `LightwalletdClient`
  over gRPC with the lightwalletd protocol at v0.4.1 plus the NU6.3 Ironwood
  fields.
- Account, key, address and proposal models, including ZIP 316 Revision 2
  address metadata and ZIP 321 payment requests.
- Note, balance and transaction-history accumulation across scans for the
  transparent, Sapling, Orchard and Ironwood pools.
- Wallet sync from lightwalletd with reorg recovery.
- ZIP 318 Orchard to Ironwood migration planning with per-network parameters.

## 0.0.1-dev.1

- Placeholder release.
