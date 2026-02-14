## 0.0.6

- Target Zebra 3.0, which activates NU6.1 on mainnet.
- Add validateAddress, zValidateAddress, reconsiderBlock and
  getRawMempoolVerbose.
- Bump http to 1.6 and test to 1.27.

## 0.0.5

- Add getBlockCount, getBlockHash, getMempoolInfo, invalidateBlock and addNode.
- Expose the value pools, including the NU6.1 lockbox, and the received total
  of an address balance.
- Bump http to 1.5.

## 0.0.4

- Add getPeerInfo, getNetworkInfo, getBlockSubsidy and getDifficulty.
- Make the request timeout configurable.
- Bump http to 1.4 and lints to 6.0.

## 0.0.3

- Target Zebra 2.2.
- Add cookie auth, stop, getBlockHeader and getBlockFull (getblock verbosity 2).
- Bump http to 1.3.

## 0.0.2

- Add ZebraClient for the Zebra 1.9 JSON-RPC API.
- Drop the native_toolchain_rust and native_assets_cli dependencies.

## 0.0.1-dev.1

- Initial version.
