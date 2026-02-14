import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

http.Client mockClient(Object? result) => MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

http.Client errorClient(int code, String message) =>
    MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          'error': {'code': code, 'message': message},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

void main() {
  group('ZebraClient', () {
    group('getInfo', () {
      test('parses node info', () async {
        final client = ZebraClient(
          client: mockClient({'build': '5.9.0', 'subversion': '/Zebra:1.9.0/'}),
        );
        final info = await client.getInfo();
        expect(info.build, '5.9.0');
        expect(info.subversion, '/Zebra:1.9.0/');
        client.close();
      });
    });

    group('getBlockchainInfo', () {
      test('parses chain, height, and tip hash', () async {
        final client = ZebraClient(
          client: mockClient({
            'chain': 'main',
            'blocks': 2500000,
            'bestblockhash': 'aabbcc',
            'estimatedheight': 2500000,
            'upgrades': {},
          }),
        );
        final info = await client.getBlockchainInfo();
        expect(info.chain, 'main');
        expect(info.blocks, 2500000);
        expect(info.bestBlockHash, 'aabbcc');
        client.close();
      });

      test('deserialises network upgrades', () async {
        final client = ZebraClient(
          client: mockClient({
            'chain': 'main',
            'blocks': 1,
            'bestblockhash': 'aa',
            'estimatedheight': 1,
            'upgrades': {
              '76b809bb': {
                'name': 'Sapling',
                'activationheight': 419200,
                'status': 'active',
              },
            },
          }),
        );
        final info = await client.getBlockchainInfo();
        final sapling = info.upgrades['76b809bb']!;
        expect(sapling.name, 'Sapling');
        expect(sapling.activationHeight, 419200);
        expect(sapling.status, 'active');
        client.close();
      });
    });

    group('getBestBlockHeightAndHash', () {
      test('parses height and hash', () async {
        final client = ZebraClient(
          client: mockClient({'height': 2500000, 'hash': 'deadbeef'}),
        );
        final tip = await client.getBestBlockHeightAndHash();
        expect(tip.height, 2500000);
        expect(tip.hash, 'deadbeef');
        client.close();
      });
    });

    group('getBlock', () {
      test('parses block fields', () async {
        final client = ZebraClient(
          client: mockClient({
            'hash': 'blockhash',
            'confirmations': 10,
            'height': 100,
            'time': 1700000000,
            'tx': ['txid1', 'txid2'],
          }),
        );
        final block = await client.getBlock('100');
        expect(block.hash, 'blockhash');
        expect(block.confirmations, 10);
        expect(block.transactions, ['txid1', 'txid2']);
        client.close();
      });
    });

    group('getTransaction', () {
      test('parses confirmed transaction', () async {
        final client = ZebraClient(
          client: mockClient({
            'txid': 'mytxid',
            'hex': 'deadbeef',
            'height': 500,
            'blockhash': 'someblockhash',
            'confirmations': 3,
            'time': 1700000001,
          }),
        );
        final tx = await client.getTransaction('mytxid');
        expect(tx.txid, 'mytxid');
        expect(tx.isMined, isTrue);
        expect(tx.confirmations, 3);
        client.close();
      });
    });

    group('getAddressBalance', () {
      test('returns balance in zatoshis and ZEC', () async {
        final client = ZebraClient(
          client: mockClient({'balance': 100000000}),
        );
        final balance = await client.getAddressBalance(['t1addr']);
        expect(balance.zatoshis, 100000000);
        expect(balance.zec, closeTo(1.0, 1e-9));
        client.close();
      });
    });

    group('getAddressUtxos', () {
      test('parses UTXO list', () async {
        final client = ZebraClient(
          client: mockClient([
            {
              'address': 't1addr',
              'txid': 'utxotxid',
              'outputIndex': 0,
              'script': 'deadbeef',
              'satoshis': 50000000,
              'height': 1000,
            },
          ]),
        );
        final utxos = await client.getAddressUtxos(['t1addr']);
        expect(utxos, hasLength(1));
        expect(utxos.first.satoshis, 50000000);
        expect(utxos.first.zec, closeTo(0.5, 1e-9));
        client.close();
      });
    });

    group('getTreeState', () {
      test('parses block hash and height', () async {
        final client = ZebraClient(
          client: mockClient({
            'hash': 'treehash',
            'height': 2000000,
            'time': 1700000000,
            'sapling': {
              'commitments': {'finalState': 'saplingroot'},
            },
          }),
        );
        final state = await client.getTreeState('2000000');
        expect(state.hash, 'treehash');
        expect(state.sapling?.finalState, 'saplingroot');
        expect(state.orchard, isNull);
        client.close();
      });
    });

    group('getBlockHeader', () {
      test('parses header fields', () async {
        final client = ZebraClient(
          client: mockClient({
            'hash': 'headerhash',
            'confirmations': 5,
            'height': 2600000,
            'version': 4,
            'merkleroot': 'merkle',
            'time': 1740000000,
            'nonce': '0000',
            'bits': '1f07ffff',
            'previousblockhash': 'prevhash',
          }),
        );
        final h = await client.getBlockHeader('2600000');
        expect(h.hash, 'headerhash');
        expect(h.height, 2600000);
        expect(h.previousBlockHash, 'prevhash');
        expect(h.nextBlockHash, isNull);
        client.close();
      });
    });

    group('getBlockFull', () {
      test('parses verbosity-2 block with decoded txs', () async {
        final tx = {'txid': 'fulltxid', 'hex': 'aa', 'size': 250};
        final client = ZebraClient(
          client: mockClient({
            'hash': 'fullblockhash',
            'confirmations': 2,
            'height': 2600001,
            'time': 1740000001,
            'tx': [tx],
          }),
        );
        final block = await client.getBlockFull('2600001');
        expect(block.hash, 'fullblockhash');
        expect(block.transactions, hasLength(1));
        expect(block.transactions.first['txid'], 'fulltxid');
        client.close();
      });
    });

    group('stop', () {
      test('sends stop RPC without error', () async {
        final client = ZebraClient(client: mockClient(''));
        await expectLater(client.stop(), completes);
        client.close();
      });
    });

    group('cookie auth', () {
      test('sets Authorization header when credentials provided', () async {
        String? capturedAuth;
        final authClient = MockClient((request) async {
          capturedAuth = request.headers['Authorization'];
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': 'aa'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = ZebraClient(
          username: 'zebra',
          password: 'secret',
          client: authClient,
        );
        await client.getBestBlockHash();
        expect(capturedAuth, startsWith('Basic '));
        client.close();
      });
    });

    group('validateAddress', () {
      test('parses valid transparent address', () async {
        final client = ZebraClient(
          client: mockClient({
            'isvalid': true,
            'address': 't1addr',
            'type': 'pubkeyhash',
            'ismine': false,
          }),
        );
        final v = await client.validateAddress('t1addr');
        expect(v.isValid, isTrue);
        expect(v.addressType, 'pubkeyhash');
        client.close();
      });

      test('parses invalid address', () async {
        final client =
            ZebraClient(client: mockClient({'isvalid': false}));
        final v = await client.validateAddress('notanaddr');
        expect(v.isValid, isFalse);
        client.close();
      });
    });

    group('getPeerInfo', () {
      test('parses peer list', () async {
        final client = ZebraClient(
          client: mockClient([
            {
              'addr': '1.2.3.4:8233',
              'bytessent': 1024,
              'bytesrecv': 2048,
              'inbound': false,
              'subver': '/Zebra:2.3.0/',
            },
          ]),
        );
        final peers = await client.getPeerInfo();
        expect(peers, hasLength(1));
        expect(peers.first.addr, '1.2.3.4:8233');
        expect(peers.first.inbound, isFalse);
        client.close();
      });
    });

    group('getBlockSubsidy', () {
      test('parses miner and funding streams', () async {
        final client = ZebraClient(
          client: mockClient({
            'miner': 312500000,
            'fundingstreams': [
              {'recipient': 'ECC', 'valueZat': 62500000},
            ],
          }),
        );
        final sub = await client.getBlockSubsidy();
        expect(sub.miner, 312500000);
        expect(sub.fundingStreams, hasLength(1));
        expect(sub.fundingStreams.first.recipient, 'ECC');
        client.close();
      });
    });

    group('getBlockTemplate', () {
      test('parses template fields', () async {
        final client = ZebraClient(
          client: mockClient({
            'version': 4,
            'previousblockhash': 'prevhash',
            'transactions': [
              {'data': 'deadbeef', 'hash': 'txhash'},
            ],
            'coinbasetxn': {'data': 'coinbasedata'},
            'target':
                '0000007fffff0000000000000000000000000000000000000000000000000000',
            'mintime': 1740000000,
            'bits': '1f07ffff',
            'height': 3000000,
          }),
        );
        final tmpl = await client.getBlockTemplate();
        expect(tmpl.version, 4);
        expect(tmpl.previousBlockHash, 'prevhash');
        expect(tmpl.transactions, hasLength(1));
        expect(tmpl.transactions.first['hash'], 'txhash');
        expect(tmpl.coinbaseTxn, isNotNull);
        expect(tmpl.coinbaseValue, isNull);
        expect(tmpl.target,
            '0000007fffff0000000000000000000000000000000000000000000000000000');
        expect(tmpl.minTime, 1740000000);
        expect(tmpl.bits, '1f07ffff');
        expect(tmpl.height, 3000000);
        client.close();
      });

      test('parses coinbasevalue when coinbasetxn absent', () async {
        final client = ZebraClient(
          client: mockClient({
            'version': 4,
            'previousblockhash': 'prevhash',
            'transactions': <dynamic>[],
            'coinbasevalue': 312500000,
            'target':
                '0000007fffff0000000000000000000000000000000000000000000000000000',
            'mintime': 1740000000,
            'bits': '1f07ffff',
            'height': 3000001,
          }),
        );
        final tmpl = await client.getBlockTemplate();
        expect(tmpl.coinbaseTxn, isNull);
        expect(tmpl.coinbaseValue, 312500000);
        client.close();
      });
    });

    group('submitBlock', () {
      test('returns null on acceptance', () async {
        final client = ZebraClient(client: mockClient(null));
        final result = await client.submitBlock('deadbeef');
        expect(result, isNull);
        client.close();
      });

      test('returns rejection reason string on failure', () async {
        final client = ZebraClient(client: mockClient('inconclusive'));
        final result = await client.submitBlock('badhex');
        expect(result, 'inconclusive');
        client.close();
      });
    });

    group('getAddressMempool', () {
      test('parses mempool entries', () async {
        final client = ZebraClient(
          client: mockClient([
            {
              'txid': 'mempooltxid',
              'index': 0,
              'satoshis': 100000000,
              'script': 'deadbeef',
              'address': 't1addr',
            },
          ]),
        );
        final entries = await client.getAddressMempool(['t1addr']);
        expect(entries, hasLength(1));
        expect(entries.first.txid, 'mempooltxid');
        expect(entries.first.index, 0);
        expect(entries.first.satoshis, 100000000);
        expect(entries.first.script, 'deadbeef');
        expect(entries.first.address, 't1addr');
        client.close();
      });

      test('returns empty list when mempool has no matching entries', () async {
        final client = ZebraClient(client: mockClient(<dynamic>[]));
        final entries = await client.getAddressMempool(['t1addr']);
        expect(entries, isEmpty);
        client.close();
      });
    });

    group('error handling', () {
      test('throws ZebraRpcException on RPC error', () async {
        final client = ZebraClient(
          client: errorClient(-8, 'Block not found'),
        );
        expect(
          () => client.getBlock('nonexistent'),
          throwsA(
            isA<ZebraRpcException>()
                .having((e) => e.code, 'code', -8)
                .having((e) => e.message, 'message', 'Block not found'),
          ),
        );
        client.close();
      });
    });
  });
}
