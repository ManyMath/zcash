@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:zcash_flutter/zcash_flutter.dart';

// Trezor's vectors (MIT), shared with the crate's Rust test.
void main() {
  final bindings = ZcashFfiBindings.resolve(Platform.environment);
  final vectors =
      (jsonDecode(
                File(
                  'native/zcash-ffi/tests/fixtures/bip39_english_vectors.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, Object?>>();

  test('every vector round-trips entropy to phrase to seed', () {
    expect(vectors, hasLength(24));
    for (final v in vectors) {
      final phrase = nativeMnemonicFromEntropy(
        v['entropy']! as String,
        bindings: bindings,
      );
      expect(phrase, v['mnemonic']);
      final seed = nativeMnemonicToSeed(
        phrase,
        passphrase: v['passphrase']! as String,
        bindings: bindings,
      );
      expect(seed.seedHex, v['seed']);
      expect(seed.wordCount, phrase.split(' ').length);
    }
  });

  test('a typed phrase is normalized before it is checked', () {
    final v = vectors.first;
    final typed =
        '  ${(v['mnemonic']! as String).toUpperCase().replaceAll(' ', '   ')} ';
    expect(
      nativeMnemonicToSeed(
        typed,
        passphrase: 'TREZOR',
        bindings: bindings,
      ).seedHex,
      v['seed'],
    );
  });

  test('a new phrase has the requested length and derives a UFVK', () {
    final phrase = generateNativeMnemonic(bindings: bindings);
    expect(phrase.split(' '), hasLength(24));
    expect(
      generateNativeMnemonic(wordCount: 12, bindings: bindings).split(' '),
      hasLength(12),
    );
    expect(() => generateNativeMnemonic(wordCount: 13), throwsArgumentError);

    final seed = nativeMnemonicToSeed(phrase, bindings: bindings);
    final ufvk = deriveNativeAccountMetadata(
      seedHex: seed.seedHex,
      network: ZcashNetwork.mainnet,
      bindings: bindings,
    ).ufvk;
    expect(ufvk, startsWith('uview1'));
  });

  test('entropy comes from the Random it is given', () {
    expect(
      generateNativeMnemonic(random: Random(7), bindings: bindings),
      generateNativeMnemonic(random: Random(7), bindings: bindings),
    );
  });

  test('a bad phrase throws its category and never echoes the phrase', () {
    const good =
        'legal winner thank year wave sausage worth useful legal winner thank '
        'yellow';
    for (final (bad, category) in [
      ('legal winner thank', 'invalid_mnemonic_word_count'),
      (good.replaceAll('sausage', 'sausagf'), 'invalid_mnemonic_word'),
      (
        good.replaceAll('thank year', 'year thank'),
        'invalid_mnemonic_checksum',
      ),
    ]) {
      expect(isValidNativeMnemonic(bad, bindings: bindings), isFalse);
      expect(
        () => nativeMnemonicToSeed(bad, bindings: bindings),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(category),
              isNot(contains('sausag')),
              isNot(contains('winner')),
            ),
          ),
        ),
      );
    }
    expect(isValidNativeMnemonic(good, bindings: bindings), isTrue);
  });
}
