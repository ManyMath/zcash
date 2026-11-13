import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

ZcashAccountMetadata _account({
  ZcashAddressNetwork network = ZcashAddressNetwork.regtest,
  int accountIndex = 0,
}) => ZcashAccountMetadata(
  network: network,
  accountIndex: accountIndex,
  ufvk: 'uview-regtest-account-$accountIndex',
  transparentAccountXpub: 'xpub-$accountIndex',
  receivers: const ZcashAccountReceiverSet(
    orchard: true,
    sapling: true,
    transparent: true,
    p2pkh: true,
    p2sh: false,
    unknown: 0,
    total: 3,
  ),
  receiverKinds: const [
    ZcashAccountReceiverKind(
      kind: ZcashAddressReceiverType.p2pkh,
      pool: ZcashAddressPool.transparent,
    ),
  ],
);

ZcashViewingKeys _viewingKeys({
  ZcashAddressNetwork network = ZcashAddressNetwork.regtest,
  int accountIndex = 0,
}) => ZcashViewingKeys(
  network: network,
  accountIndex: accountIndex,
  transparent: const ZcashTransparentViewingKeys(
    available: true,
    externalIvk: 'external-ivk',
    internalIvk: 'internal-ivk',
    defaultExternalAddress: 'tmDefaultAccountAddress',
    defaultExternalIndex: 0,
  ),
  sapling: const ZcashSaplingViewingKey(available: true),
  orchard: const ZcashOrchardViewingKey(available: true),
);

