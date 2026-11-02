@TestOn('vm')
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:zcash_ffi/src/ffi/native_result.dart';

void main() {
  group('native result parser', () {
    test('accepts versioned success envelopes with legacy payload keys', () {
      final json = parseNativeJsonObject(
        jsonEncode({
          nativeResultVersionKey: 1,
          nativeResultStatusKey: nativeResultOkStatus,
          'ufvk': 'uviewtest1example',
        }),
        context: 'seed_to_account_ufvk',
      );

      expect(json[nativeResultVersionKey], 1);
      expect(
        requiredNativeStringFromObject(
          json,
          'ufvk',
          context: 'seed_to_account_ufvk',
        ),
        'uviewtest1example',
      );
    });

    test('accepts legacy success objects without envelope fields', () {
      final json = parseNativeJsonObject(
        '{"address":"tmExample"}',
        context: 'transparent_address',
      );

      expect(
        requiredNativeStringFromObject(
          json,
          'address',
          context: 'transparent_address',
        ),
        'tmExample',
      );
    });

    test('throws categorized redacted errors with block context', () {
      const secret = 'uviewtest-secret-that-must-not-leak';

      expect(
        () => parseNativeJsonObject(
          jsonEncode({
            nativeResultVersionKey: 1,
            nativeResultStatusKey: nativeResultErrorStatus,
            'category': 'invalid_ufvk',
            'error': 'invalid UFVK $secret',
            'block_index': 2,
            'height': 99,
          }),
          context: 'scan_compact_blocks',
          redactSensitive: [secret],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('scan_compact_blocks failed'),
              contains('[invalid_ufvk]'),
              contains('<redacted>'),
              contains('block_index=2'),
              contains('height=99'),
              isNot(contains(secret)),
            ),
          ),
        ),
      );
    });

    test('malformed JSON errors do not echo payload contents', () {
      expect(
        () => parseNativeJsonObject(
          'not-json-secret',
          context: 'seed_to_account_ufvk',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('malformed JSON'),
              isNot(contains('not-json-secret')),
            ),
          ),
        ),
      );
    });
  });
}
