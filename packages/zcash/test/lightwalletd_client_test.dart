import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart' hide TreeState;
import 'package:zcash/lightwalletd_protos.dart' as lwd show TreeState, Duration;
import 'package:zcash/lightwalletd_protos.dart'
    show
        CompactTxStreamerServiceBase,
        LightdInfo,
        BlockID,
        ChainSpec,
        BlockRange,
        RawTransaction,
        TxFilter,
        SendResponse,
        TransparentAddressBlockFilter,
        Balance,
        AddressList,
        Address,
        GetMempoolTxRequest,
        Empty,
        SubtreeRoot,
        GetSubtreeRootsArg,
        GetAddressUtxosReplyList,
        GetAddressUtxosArg,
        GetAddressUtxosReply,
        PingResponse;

Server? _server;
LightwalletdClient? _client;

Future<void> _startServer(_FakeStreamer fake) async {
  _server = Server.create(services: [fake]);
  await _server!.serve(address: InternetAddress.loopbackIPv4, port: 0);
  _client = LightwalletdClient(
    host: 'localhost',
    port: _server!.port!,
    useTls: false,
  );
}

Future<void> _stopServer() async {
  await _client?.close();
  await _server?.shutdown();
}

void main() {
  group('LightwalletdClient.getInfo', () {
    setUp(
      () => _startServer(
        _FakeStreamer(
          lightdInfo: LightdInfo()
            ..version = '0.4.1'
            ..vendor = 'ECC LightWalletD'
            ..chainName = 'main'
            ..blockHeight = Int64(2500000)
            ..saplingActivationHeight = Int64(419200),
        ),
      ),
    );

    tearDown(_stopServer);

    test('deserialises LightdInfo fields', () async {
      final info = await _client!.getInfo();
      expect(info.version, '0.4.1');
      expect(info.vendor, 'ECC LightWalletD');
      expect(info.chainName, 'main');
      expect(info.blockHeight, Int64(2500000));
      expect(info.saplingActivationHeight, Int64(419200));
    });
  });

  group('LightwalletdClient Orchard parsed-only fields', () {
    setUp(
      () => _startServer(
        _FakeStreamer(
          treeState: lwd.TreeState()
            ..height = Int64(123)
            ..hash = 'tree-hash'
            ..saplingTree = 'sapling-tree'
            ..orchardTree = 'orchard-tree',
        ),
      ),
    );

    tearDown(_stopServer);

    test('getTreeState returns Orchard tree data as parsed-only', () async {
      final state = await _client!.getTreeState(BlockID()..height = Int64(123));
      final classification = OrchardDataClassifier.lightwalletdTreeState(state);

      expect(state.orchardTree, 'orchard-tree');
      expect(classification.status, CapabilityStatus.parsedOnly);
      expect(classification.present, isTrue);
      expect(classification.impliesWalletSupport, isFalse);
    });

    test(
      'getLatestTreeState returns Orchard tree data as parsed-only',
      () async {
        await _stopServer();
        await _startServer(
          _FakeStreamer(
            latestTreeState: lwd.TreeState()
              ..height = Int64(124)
              ..hash = 'latest-tree-hash'
              ..orchardTree = 'latest-orchard-tree',
          ),
        );

        final state = await _client!.getLatestTreeState();
        final classification = OrchardDataClassifier.lightwalletdTreeState(
          state,
        );

        expect(state.height, Int64(124));
        expect(state.orchardTree, 'latest-orchard-tree');
        expect(classification.status, CapabilityStatus.parsedOnly);
        expect(classification.present, isTrue);
        expect(classification.impliesWalletSupport, isFalse);
      },
    );

    test(
      'getSubtreeRoots streams Orchard root shapes as parsed-only',
      () async {
        await _stopServer();
        await _startServer(
          _FakeStreamer(
            subtreeRoots: [
              SubtreeRoot()
                ..rootHash = [1, 2, 3, 4]
                ..completingBlockHash = [5, 6, 7, 8]
                ..completingBlockHeight = Int64(125),
            ],
          ),
        );
        final arg = GetSubtreeRootsArg()
          ..shieldedProtocol = ShieldedProtocol.orchard
          ..startIndex = 2
          ..maxEntries = 1;

        final roots = await _client!.getSubtreeRoots(arg).toList();
        final argClassification = OrchardDataClassifier.subtreeRootsArg(arg);
        final rootClassification = OrchardDataClassifier.subtreeRoot(
          roots.single,
        );

        expect(roots, hasLength(1));
        expect(roots.single.rootHash, [1, 2, 3, 4]);
        expect(argClassification.status, CapabilityStatus.parsedOnly);
        expect(argClassification.present, isTrue);
        expect(rootClassification.status, CapabilityStatus.parsedOnly);
        expect(rootClassification.present, isTrue);
        expect(rootClassification.impliesWalletSupport, isFalse);
      },
    );

    test(
      'getBlockRange preserves Orchard actions and metadata as parsed-only',
      () async {
        await _stopServer();
        await _startServer(
          _FakeStreamer(
            blocks: [
              CompactBlock()
                ..height = Int64(200)
                ..chainMetadata = (ChainMetadata()
                  ..orchardCommitmentTreeSize = 88)
                ..vtx.add(
                  CompactTx()
                    ..actions.add(
                      CompactOrchardAction()
                        ..nullifier = [9]
                        ..cmx = [10]
                        ..ephemeralKey = [11]
                        ..ciphertext = [12],
                    ),
                ),
            ],
          ),
        );
        final range = BlockRange()
          ..start = (BlockID()..height = Int64(200))
          ..end = (BlockID()..height = Int64(200));

        final blocks = await _client!.getBlockRange(range).toList();
        final actions = OrchardDataClassifier.compactBlockActions(
          blocks.single,
        );
        final metadata = OrchardDataClassifier.chainMetadata(
          blocks.single.chainMetadata,
        );

        expect(blocks.single.height, Int64(200));
        expect(blocks.single.vtx.single.actions, hasLength(1));
        expect(blocks.single.chainMetadata.orchardCommitmentTreeSize, 88);
        expect(actions.status, CapabilityStatus.parsedOnly);
        expect(actions.present, isTrue);
        expect(actions.count, 1);
        expect(metadata.status, CapabilityStatus.parsedOnly);
        expect(metadata.present, isTrue);
        expect(metadata.impliesWalletSupport, isFalse);
      },
    );

    test(
      'missing Orchard fields remain parsed-only absence, not wallet support',
      () async {
        await _stopServer();
        await _startServer(
          _FakeStreamer(
            latestTreeState: lwd.TreeState()..saplingTree = 'sapling-only-tree',
            blocks: [
              CompactBlock()
                ..height = Int64(201)
                ..vtx.add(CompactTx()),
            ],
          ),
        );
        final range = BlockRange()
          ..start = (BlockID()..height = Int64(201))
          ..end = (BlockID()..height = Int64(201));
        final saplingArg = GetSubtreeRootsArg()
          ..shieldedProtocol = ShieldedProtocol.sapling
          ..startIndex = 0
          ..maxEntries = 1;

        final state = await _client!.getLatestTreeState();
        final blocks = await _client!.getBlockRange(range).toList();
        final roots = await _client!.getSubtreeRoots(saplingArg).toList();
        final classifications = [
          OrchardDataClassifier.lightwalletdTreeState(state),
          OrchardDataClassifier.compactBlockActions(blocks.single),
          OrchardDataClassifier.chainMetadata(
            blocks.single.hasChainMetadata()
                ? blocks.single.chainMetadata
                : null,
          ),
          OrchardDataClassifier.subtreeRootsArg(saplingArg),
        ];

        expect(roots, isEmpty);
        for (final classification in classifications) {
          expect(classification.status, CapabilityStatus.parsedOnly);
          expect(classification.present, isFalse);
          expect(classification.count, 0);
          expect(classification.impliesWalletSupport, isFalse);
        }
        expect(
          ShieldedCapabilityMatrix.current.statusFor(
            ShieldedPool.orchard,
            CapabilitySurface.compactBlockNoteDiscovery,
          ),
          CapabilityStatus.unsupported,
        );
      },
    );
  });

  group('LightwalletdClient Ironwood (NU6.3) wire fields', () {
    setUp(
      () => _startServer(
        _FakeStreamer(
          treeState: lwd.TreeState()
            ..height = Int64(3428143)
            ..hash = 'ironwood-activation-hash'
            ..saplingTree = 'sapling-tree'
            ..orchardTree = 'orchard-tree'
            ..ironwoodTree = 'ironwood-tree',
        ),
      ),
    );

    tearDown(_stopServer);

    test('getTreeState carries the Ironwood tree over the wire', () async {
      final state = await _client!.getTreeState(
        BlockID()..height = Int64(3428143),
      );
      expect(state.ironwoodTree, 'ironwood-tree');
      expect(state.hasIronwoodTree(), isTrue);
      expect(state.orchardTree, 'orchard-tree');
      expect(state.orchardTree, isNot(state.ironwoodTree));
    });

    test('a server that omits the Ironwood tree reports absence', () async {
      await _stopServer();
      await _startServer(
        _FakeStreamer(
          latestTreeState: lwd.TreeState()
            ..height = Int64(3428142)
            ..orchardTree = 'orchard-tree',
        ),
      );
      // Empty is the proto3 default, not an empty-tree anchor.
      final state = await _client!.getLatestTreeState();
      expect(state.hasIronwoodTree(), isFalse);
      expect(state.ironwoodTree, isEmpty);
    });

    test('compact blocks carry Ironwood actions in their own field', () async {
      await _stopServer();
      await _startServer(
        _FakeStreamer(
          blocks: [
            CompactBlock()
              ..height = Int64(3428144)
              ..chainMetadata = (ChainMetadata()
                ..orchardCommitmentTreeSize = 88
                ..ironwoodCommitmentTreeSize = 5)
              ..vtx.add(
                CompactTx()
                  ..actions.add(
                    CompactOrchardAction()
                      ..nullifier = [1]
                      ..cmx = [2]
                      ..ephemeralKey = [3]
                      ..ciphertext = [4],
                  )
                  ..ironwoodActions.add(
                    CompactOrchardAction()
                      ..nullifier = [5]
                      ..cmx = [6]
                      ..ephemeralKey = [7]
                      ..ciphertext = [8],
                  ),
              ),
          ],
        ),
      );
      final range = BlockRange()
        ..start = (BlockID()..height = Int64(3428144))
        ..end = (BlockID()..height = Int64(3428144));

      final blocks = await _client!.getBlockRange(range).toList();
      final tx = blocks.single.vtx.single;

      expect(tx.actions, hasLength(1));
      expect(tx.ironwoodActions, hasLength(1));
      expect(tx.actions.single.nullifier, [1]);
      expect(tx.ironwoodActions.single.nullifier, [5]);
      expect(blocks.single.chainMetadata.orchardCommitmentTreeSize, 88);
      expect(blocks.single.chainMetadata.ironwoodCommitmentTreeSize, 5);
    });

    test('subtree roots can be requested for the Ironwood pool', () async {
      await _stopServer();
      await _startServer(
        _FakeStreamer(
          subtreeRoots: [
            SubtreeRoot()
              ..rootHash = [1, 2, 3, 4]
              ..completingBlockHeight = Int64(3428200),
          ],
        ),
      );
      final arg = GetSubtreeRootsArg()
        ..shieldedProtocol = ShieldedProtocol.ironwood
        ..startIndex = 0
        ..maxEntries = 1;

      final roots = await _client!.getSubtreeRoots(arg).toList();
      expect(arg.shieldedProtocol, ShieldedProtocol.ironwood);
      expect(ShieldedProtocol.ironwood.value, 2);
      expect(PoolType.IRONWOOD.value, 4);
      expect(roots, hasLength(1));
    });
  });

  group('LightwalletdClient.getBlockRange', () {
    setUp(() {
      final blocks = List.generate(
        5,
        (i) => CompactBlock()
          ..height = Int64(100 + i)
          ..protoVersion = 1,
      );
      return _startServer(_FakeStreamer(blocks: blocks));
    });

    tearDown(_stopServer);

    test('emits the expected number of CompactBlocks', () async {
      final range = BlockRange()
        ..start = (BlockID()..height = Int64(100))
        ..end = (BlockID()..height = Int64(104));
      final blocks = await _client!.getBlockRange(range).toList();
      expect(blocks, hasLength(5));
      expect(blocks.first.height, Int64(100));
      expect(blocks.last.height, Int64(104));
    });

    test('allows the inclusive genesis range 0..0', () async {
      await _stopServer();
      await _startServer(
        _FakeStreamer(blocks: [CompactBlock()..height = Int64.ZERO]),
      );
      final range = BlockRange()
        ..start = (BlockID()..height = Int64.ZERO)
        ..end = (BlockID()..height = Int64.ZERO);

      final blocks = await _client!.getBlockRange(range).toList();

      expect(blocks, hasLength(1));
      expect(blocks.single.height, Int64.ZERO);
    });

    test('rejects inverted height ranges with method and range context', () {
      final range = BlockRange()
        ..start = (BlockID()..height = Int64(7))
        ..end = (BlockID()..height = Int64(3));

      expect(
        () => _client!.getBlockRange(range),
        throwsA(
          isA<LightwalletdClientException>()
              .having((e) => e.method, 'method', 'GetBlockRange')
              .having((e) => e.range, 'range', '7..3')
              .having((e) => e.toString(), 'message', contains('7..3')),
        ),
      );
    });

    test('wraps stream failures with method and range context', () async {
      await _stopServer();
      await _startServer(
        _FakeStreamer(rangeError: GrpcError.unavailable('backend offline')),
      );
      final range = BlockRange()
        ..start = (BlockID()..height = Int64(2))
        ..end = (BlockID()..height = Int64(4));

      expect(
        _client!.getBlockRange(range).toList(),
        throwsA(
          isA<LightwalletdClientException>()
              .having((e) => e.method, 'method', 'GetBlockRange')
              .having((e) => e.range, 'range', '2..4')
              .having((e) => e.cause, 'cause', isA<GrpcError>()),
        ),
      );
    });
  });

  group('LightwalletdClient.sendTransaction', () {
    setUp(
      () => _startServer(
        _FakeStreamer(
          sendResponse: SendResponse()
            ..errorCode = 0
            ..errorMessage = '',
        ),
      ),
    );

    tearDown(_stopServer);

    test('returns SendResponse with error code 0 on success', () async {
      final txBytes = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);
      final resp = await _client!.sendTransaction(txBytes);
      expect(resp.errorCode, 0);
      expect(resp.errorMessage, isEmpty);
    });

    test('returns non-zero error code on rejection', () async {
      await _stopServer();
      await _startServer(
        _FakeStreamer(
          sendResponse: SendResponse()
            ..errorCode = -1
            ..errorMessage = 'invalid transaction',
        ),
      );
      final resp = await _client!.sendTransaction(Uint8List(0));
      expect(resp.errorCode, -1);
      expect(resp.errorMessage, 'invalid transaction');
    });
  });
}

