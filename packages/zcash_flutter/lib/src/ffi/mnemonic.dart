import 'dart:math';

import 'native_result.dart';
import 'zcash_ffi_bindings.dart';

class ZcashMnemonicSeed {
  const ZcashMnemonicSeed({required this.seedHex, required this.wordCount});

  final String seedHex;
  final int wordCount;
}

const _entropyBytesForWords = {12: 16, 15: 20, 18: 24, 21: 28, 24: 32};

String generateNativeMnemonic({
  int wordCount = 24,
  ZcashFfiBindings? bindings,
  Random? random,
}) {
  final bytes = _entropyBytesForWords[wordCount];
  if (bytes == null) {
    throw ArgumentError.value(
      wordCount,
      'wordCount',
      'must be one of ${_entropyBytesForWords.keys.join(', ')}',
    );
  }
  final source = random ?? Random.secure();
  final entropyHex = [
    for (var i = 0; i < bytes; i++)
      source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
  return nativeMnemonicFromEntropy(entropyHex, bindings: bindings);
}

/// [entropyHex] is 16, 20, 24, 28 or 32 bytes.
String nativeMnemonicFromEntropy(
  String entropyHex, {
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  const context = 'mnemonic_from_entropy';
  final json = parseNativeJsonObject(
    ffi.mnemonicFromEntropyRaw(entropyHex),
    context: context,
    redactSensitive: [entropyHex],
  );
  return requiredNativeStringFromObject(json, 'phrase', context: context);
}

ZcashMnemonicSeed nativeMnemonicToSeed(
  String phrase, {
  String passphrase = '',
  ZcashFfiBindings? bindings,
}) {
  final ffi = bindings ?? ZcashFfiBindings.instance;
  final normalized = phrase
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .join(' ');
  final secrets = [phrase, normalized, if (passphrase.isNotEmpty) passphrase];
  const context = 'mnemonic_to_seed';
  final json = parseNativeJsonObject(
    ffi.mnemonicToSeedRaw(normalized, passphrase),
    context: context,
    redactSensitive: secrets,
  );
  return ZcashMnemonicSeed(
    seedHex: requiredNativeStringFromObject(json, 'seed', context: context),
    wordCount: json['word_count'] as int,
  );
}

bool isValidNativeMnemonic(String phrase, {ZcashFfiBindings? bindings}) {
  try {
    nativeMnemonicToSeed(phrase, bindings: bindings);
    return true;
  } on StateError {
    return false;
  }
}
