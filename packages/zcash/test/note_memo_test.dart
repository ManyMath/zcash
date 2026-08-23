import 'dart:convert';

import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

Map<String, Object?> _decrypted({
  String? memoHex,
  bool isEmptyMemo = false,
  String pool = 'ironwood',
  int outputIndex = 0,
  int valueZatoshis = 58000,
}) => {
  'ffi_result_version': 1,
  'status': 'ok',
  'outcome': 'decrypted',
  'pool': pool,
  'output_index': outputIndex,
  'value_zatoshis': valueZatoshis,
  'is_empty_memo': isEmptyMemo,
  'memo': memoHex,
};

void main() {
  group('ZcashNoteMemo', () {
    test('carries the bytes and binds them to the note they came with', () {
      final memo = ZcashNoteMemo.fromJson(_decrypted(memoHex: '68656c6c6f'))!;

      expect(memo.bytes, utf8.encode('hello'));
      expect(memo.text, 'hello');
      expect(memo.isEmpty, isFalse);
      expect(memo.pool, 'ironwood');
      expect(memo.outputIndex, 0);
      expect(memo.valueZatoshis, 58000);
    });

    test('not_for_this_key is an answer, not an exception', () {
      final memo = ZcashNoteMemo.fromJson({
        'ffi_result_version': 1,
        'status': 'ok',
        'outcome': 'not_for_this_key',
        'pool': 'sapling',
        'output_index': 3,
      });

      expect(memo, isNull);
    });

    test('the empty memo is absence, never 512 bytes of padding', () {
      final memo = ZcashNoteMemo.fromJson(
        _decrypted(memoHex: null, isEmptyMemo: true),
      )!;

      expect(memo.isEmpty, isTrue);
      expect(memo.bytes, isNull);
      expect(memo.text, isNull);
      expect(memo.valueZatoshis, 58000);
    });

    test('a memo that is not text has bytes and no text', () {
      final reserved = ZcashNoteMemo.fromJson(
        _decrypted(memoHex: 'f501020304'),
      )!;

      expect(reserved.bytes, hasLength(5));
      expect(reserved.text, isNull);
      expect(reserved.isEmpty, isFalse);
    });

    test('invalid UTF-8 is not decoded lossily', () {
      final memo = ZcashNoteMemo.fromJson(_decrypted(memoHex: '00ff'))!;

      expect(memo.bytes, [0x00, 0xff]);
      expect(memo.text, isNull);
    });

    test('the trailing padding of a memo field is not part of the message', () {
      final padded = utf8.encode('hello') + List<int>.filled(507, 0);
      final memo = ZcashNoteMemo.fromJson(
        _decrypted(
          memoHex: padded
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
        ),
      )!;

      expect(memo.text, 'hello');
      expect(
        memo.bytes,
        hasLength(512),
        reason: 'the bytes are still the field as it was sent',
      );
    });

    test('a malformed result is refused rather than half-read', () {
      expect(
        () => ZcashNoteMemo.fromJson({'outcome': 'something_else'}),
        throwsA(isA<ZcashModelException>()),
      );
      expect(
        () => ZcashNoteMemo.fromJson(_decrypted(memoHex: 'abc')),
        throwsA(isA<ZcashModelException>()),
        reason: 'an odd-length memo hex is not half a memo',
      );
      expect(
        () => ZcashNoteMemo.fromJson(_decrypted(memoHex: 'zz')),
        throwsA(isA<ZcashModelException>()),
      );
    });

    test('the pool is named by the caller and answered for alone', () {
      expect(ZcashMemoPool.values.map((p) => p.jsonValue), [
        'sapling',
        'orchard',
        'ironwood',
      ]);
    });
  });
}
