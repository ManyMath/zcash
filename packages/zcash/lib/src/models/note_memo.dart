import 'dart:convert';
import 'dart:typed_data';

import 'spend.dart';

enum ZcashMemoPool {
  sapling('sapling'),
  orchard('orchard'),
  ironwood('ironwood');

  const ZcashMemoPool(this.jsonValue);

  final String jsonValue;
}

class ZcashNoteMemo {
  const ZcashNoteMemo._({
    required this.pool,
    required this.outputIndex,
    required this.valueZatoshis,
    required this.bytes,
  });

  final String pool;

  final int outputIndex;

  final int valueZatoshis;

  final Uint8List? bytes;

  bool get isEmpty => bytes == null;

  /// ZIP 302: a first byte of `0xF5` or above is reserved or the empty memo;
  /// only `0x00`–`0xF4` is UTF-8 text.
  String? get text {
    final memo = bytes;
    if (memo == null || memo.isEmpty) {
      return null;
    }
    if (memo.first >= 0xF5) {
      return null;
    }
    var end = memo.length;
    while (end > 0 && memo[end - 1] == 0) {
      end -= 1;
    }
    if (end == 0) {
      return '';
    }
    try {
      return const Utf8Decoder(
        allowMalformed: false,
      ).convert(memo.sublist(0, end));
    } on FormatException {
      return null;
    }
  }

  static ZcashNoteMemo? fromJson(
    Map<String, Object?> json, {
    String context = 'read_note_memo',
  }) {
    final outcome = json['outcome'];
    if (outcome == 'not_for_this_key') {
      return null;
    }
    if (outcome != 'decrypted') {
      throw ZcashModelException('$context returned an unknown outcome');
    }
    final pool = json['pool'];
    if (pool is! String) {
      throw ZcashModelException('$context returned no pool');
    }
    final index = json['output_index'];
    final value = json['value_zatoshis'];
    if (index is! num || value is! num) {
      throw ZcashModelException(
        '$context returned no output index or no note value',
      );
    }
    final memoHex = json['memo'];
    if (memoHex != null && memoHex is! String) {
      throw ZcashModelException('$context returned a malformed memo');
    }
    return ZcashNoteMemo._(
      pool: pool,
      outputIndex: index.toInt(),
      valueZatoshis: value.toInt(),
      bytes: memoHex == null ? null : _decodeHex(memoHex as String, context),
    );
  }

  static Uint8List _decodeHex(String hex, String context) {
    if (hex.length.isOdd) {
      throw ZcashModelException('$context returned an odd-length memo');
    }
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw ZcashModelException('$context returned a non-hex memo');
      }
      bytes[i] = byte;
    }
    return bytes;
  }
}