void main() {
  group('ZcashTransparentState', () {
    test('discovers and binds the account default transparent receiver', () {
      final account = _account();
      final state = ZcashTransparentState.fromAccount(
        account: account,
        viewingKeys: _viewingKeys(),
      );

      expect(state.network, ZcashAddressNetwork.regtest);
      expect(state.accountFingerprint, account.fingerprint);
      expect(state.receivers, hasLength(1));
      expect(state.receivers.single.address, 'tmDefaultAccountAddress');
      expect(state.receivers.single.childIndex, 0);
      expect(
        state.receivers.single.scope,
        ZcashTransparentReceiverScope.external,
      );
      expect(state.addresses, ['tmDefaultAccountAddress']);
    });

    test('registers additional derived receivers in deterministic order', () {
      final state = ZcashTransparentState.fromAccount(
        account: _account(),
        viewingKeys: _viewingKeys(),
        additionalReceivers: const [
          ZcashTransparentReceiver(
            address: 'tmChildTwo',
            scope: ZcashTransparentReceiverScope.external,
            childIndex: 2,
          ),
          ZcashTransparentReceiver(
            address: 'tmChildOne',
            scope: ZcashTransparentReceiverScope.external,
            childIndex: 1,
          ),
        ],
      );

      expect(state.addresses, [
        'tmDefaultAccountAddress',
        'tmChildOne',
        'tmChildTwo',
      ]);
    });

    test('adds discovered receivers to a migrated account-bound state', () {
      final account = _account();
      final state = ZcashTransparentState.empty(
        network: account.network,
        accountFingerprint: account.fingerprint,
      );

      state.registerAccountReceivers(
        account: account,
        viewingKeys: _viewingKeys(),
        additionalReceivers: const [
          ZcashTransparentReceiver(
            address: 'tmChildOne',
            scope: ZcashTransparentReceiverScope.external,
            childIndex: 1,
          ),
        ],
      );

      expect(state.addresses, ['tmDefaultAccountAddress', 'tmChildOne']);
    });

    test('persists a canonical unspent output across restart', () {
      final account = _account();
      final state = ZcashTransparentState.fromAccount(
        account: account,
        viewingKeys: _viewingKeys(),
      );
      final output = ZcashTransparentOutputObservation(
        address: 'tmDefaultAccountAddress',
        protocolTxid: '11' * 32,
        outputIndex: 2,
        scriptHex: '76a914${'22' * 20}88ac',
        valueZatoshis: 125000,
        minedHeight: 90,
        blockHash: '33' * 32,
        blockTime: 1700000000,
        isCoinbase: false,
      );

      state.applyRefresh(
        ZcashTransparentRefresh(
          network: ZcashAddressNetwork.regtest,
          accountFingerprint: account.fingerprint,
          queriedAddresses: const ['tmDefaultAccountAddress'],
          chainHeight: 100,
          chainTipHash: '44' * 32,
          canonicalBlockHashes: {90: '33' * 32, 100: '44' * 32},
          unspentOutputs: [output],
          observedSpends: const [],
        ),
      );

      final restored = ZcashTransparentState.fromJson(state.toJson());
      expect(restored.network, ZcashAddressNetwork.regtest);
      expect(restored.accountFingerprint, account.fingerprint);
      expect(restored.refreshedThroughHeight, 100);
      expect(restored.refreshedThroughBlockHash, '44' * 32);
      expect(restored.outputs, hasLength(1));
      final coin = restored.outputs.single;
      expect(coin.protocolTxid, '11' * 32);
      expect(coin.txid, reverseTxidByteOrder('11' * 32));
      expect(coin.outputIndex, 2);
      expect(coin.scriptHex, '76a914${'22' * 20}88ac');
      expect(coin.valueZatoshis, 125000);
      expect(coin.minedHeight, 90);
      expect(coin.blockHash, '33' * 32);
      expect(coin.blockTime, 1700000000);
      expect(coin.isCoinbase, isFalse);
      expect(coin.spendState, ZcashTransparentSpendState.unspent);
    });

    test('records the exact mined spend and removes it from selection', () {
      final account = _account();
      final state = ZcashTransparentState.fromAccount(
        account: account,
        viewingKeys: _viewingKeys(),
      );
      final output = ZcashTransparentOutputObservation(
        address: 'tmDefaultAccountAddress',
        protocolTxid: '11' * 32,
        outputIndex: 2,
        scriptHex: '76a914${'22' * 20}88ac',
        valueZatoshis: 125000,
        minedHeight: 90,
        blockHash: '33' * 32,
        blockTime: 1700000000,
        isCoinbase: false,
      );
      state.applyRefresh(
        ZcashTransparentRefresh(
          network: ZcashAddressNetwork.regtest,
          accountFingerprint: account.fingerprint,
          queriedAddresses: const ['tmDefaultAccountAddress'],
          chainHeight: 100,
          chainTipHash: '44' * 32,
          canonicalBlockHashes: {90: '33' * 32, 100: '44' * 32},
          unspentOutputs: [output],
          observedSpends: const [],
        ),
      );
      state.applyRefresh(
        ZcashTransparentRefresh(
          network: ZcashAddressNetwork.regtest,
          accountFingerprint: account.fingerprint,
          queriedAddresses: const ['tmDefaultAccountAddress'],
          chainHeight: 101,
          chainTipHash: '55' * 32,
          canonicalBlockHashes: {90: '33' * 32, 100: '44' * 32, 101: '55' * 32},
          unspentOutputs: const [],
          observedSpends: [
            ZcashTransparentSpendObservation(
              spentOutpoint: output.outpoint,
              spendingProtocolTxid: '66' * 32,
              spentHeight: 101,
              blockHash: '55' * 32,
              blockTime: null,
              feeZatoshis: 10000,
            ),
          ],
        ),
      );

      final spent = state.outputs.single;
      expect(spent.spendState, ZcashTransparentSpendState.spent);
      expect(spent.spendingProtocolTxid, '66' * 32);
      expect(spent.spentHeight, 101);
      expect(spent.spentBlockHash, '55' * 32);
      expect(spent.spentBlockTime, isNull);
      expect(spent.feeZatoshis, 10000);
      expect(state.coinSet.totalZatoshis, 0);
    });

    test('refuses changed immutable data for a canonical outpoint', () {
      final account = _account();
      final state = ZcashTransparentState.fromAccount(
        account: account,
        viewingKeys: _viewingKeys(),
      );
      ZcashTransparentOutputObservation output(int value) =>
          ZcashTransparentOutputObservation(
            address: 'tmDefaultAccountAddress',
            protocolTxid: '11' * 32,
            outputIndex: 2,
            scriptHex: '51',
            valueZatoshis: value,
            minedHeight: 90,
            blockHash: '33' * 32,
            blockTime: null,
            isCoinbase: false,
          );
      ZcashTransparentRefresh refresh(int value, int tip) =>
          ZcashTransparentRefresh(
            network: ZcashAddressNetwork.regtest,
            accountFingerprint: account.fingerprint,
            queriedAddresses: const ['tmDefaultAccountAddress'],
            chainHeight: tip,
            chainTipHash: (tip == 100 ? '44' : '55') * 32,
            canonicalBlockHashes: {
              90: '33' * 32,
              100: '44' * 32,
              if (tip == 101) 101: '55' * 32,
            },
            unspentOutputs: [output(value)],
            observedSpends: const [],
          );

      state.applyRefresh(refresh(125000, 100));

      expect(
        () => state.applyRefresh(refresh(125001, 101)),
        throwsA(isA<ZcashModelException>()),
      );
      expect(state.outputs.single.valueZatoshis, 125000);
    });

    test('fails closed on a reorg and rollback restores the spent coin', () {
      final account = _account();
      final state = ZcashTransparentState.fromAccount(
        account: account,
        viewingKeys: _viewingKeys(),
      );
      final output = ZcashTransparentOutputObservation(
        address: 'tmDefaultAccountAddress',
        protocolTxid: '11' * 32,
        outputIndex: 2,
        scriptHex: '76a914${'22' * 20}88ac',
        valueZatoshis: 125000,
        minedHeight: 90,
        blockHash: '33' * 32,
        blockTime: 1700000000,
        isCoinbase: false,
      );
      state.applyRefresh(
        ZcashTransparentRefresh(
          network: ZcashAddressNetwork.regtest,
          accountFingerprint: account.fingerprint,
          queriedAddresses: const ['tmDefaultAccountAddress'],
          chainHeight: 100,
          chainTipHash: '44' * 32,
          canonicalBlockHashes: {90: '33' * 32, 100: '44' * 32},
          unspentOutputs: [output],
          observedSpends: const [],
        ),
      );
      state.applyRefresh(
        ZcashTransparentRefresh(
          network: ZcashAddressNetwork.regtest,
          accountFingerprint: account.fingerprint,
          queriedAddresses: const ['tmDefaultAccountAddress'],
          chainHeight: 101,
          chainTipHash: '55' * 32,
          canonicalBlockHashes: {90: '33' * 32, 100: '44' * 32, 101: '55' * 32},
          unspentOutputs: const [],
          observedSpends: [
            ZcashTransparentSpendObservation(
              spentOutpoint: output.outpoint,
              spendingProtocolTxid: '66' * 32,
              spentHeight: 101,
              blockHash: '55' * 32,
              blockTime: null,
              feeZatoshis: null,
            ),
          ],
        ),
      );

      final replacement = ZcashTransparentRefresh(
        network: ZcashAddressNetwork.regtest,
        accountFingerprint: account.fingerprint,
        queriedAddresses: const ['tmDefaultAccountAddress'],
        chainHeight: 102,
        chainTipHash: '88' * 32,
        canonicalBlockHashes: {90: '33' * 32, 101: '77' * 32, 102: '88' * 32},
        unspentOutputs: [output],
        observedSpends: const [],
      );

      expect(
        () => state.applyRefresh(replacement),
        throwsA(isA<ZcashModelException>()),
      );
      expect(state.outputs.single.spendState, ZcashTransparentSpendState.spent);

      state.rollbackTo(height: 90, blockHash: '33' * 32);
      expect(
        state.outputs.single.spendState,
        ZcashTransparentSpendState.unspent,
      );
      expect(state.outputs.single.spendingProtocolTxid, isNull);
      state.applyRefresh(replacement);
      expect(
        state.outputs.single.spendState,
        ZcashTransparentSpendState.unspent,
      );
      expect(state.refreshedThroughHeight, 102);
    });

    test(
      'contributes exact nullable receive and spend metadata to history',
      () {
        final account = _account();
        final state = ZcashTransparentState.fromAccount(
          account: account,
          viewingKeys: _viewingKeys(),
        );
        final output = ZcashTransparentOutputObservation(
          address: 'tmDefaultAccountAddress',
          protocolTxid: '11' * 32,
          outputIndex: 0,
          scriptHex: '51',
          valueZatoshis: 125000,
          minedHeight: 90,
          blockHash: '33' * 32,
          blockTime: 1700000000,
          creationFeeZatoshis: null,
          isCoinbase: false,
        );
        state.applyRefresh(
          ZcashTransparentRefresh(
            network: ZcashAddressNetwork.regtest,
            accountFingerprint: account.fingerprint,
            queriedAddresses: const ['tmDefaultAccountAddress'],
            chainHeight: 100,
            chainTipHash: '44' * 32,
            canonicalBlockHashes: {90: '33' * 32, 100: '44' * 32},
            unspentOutputs: [output],
            observedSpends: const [],
          ),
        );
        state.applyRefresh(
          ZcashTransparentRefresh(
            network: ZcashAddressNetwork.regtest,
            accountFingerprint: account.fingerprint,
            queriedAddresses: const ['tmDefaultAccountAddress'],
            chainHeight: 101,
            chainTipHash: '55' * 32,
            canonicalBlockHashes: {
              90: '33' * 32,
              100: '44' * 32,
              101: '55' * 32,
            },
            unspentOutputs: const [],
            observedSpends: [
              ZcashTransparentSpendObservation(
                spentOutpoint: output.outpoint,
                spendingProtocolTxid: '66' * 32,
                spentHeight: 101,
                blockHash: '55' * 32,
                blockTime: null,
                feeZatoshis: 10000,
              ),
            ],
          ),
        );

        final history = ZcashTransactionHistory.fromStores(
          transparent: state,
        ).entries;
        expect(history, hasLength(2));
        final spend = history.first;
        expect(spend.protocolTxid, '66' * 32);
        expect(spend.spentZatoshis, 125000);
        expect(spend.pools, {'transparent'});
        expect(spend.blockHash, '55' * 32);
        expect(spend.timestamp, isNull);
        expect(spend.feeZatoshis, 10000);
        final receive = history.last;
        expect(receive.protocolTxid, '11' * 32);
        expect(receive.receivedZatoshis, 125000);
        expect(receive.blockHash, '33' * 32);
        expect(receive.timestamp, 1700000000);
        expect(receive.feeZatoshis, isNull);
      },
    );

    test('enforces coinbase maturity from canonical transaction identity', () {
      final account = _account();
      final state = ZcashTransparentState.fromAccount(
        account: account,
        viewingKeys: _viewingKeys(),
      );
      final coinbase = ZcashTransparentOutputObservation(
        address: 'tmDefaultAccountAddress',
        protocolTxid: '11' * 32,
        outputIndex: 0,
        scriptHex: '51',
        valueZatoshis: 625000000,
        minedHeight: 90,
        blockHash: '33' * 32,
        blockTime: null,
        isCoinbase: true,
      );
      state.applyRefresh(
        ZcashTransparentRefresh(
          network: ZcashAddressNetwork.regtest,
          accountFingerprint: account.fingerprint,
          queriedAddresses: const ['tmDefaultAccountAddress'],
          chainHeight: 188,
          chainTipHash: '44' * 32,
          canonicalBlockHashes: {90: '33' * 32, 188: '44' * 32},
          unspentOutputs: [coinbase],
          observedSpends: const [],
        ),
      );
      expect(state.coinSet.spendableZatoshis, 0);
      expect(state.coinSet.maturingZatoshis, 625000000);
      expect(state.coinSet.nextMaturityHeight, 189);

      state.applyRefresh(
        ZcashTransparentRefresh(
          network: ZcashAddressNetwork.regtest,
          accountFingerprint: account.fingerprint,
          queriedAddresses: const ['tmDefaultAccountAddress'],
          chainHeight: 189,
          chainTipHash: '55' * 32,
          canonicalBlockHashes: {90: '33' * 32, 188: '44' * 32, 189: '55' * 32},
          unspentOutputs: [coinbase],
          observedSpends: const [],
        ),
      );
      expect(state.coinSet.spendableZatoshis, 625000000);
      expect(state.coinSet.maturingZatoshis, 0);
    });

    test('refuses foreign networks, accounts, and schema versions', () {
      expect(
        () => ZcashTransparentState.fromAccount(
          account: _account(),
          viewingKeys: _viewingKeys(network: ZcashAddressNetwork.mainnet),
        ),
        throwsArgumentError,
      );
      expect(
        () => ZcashTransparentState.fromAccount(
          account: _account(),
          viewingKeys: _viewingKeys(accountIndex: 1),
        ),
        throwsArgumentError,
      );

      final state = ZcashTransparentState.fromAccount(
        account: _account(),
        viewingKeys: _viewingKeys(),
      );
      ZcashTransparentRefresh refresh({
        ZcashAddressNetwork network = ZcashAddressNetwork.regtest,
        String fingerprint = 'wrong-account',
      }) => ZcashTransparentRefresh(
        network: network,
        accountFingerprint: fingerprint,
        queriedAddresses: const ['tmDefaultAccountAddress'],
        chainHeight: 1,
        chainTipHash: '11' * 32,
        canonicalBlockHashes: {1: '11' * 32},
        unspentOutputs: const [],
        observedSpends: const [],
      );
      expect(
        () => state.applyRefresh(refresh(network: ZcashAddressNetwork.mainnet)),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => state.applyRefresh(refresh()),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ZcashTransparentState.fromJson({
          ...state.toJson(),
          'transparent_state_version': 999,
        }),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });
}
