import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

class RpcRequestLog {
  final requests = <Map<String, dynamic>>[];
}

http.Client walletMockClient(Object? result, {RpcRequestLog? log}) {
  return MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    log?.requests.add(body);
    return http.Response(
      jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

http.Client walletSequenceClient(List<Object?> results, {RpcRequestLog? log}) {
  var index = 0;
  return MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    log?.requests.add(body);
    final result = results[index++];
    return http.Response(
      jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

http.Client walletErrorClient(int code, String message) {
  return MockClient((request) async {
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
}

http.Client walletTransportFailureClient() {
  return MockClient((request) async {
    throw http.ClientException('connection refused', request.url);
  });
}

void main() {
  group('amount helpers', () {
    test('serializes zatoshis as exact eight-decimal ZEC strings', () {
      expect(zatoshisToZecString(0), '0.00000000');
      expect(zatoshisToZecString(1), '0.00000001');
      expect(zatoshisToZecString(123456789), '1.23456789');
      expect(zatoshisToZecJsonValue(100000000), '1.00000000');
    });

    test('rejects negative helper amounts and non-positive recipients', () {
      expect(
        () => zatoshisToZecString(-1),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ZSendRecipient(address: 'u1addr', amountZatoshis: 0),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ZSendRecipient(address: 'u1addr', amountZatoshis: -1),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('rejects invalid memo hex', () {
      expect(
        () => ZSendRecipient(
          address: 'u1addr',
          amountZatoshis: 1,
          memoHex: 'abc',
        ),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () =>
            ZSendRecipient(address: 'u1addr', amountZatoshis: 1, memoHex: 'zz'),
        throwsA(isA<ZcashModelException>()),
      );
    });
  });

  group('ZcashdWalletClient request shapes', () {
    test('sets basic auth and increments JSON-RPC ids', () async {
      final log = RpcRequestLog();
      String? capturedAuth;
      final client = ZcashdWalletClient(
        username: 'user',
        password: 'pass',
        client: MockClient((request) async {
          capturedAuth = request.headers['Authorization'];
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          log.requests.add(body);
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': 1}),
            200,
          );
        }),
      );

      await client.zGetNewAccount();
      await client.zGetNewAccount();

      expect(capturedAuth, startsWith('Basic '));
      expect(log.requests.map((request) => request['id']), [1, 2]);
      client.close();
    });

    test('parses z_getnewaccount object responses from zcashd', () async {
      final client = ZcashdWalletClient(
        client: walletMockClient({'account': 7}),
      );

      expect(await client.zGetNewAccount(), 7);
      client.close();
    });

    test(
      'parses z_getaddressforaccount object responses from zcashd',
      () async {
        final client = ZcashdWalletClient(
          client: walletMockClient({'address': 'uregtest1example'}),
        );

        expect(await client.zGetAddressForAccount(7), 'uregtest1example');
        client.close();
      },
    );

    test(
      'sends default z_getaddressforaccount params without receivers',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletMockClient({'address': 'uregtest1default'}, log: log),
        );

        final address = await client.zGetAddressForAccount(7);

        expect(address, 'uregtest1default');
        expect(log.requests.single['method'], 'z_getaddressforaccount');
        expect(log.requests.single['params'], [7]);
        client.close();
      },
    );

    test('sends Sapling-only z_getaddressforaccount receiver params', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        client: walletMockClient({'address': 'uregtest1sapling'}, log: log),
      );

      final address = await client.zGetAddressForAccount(
        7,
        receiverTypes: [ZcashdReceiverType.sapling],
      );

      expect(address, 'uregtest1sapling');
      expect(log.requests.single['method'], 'z_getaddressforaccount');
      expect(log.requests.single['params'], [
        7,
        [ZcashdReceiverType.sapling],
      ]);
      client.close();
    });

    test('sends Orchard-only z_getaddressforaccount receiver params', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        client: walletMockClient({'address': 'uregtest1orchard'}, log: log),
      );

      final address = await client.zGetAddressForAccount(
        7,
        receiverTypes: [ZcashdReceiverType.orchard],
      );

      expect(address, 'uregtest1orchard');
      expect(log.requests.single['method'], 'z_getaddressforaccount');
      expect(log.requests.single['params'], [
        7,
        [ZcashdReceiverType.orchard],
      ]);
      client.close();
    });

    test(
      'sends mixed Unified Address receiver params in zcashd order',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletMockClient({'address': 'uregtest1mixed'}, log: log),
        );

        final address = await client.zGetAddressForAccount(
          7,
          receiverTypes: ZcashdReceiverType.unifiedAddressReceivers,
        );

        expect(address, 'uregtest1mixed');
        expect(log.requests.single['method'], 'z_getaddressforaccount');
        expect(log.requests.single['params'], [
          7,
          [
            ZcashdReceiverType.p2pkh,
            ZcashdReceiverType.sapling,
            ZcashdReceiverType.orchard,
          ],
        ]);
        client.close();
      },
    );

    test(
      'rejects unsupported z_getaddressforaccount receiver params before RPC',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletMockClient({'address': 'unused'}, log: log),
        );

        expect(
          () => client.zGetAddressForAccount(
            7,
            receiverTypes: [ZcashdReceiverType.sapling, 'bogus'],
          ),
          throwsA(
            isA<ZcashdWalletException>()
                .having(
                  (error) => error.method,
                  'method',
                  'z_getaddressforaccount',
                )
                .having(
                  (error) => error.message,
                  'message',
                  allOf(
                    contains('unsupported receiver type'),
                    contains('bogus'),
                  ),
                ),
          ),
        );
        expect(log.requests, isEmpty);
        client.close();
      },
    );

    test(
      'rejects malformed z_getaddressforaccount object responses safely',
      () async {
        final client = ZcashdWalletClient(
          client: walletMockClient({'address': ''}),
        );

        expect(
          () => client.zGetAddressForAccount(7),
          throwsA(
            isA<ZcashdWalletException>()
                .having(
                  (error) => error.method,
                  'method',
                  'z_getaddressforaccount',
                )
                .having(
                  (error) => error.message,
                  'message',
                  allOf(contains('parse'), contains('address')),
                ),
          ),
        );
        client.close();
      },
    );

    test(
      'z_getaddressforaccount transport failures keep method context',
      () async {
        final client = ZcashdWalletClient(
          client: walletTransportFailureClient(),
        );

        expect(
          () => client.zGetAddressForAccount(
            7,
            receiverTypes: [ZcashdReceiverType.orchard],
          ),
          throwsA(
            isA<ZcashdWalletException>()
                .having(
                  (error) => error.method,
                  'method',
                  'z_getaddressforaccount',
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('transport failed'),
                ),
          ),
        );
        client.close();
      },
    );

    test(
      'sends z_sendmany recipients and optional positional params exactly',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletMockClient('opid-send', log: log),
        );

        final opid = await client.zSendMany('from-addr', [
          ZSendRecipient(
            address: 'to-addr',
            amountZatoshis: 123456789,
            memoHex: 'f09f9880',
            subtractFeeFromAmount: true,
          ),
        ], privacyPolicy: PrivacyPolicy.allowRevealedRecipients);

        expect(opid, 'opid-send');
        expect(log.requests.single['method'], 'z_sendmany');
        expect(log.requests.single['params'], [
          'from-addr',
          [
            {
              'address': 'to-addr',
              'amount': '1.23456789',
              'memo': 'f09f9880',
              'subtractFeeFromAmount': true,
            },
          ],
          1,
          '0.00010000',
          'AllowRevealedRecipients',
        ]);
        client.close();
      },
    );

    test(
      'sends explicit minConf 1 and FullPrivacy for Sapling spends',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletMockClient('opid-private-send', log: log),
        );

        final opid = await client.zSendMany(
          'zregtestsapling1from',
          [
            ZSendRecipient(
              address: 'zregtestsapling1to',
              amountZatoshis: 1000000,
            ),
          ],
          minConf: 1,
          privacyPolicy: PrivacyPolicy.fullPrivacy,
        );

        expect(opid, 'opid-private-send');
        expect(log.requests.single['method'], 'z_sendmany');
        expect(log.requests.single['params'], [
          'zregtestsapling1from',
          [
            {'address': 'zregtestsapling1to', 'amount': '0.01000000'},
          ],
          1,
          '0.00010000',
          'FullPrivacy',
        ]);
        client.close();
      },
    );

    test('sends z_shieldcoinbase optional positional params exactly', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        client: walletMockClient({
          'opid': 'opid-shield',
          'remainingUTXOs': 2,
          'remainingValue': '0.50000000',
          'shieldingUTXOs': 3,
          'shieldingValue': '1.25000000',
        }, log: log),
      );

      final result = await client.zShieldCoinbase(
        '*',
        'u1shielded',
        limit: 25,
        privacyPolicy: PrivacyPolicy.allowRevealedSenders,
      );

      expect(result.operationId, 'opid-shield');
      expect(result.remainingValueZatoshis, 50000000);
      expect(result.shieldingValueZatoshis, 125000000);
      expect(log.requests.single['method'], 'z_shieldcoinbase');
      expect(log.requests.single['params'], [
        '*',
        'u1shielded',
        '0.00010000',
        25,
        'AllowRevealedSenders',
      ]);
      client.close();
    });

    test('preserves empty operation id lists as RPC params', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        client: walletMockClient(<dynamic>[], log: log),
      );

      final statuses = await client.zGetOperationStatus([]);

      expect(statuses, isEmpty);
      expect(log.requests.single['method'], 'z_getoperationstatus');
      expect(log.requests.single['params'], [<dynamic>[]]);
      client.close();
    });

    test(
      'z_importkey sends key, default no-rescan, and parses null success',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletMockClient(null, log: log),
        );

        final result = await client.zImportKey('secret-extended-key-test1abc');

        expect(result.responseShape, 'null');
        expect(result.address, isNull);
        expect(result.keyType, isNull);
        expect(log.requests.single['method'], 'z_importkey');
        expect(log.requests.single['params'], [
          'secret-extended-key-test1abc',
          'no',
        ]);
        client.close();
      },
    );

    test(
      'z_importkey includes startHeight after explicit rescan mode',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletMockClient({
            'address_type': 'sapling',
            'address': 'ztestsapling1abc',
          }, log: log),
        );

        final result = await client.zImportKey(
          'secret-extended-key-test1abc',
          rescan: 'whenkeyisnew',
          startHeight: 123,
        );

        expect(result.responseShape, 'object');
        expect(result.keyType, 'sapling');
        expect(result.address, 'ztestsapling1abc');
        expect(log.requests.single['params'], [
          'secret-extended-key-test1abc',
          'whenkeyisnew',
          123,
        ]);
        client.close();
      },
    );

    test('z_importkey rejects empty keys before RPC', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        client: walletMockClient(null, log: log),
      );

      expect(
        () => client.zImportKey(''),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.method, 'method', 'z_importkey')
              .having((error) => error.message, 'message', contains('empty')),
        ),
      );
      expect(log.requests, isEmpty);
      client.close();
    });

    test('rejects non-positive generate counts before RPC', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        client: walletMockClient(<String>['unused'], log: log),
      );

      expect(
        () => client.generate(0),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.method, 'method', 'generate')
              .having(
                (error) => error.message,
                'message',
                contains('positive'),
              ),
        ),
      );
      expect(
        () => client.generate(-1),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.method, 'method', 'generate')
              .having(
                (error) => error.message,
                'message',
                contains('positive'),
              ),
        ),
      );
      expect(log.requests, isEmpty);
      client.close();
    });

    test('allows wallet-moving RPCs on loopback regtest by default', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        host: '127.0.0.1',
        client: walletMockClient('opid-safe-send', log: log),
      );

      final opid = await client.zSendMany('from-addr', [
        ZSendRecipient(address: 'to-addr', amountZatoshis: 1),
      ]);

      expect(opid, 'opid-safe-send');
      expect(log.requests.single['method'], 'z_sendmany');
      client.close();
    });

    test('rejects non-loopback wallet-moving RPCs before HTTP', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        host: '203.0.113.10',
        client: walletMockClient('unused', log: log),
      );

      expect(
        () => client.zSendMany('from-addr', [
          ZSendRecipient(address: 'to-addr', amountZatoshis: 1),
        ]),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.method, 'method', 'z_sendmany')
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('loopback'),
                  contains('endpoint=http://203.0.113.10:8232/'),
                  contains('network=regtest'),
                ),
              ),
        ),
      );
      expect(log.requests, isEmpty);
      client.close();
    });

    test('rejects non-regtest wallet-moving RPCs before HTTP', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        network: 'mainnet',
        client: walletMockClient('unused', log: log),
      );

      expect(
        () => client.zShieldCoinbase('*', 'u1shielded'),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.method, 'method', 'z_shieldcoinbase')
              .having(
                (error) => error.message,
                'message',
                allOf(contains('not regtest'), contains('network=mainnet')),
              ),
        ),
      );
      expect(log.requests, isEmpty);
      client.close();
    });

    test('unsafe opt-in allows non-local non-regtest wallet RPCs', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        host: '203.0.113.10',
        network: 'mainnet',
        unsafeAllowNonLocalOrNonRegtestWalletRpc: true,
        client: walletMockClient(null, log: log),
      );

      final result = await client.zImportKey('secret-extended-key-test1abc');

      expect(result.responseShape, 'null');
      expect(log.requests.single['method'], 'z_importkey');
      client.close();
    });

    test('safety rejection redacts credentials and wallet inputs', () async {
      const zkey = 'secret-extended-key-test1abcdefghijklmnopqrstuvwxyz';
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        host: '203.0.113.20',
        username: 'rpc-user',
        password: 'rpc-pass',
        client: walletMockClient(null, log: log),
      );

      expect(
        () => client.zImportKey(zkey),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.method, 'method', 'z_importkey')
              .having(
                (error) => error.toString(),
                'toString',
                allOf(
                  contains('endpoint=http://203.0.113.20:8232/'),
                  isNot(contains(zkey)),
                  isNot(contains('abcdefghijklmnopqrstuvwxyz')),
                  isNot(contains('rpc-user')),
                  isNot(contains('rpc-pass')),
                ),
              ),
        ),
      );
      expect(log.requests, isEmpty);
      client.close();
    });
  });

  group('ZcashdWalletClient parsing and errors', () {
    test('parses z_importkey scalar success variants', () async {
      final client = ZcashdWalletClient(client: walletMockClient('success'));

      final result = await client.zImportKey('secret-extended-key-test1abc');

      expect(result.responseShape, 'string');
      expect(result.message, 'success');
      client.close();
    });

    test(
      'z_importkey RPC errors are redacted but keep method context',
      () async {
        const zkey = 'secret-extended-key-test1abcdefghijklmnopqrstuvwxyz';
        final client = ZcashdWalletClient(
          client: walletErrorClient(-5, 'Invalid key $zkey'),
        );

        expect(
          () => client.zImportKey(zkey),
          throwsA(
            isA<ZcashdWalletException>()
                .having((error) => error.method, 'method', 'z_importkey')
                .having(
                  (error) => error.message,
                  'message',
                  contains('code=-5'),
                )
                .having(
                  (error) => error.toString(),
                  'toString',
                  allOf(
                    contains('secret-exten'),
                    isNot(contains(zkey)),
                    isNot(contains('abcdefghijklmnopqrstuvwxyz')),
                  ),
                ),
          ),
        );
        client.close();
      },
    );

    test(
      'z_importkey rejects malformed object responses with safe fields',
      () async {
        final client = ZcashdWalletClient(
          client: walletMockClient({'unexpected': 'value'}),
        );

        expect(
          () => client.zImportKey('secret-extended-key-test1abc'),
          throwsA(
            isA<ZcashdWalletException>()
                .having((error) => error.method, 'method', 'z_importkey')
                .having(
                  (error) => error.message,
                  'message',
                  allOf(contains('parse'), contains('unexpected')),
                ),
          ),
        );
        client.close();
      },
    );

    test('throws ZebraRpcException on JSON-RPC error bodies', () async {
      final client = ZcashdWalletClient(
        client: walletErrorClient(-6, 'Insufficient funds'),
      );

      expect(
        () => client.zSendMany('from', [
          ZSendRecipient(address: 'to', amountZatoshis: 1),
        ]),
        throwsA(
          isA<ZebraRpcException>()
              .having((error) => error.code, 'code', -6)
              .having(
                (error) => error.message,
                'message',
                'Insufficient funds',
              ),
        ),
      );
      client.close();
    });

    test('names methods when model parsing fails', () async {
      final client = ZcashdWalletClient(
        client: walletMockClient({'bad': 'shape'}),
      );

      expect(
        () => client.generate(1),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.method, 'method', 'generate')
              .having((error) => error.message, 'message', contains('parse')),
        ),
      );
      client.close();
    });

    test(
      'polls operation status without consuming operation results',
      () async {
        final log = RpcRequestLog();
        final client = ZcashdWalletClient(
          client: walletSequenceClient([
            [
              {'id': 'opid-1', 'status': 'executing'},
            ],
            [
              {
                'id': 'opid-1',
                'status': 'success',
                'result': {'txid': 'txid-1'},
                'execution_secs': 0.25,
              },
            ],
          ], log: log),
          pollInterval: Duration.zero,
        );

        final status = await client.waitForOperation(
          'opid-1',
          timeout: const Duration(seconds: 1),
        );

        expect(status.status, 'success');
        expect(status.txid, 'txid-1');
        expect(status.executionSeconds, 0.25);
        expect(
          log.requests.map((request) => request['method']),
          everyElement('z_getoperationstatus'),
        );
        client.close();
      },
    );

    test('mixed operation arrays return exact requested success', () async {
      final log = RpcRequestLog();
      final client = ZcashdWalletClient(
        client: walletMockClient([
          {
            'id': 'opid-unrelated',
            'status': 'success',
            'result': {'txid': 'txid-unrelated'},
          },
          {
            'id': 'opid-requested',
            'status': 'success',
            'result': {'txid': 'txid-requested'},
          },
        ], log: log),
        pollInterval: Duration.zero,
      );

      final status = await client.waitForOperation(
        'opid-requested',
        timeout: const Duration(seconds: 1),
      );

      expect(status.operationId, 'opid-requested');
      expect(status.txid, 'txid-requested');
      expect(log.requests.single['params'], [
        ['opid-requested'],
      ]);
      client.close();
    });

    test(
      'unrelated success before requested pending does not complete polling',
      () async {
        final client = ZcashdWalletClient(
          client: walletSequenceClient([
            [
              {
                'id': 'opid-unrelated',
                'status': 'success',
                'result': {'txid': 'txid-unrelated'},
              },
              {'id': 'opid-requested', 'status': 'executing'},
            ],
            [
              {
                'id': 'opid-unrelated',
                'status': 'success',
                'result': {'txid': 'txid-unrelated'},
              },
              {
                'id': 'opid-requested',
                'status': 'failed',
                'error': {'code': -1, 'message': 'requested boom'},
              },
            ],
          ]),
          pollInterval: Duration.zero,
        );

        expect(
          () => client.waitForOperation(
            'opid-requested',
            timeout: const Duration(seconds: 1),
          ),
          throwsA(
            isA<ZcashdWalletException>()
                .having((error) => error.operationId, 'opid', 'opid-requested')
                .having(
                  (error) => error.message,
                  'message',
                  contains('requested boom'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('txid-unrelated')),
                ),
          ),
        );
        client.close();
      },
    );

    test(
      'unrelated operation statuses time out without being selected',
      () async {
        final client = ZcashdWalletClient(
          client: walletMockClient([
            {
              'id': 'opid-unrelated',
              'status': 'success',
              'result': {'txid': 'txid-unrelated'},
            },
          ]),
          pollInterval: const Duration(milliseconds: 10),
        );

        expect(
          () => client.waitForOperation(
            'opid-missing',
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(
            isA<ZcashdWalletException>()
                .having((error) => error.operationId, 'opid', 'opid-missing')
                .having(
                  (error) => error.message,
                  'message',
                  contains('Last matching status: none'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('nonMatching='),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('txid-unrelated')),
                ),
          ),
        );
        client.close();
      },
    );

    test('malformed operation statuses without ids are ignored', () async {
      final client = ZcashdWalletClient(
        client: walletMockClient([
          {
            'status': 'success',
            'result': {'txid': 'txid-unrelated'},
          },
        ]),
        pollInterval: const Duration(milliseconds: 10),
      );

      expect(
        () => client.waitForOperation(
          'opid-missing',
          timeout: const Duration(milliseconds: 1),
        ),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.operationId, 'opid', 'opid-missing')
              .having(
                (error) => error.message,
                'message',
                contains('Last matching status: none'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('malformed='),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('txid-unrelated')),
              ),
        ),
      );
      client.close();
    });

    test('operation failures expose opid, status, and error', () async {
      final client = ZcashdWalletClient(
        client: walletMockClient([
          {
            'id': 'opid-failed',
            'status': 'failed',
            'error': {'code': -1, 'message': 'boom'},
          },
        ]),
        pollInterval: Duration.zero,
      );

      expect(
        () => client.waitForOperation(
          'opid-failed',
          timeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.operationId, 'opid', 'opid-failed')
              .having((error) => error.message, 'message', contains('failed'))
              .having((error) => error.message, 'message', contains('boom')),
        ),
      );
      client.close();
    });

    test('operation timeout exposes opid and last observed status', () async {
      final client = ZcashdWalletClient(
        client: walletMockClient([
          {'id': 'opid-slow', 'status': 'executing'},
        ]),
        pollInterval: Duration.zero,
      );

      expect(
        () => client.waitForOperation('opid-slow', timeout: Duration.zero),
        throwsA(
          isA<ZcashdWalletException>()
              .having((error) => error.operationId, 'opid', 'opid-slow')
              .having(
                (error) => error.message,
                'message',
                contains('Timed out'),
              ),
        ),
      );
      client.close();
    });
  });
}