class _FakeStreamer extends CompactTxStreamerServiceBase {
  final LightdInfo? lightdInfo;
  final List<CompactBlock>? blocks;
  final SendResponse? sendResponse;
  final lwd.TreeState? treeState;
  final lwd.TreeState? latestTreeState;
  final List<SubtreeRoot>? subtreeRoots;
  final Object? rangeError;

  _FakeStreamer({
    this.lightdInfo,
    this.blocks,
    this.sendResponse,
    this.treeState,
    this.latestTreeState,
    this.subtreeRoots,
    this.rangeError,
  });

  @override
  Future<LightdInfo> getLightdInfo(ServiceCall call, Empty request) async =>
      lightdInfo ?? LightdInfo();

  @override
  Future<BlockID> getLatestBlock(ServiceCall call, ChainSpec request) async =>
      BlockID()..height = Int64(0);

  @override
  Future<CompactBlock> getBlock(ServiceCall call, BlockID request) async =>
      CompactBlock();

  @override
  Future<CompactBlock> getBlockNullifiers(
    ServiceCall call,
    BlockID request,
  ) async => CompactBlock();

  @override
  Stream<CompactBlock> getBlockRange(ServiceCall call, BlockRange request) {
    final error = rangeError;
    if (error != null) return Stream<CompactBlock>.error(error);
    return Stream.fromIterable(blocks ?? []);
  }

