@TestOn('vm')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zcash_ffi/src/ffi/native_string.dart';

void main() {
  group('native string ownership', () {
    test('takes and frees repeated successful string pointers', () {
      final freed = <Pointer<Utf8>>[];

      for (final value in ['first', 'second', 'third']) {
        final ptr = value.toNativeUtf8();
        final taken = takeNativeString(
          ptr,
          free: (ptr) {
            freed.add(ptr);
            calloc.free(ptr);
          },
          context: 'test-native',
        );

        expect(taken, value);
      }

      expect(freed, hasLength(3));
    });

    test('rejects null string pointers before free', () {
      var freed = false;

      expect(
        () => takeNativeString(
          nullptr,
          free: (_) {
            freed = true;
          },
          context: 'test-native',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'test-native returned a null string pointer',
          ),
        ),
      );
      expect(freed, isFalse);
    });

    test('frees pointers when UTF-8 conversion throws', () {
      final ptr = calloc<Uint8>(2).cast<Utf8>();
      ptr.cast<Uint8>()[0] = 0xff;
      ptr.cast<Uint8>()[1] = 0;
      var freed = false;

      expect(
        () => takeNativeString(
          ptr,
          free: (ptr) {
            freed = true;
            calloc.free(ptr);
          },
          context: 'test-native',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(freed, isTrue);
    });
  });
}
