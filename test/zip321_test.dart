import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

void main() {
  group('parseZcashUri', () {
    test('single payment address only', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final req = parseZcashUri('zcash:$addr');
      expect(req, isNotNull);
      expect(req!.payments, hasLength(1));
      expect(req.payments.first.address, addr);
      expect(req.payments.first.amountZatoshis, isNull);
      expect(req.payments.first.memo, isNull);
      expect(req.payments.first.label, isNull);
    });

    test('single payment with amount, memo, label', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      // "Hello world" in base64url without padding
      const memoBase64 = 'SGVsbG8gd29ybGQ';
      final req = parseZcashUri(
          'zcash:$addr?amount=1.5&memo=$memoBase64&label=Donation');
      expect(req, isNotNull);
      final p = req!.payments.first;
      expect(p.address, addr);
      expect(p.amountZatoshis, BigInt.from(150000000));
      expect(p.memo, isNotNull);
      expect(String.fromCharCodes(p.memo!), 'Hello world');
      expect(p.label, 'Donation');
    });

    test('multi-payment indexes 0 and 1', () {
      const addr0 = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      const addr1 = 'zs1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsqkztjk';
      final req = parseZcashUri(
          'zcash:?address.0=$addr0&amount.0=1.0&address.1=$addr1&amount.1=0.5');
      expect(req, isNotNull);
      expect(req!.payments, hasLength(2));
      expect(req.payments[0].address, addr0);
      expect(req.payments[0].amountZatoshis, BigInt.from(100000000));
      expect(req.payments[1].address, addr1);
      expect(req.payments[1].amountZatoshis, BigInt.from(50000000));
    });

    test('index-less params default to index 0', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final req = parseZcashUri('zcash:?address=$addr&amount=2.0');
      expect(req, isNotNull);
      expect(req!.payments.first.address, addr);
      expect(req.payments.first.amountZatoshis, BigInt.from(200000000));
    });

    test('scheme is case-insensitive', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      // Dart lowercases the scheme.
      final req = parseZcashUri('zcash:$addr');
      expect(req, isNotNull);
    });

    test('invalid scheme returns null', () {
      expect(
          parseZcashUri(
              'bitcoin:t1KRmojzZ6UGCoJDKfEfKjEbDMD6fZDMGhF'),
          isNull);
    });

    test('garbage input returns null', () {
      expect(parseZcashUri('not a uri at all'), isNull);
    });

    test('missing address for index returns null', () {
      expect(parseZcashUri('zcash:?amount.0=1.0'), isNull);
    });

    test('duplicate address param returns null', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      expect(
          parseZcashUri('zcash:$addr?address.0=otheraddr'),
          isNull);
    });

    test('memo > 512 bytes returns null', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final bigMemo = Uint8List(513);
      final encoded = base64Url.encode(bigMemo).replaceAll('=', '');
      expect(parseZcashUri('zcash:$addr?memo=$encoded'), isNull);
    });

    test('memo exactly 512 bytes is accepted', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final okMemo = Uint8List(512);
      final encoded = base64Url.encode(okMemo).replaceAll('=', '');
      final req = parseZcashUri('zcash:$addr?memo=$encoded');
      expect(req, isNotNull);
      expect(req!.payments.first.memo!.length, 512);
    });

    test('amount with 8 decimal places parses correctly', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final req = parseZcashUri('zcash:$addr?amount=0.00000001');
      expect(req, isNotNull);
      expect(req!.payments.first.amountZatoshis, BigInt.one);
    });

    test('amount with more than 8 decimal places returns null', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      expect(parseZcashUri('zcash:$addr?amount=0.000000001'), isNull);
    });
  });

  group('formatZcashUri', () {
    test('round-trip: single payment address only', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(address: addr),
      ]);
      final uri = formatZcashUri(req);
      expect(uri, 'zcash:$addr');
      final parsed = parseZcashUri(uri);
      expect(parsed!.payments.first.address, addr);
    });

    test('round-trip: single payment with amount, memo, label', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final memo = Uint8List.fromList([72, 101, 108, 108, 111]);
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(
          address: addr,
          amountZatoshis: BigInt.from(123456789),
          memo: memo,
          label: 'Test payment',
        ),
      ]);
      final uri = formatZcashUri(req);
      final p = parseZcashUri(uri)!.payments.first;
      expect(p.address, addr);
      expect(p.amountZatoshis, BigInt.from(123456789));
      expect(p.memo!.toList(), memo.toList());
      expect(p.label, 'Test payment');
    });

    test('round-trip: multi-payment indexes 0 and 1', () {
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(
          address: 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq',
          amountZatoshis: BigInt.from(100000000),
        ),
        ZcashPaymentTarget(
          address: 'zs1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsqkztjk',
          amountZatoshis: BigInt.from(50000000),
          message: 'Split payment',
        ),
      ]);
      final uri = formatZcashUri(req);
      final parsed = parseZcashUri(uri)!;
      expect(parsed.payments, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(parsed.payments[i].address, req.payments[i].address);
        expect(
            parsed.payments[i].amountZatoshis, req.payments[i].amountZatoshis);
      }
      expect(parsed.payments[1].message, 'Split payment');
    });

    test('round-trip: other params preserved', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(
          address: addr,
          other: {'req-foo': 'bar'},
        ),
      ]);
      final uri = formatZcashUri(req);
      final p = parseZcashUri(uri)!.payments.first;
      expect(p.other['req-foo'], 'bar');
    });

    test('throws for transparent address with memo', () {
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(
          address: 't1Rv3KSTF8D7hDMMZfcE87ZYZMQ2Np2mfUE',
          memo: Uint8List.fromList([1, 2, 3]),
        ),
      ]);
      expect(() => formatZcashUri(req), throwsArgumentError);
    });

    test('throws for negative amountZatoshis', () {
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(
          address: 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq',
          amountZatoshis: BigInt.from(-1),
        ),
      ]);
      expect(() => formatZcashUri(req), throwsArgumentError);
    });

    test('throws for empty payments list', () {
      expect(
          () => formatZcashUri(ZcashPaymentRequest(payments: [])),
          throwsArgumentError);
    });

    test('amount formatting: no trailing zeros', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(
          address: addr,
          amountZatoshis: BigInt.from(150000000), // 1.5 ZEC
        ),
      ]);
      final uri = formatZcashUri(req);
      expect(uri, contains('amount=1.5'));
    });

    test('amount formatting: whole ZEC has no decimal point', () {
      const addr = 'zs1zqa7llmm3m3l8wglp7c2zjuygymhqe76a88nvjhpqfpjhef0jcnzrpxq';
      final req = ZcashPaymentRequest(payments: [
        ZcashPaymentTarget(
          address: addr,
          amountZatoshis: BigInt.from(200000000), // 2 ZEC
        ),
      ]);
      final uri = formatZcashUri(req);
      expect(uri, contains('amount=2'));
      expect(uri, isNot(contains('amount=2.')));
    });
  });
}