  @override
  Stream<CompactBlock> getBlockRangeNullifiers(
    ServiceCall call,
    BlockRange request,
  ) => const Stream.empty();

  @override
  Future<RawTransaction> getTransaction(
    ServiceCall call,
    TxFilter request,
  ) async => RawTransaction();

  @override
  Future<SendResponse> sendTransaction(
    ServiceCall call,
    RawTransaction request,
  ) async => sendResponse ?? SendResponse();

  @override
  Stream<RawTransaction> getTaddressTxids(
    ServiceCall call,
    TransparentAddressBlockFilter request,
  ) => const Stream.empty();

  @override
  Stream<RawTransaction> getTaddressTransactions(
    ServiceCall call,
    TransparentAddressBlockFilter request,
  ) => const Stream.empty();

  @override
  Future<Balance> getTaddressBalance(
    ServiceCall call,
    AddressList request,
  ) async => Balance();

  @override
  Future<Balance> getTaddressBalanceStream(
    ServiceCall call,
    Stream<Address> request,
  ) async => Balance();

  @override
  Stream<CompactTx> getMempoolTx(
    ServiceCall call,
    GetMempoolTxRequest request,
  ) => const Stream.empty();

  @override
  Stream<RawTransaction> getMempoolStream(ServiceCall call, Empty request) =>
      const Stream.empty();

  @override
  Future<lwd.TreeState> getTreeState(ServiceCall call, BlockID request) async =>
      treeState ?? lwd.TreeState();

  @override
  Future<lwd.TreeState> getLatestTreeState(
    ServiceCall call,
    Empty request,
  ) async => latestTreeState ?? treeState ?? lwd.TreeState();

  @override
  Stream<SubtreeRoot> getSubtreeRoots(
    ServiceCall call,
    GetSubtreeRootsArg request,
  ) => Stream.fromIterable(subtreeRoots ?? const []);

  @override
  Future<GetAddressUtxosReplyList> getAddressUtxos(
    ServiceCall call,
    GetAddressUtxosArg request,
  ) async => GetAddressUtxosReplyList();

  @override
  Stream<GetAddressUtxosReply> getAddressUtxosStream(
    ServiceCall call,
    GetAddressUtxosArg request,
  ) => const Stream.empty();

  @override
  Future<PingResponse> ping(ServiceCall call, lwd.Duration request) async =>
      PingResponse();
}
