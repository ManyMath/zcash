import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class BlockAssembler {
  /// Hashes are internal byte order; RPC gives displayed (reversed) order,
  /// so pass those through [reverseHash] first.
  static Uint8List buildHeaderPrefix({
    required int version,
    required Uint8List prevBlockHash,
    required Uint8List merkleRoot,
    required Uint8List blockCommitments,
    required int time,
    required int bits,
  }) {
    _check32('prevBlockHash', prevBlockHash);
    _check32('merkleRoot', merkleRoot);
    _check32('blockCommitments', blockCommitments);

    final out = Uint8List(108);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, version, Endian.little);
    out.setRange(4, 36, prevBlockHash);
    out.setRange(36, 68, merkleRoot);
    out.setRange(68, 100, blockCommitments);
    bd.setUint32(100, time, Endian.little);
    bd.setUint32(104, bits, Endian.little);
    return out;
  }

  static Uint8List buildHeader({
    required Uint8List headerPrefix,
    required Uint8List nonce,
    required Uint8List solution,
  }) {
    if (headerPrefix.length != 108) {
      throw ArgumentError('headerPrefix must be 108 bytes');
    }
    _check32('nonce', nonce);
    if (solution.length != 1344) {
      throw ArgumentError('solution must be 1344 bytes');
    }

    final solSizeVarint = encodeVarint(solution.length);
    final out = Uint8List(108 + 32 + solSizeVarint.length + 1344);
    var off = 0;
    out.setRange(off, off + 108, headerPrefix);
    off += 108;
    out.setRange(off, off + 32, nonce);
    off += 32;
    out.setRange(off, off + solSizeVarint.length, solSizeVarint);
    off += solSizeVarint.length;
    out.setRange(off, off + 1344, solution);
    return out;
  }

  static Uint8List encodeVarint(int value) {
    if (value < 0) {
      throw ArgumentError('varint value must be non-negative');
    }
    if (value < 0xfd) {
      return Uint8List.fromList([value]);
    }
    if (value <= 0xffff) {
      final b = Uint8List(3);
      b[0] = 0xfd;
      ByteData.sublistView(b).setUint16(1, value, Endian.little);
      return b;
    }
    if (value <= 0xffffffff) {
      final b = Uint8List(5);
      b[0] = 0xfe;
      ByteData.sublistView(b).setUint32(1, value, Endian.little);
      return b;
    }
    final b = Uint8List(9);
    b[0] = 0xff;
    ByteData.sublistView(b).setUint64(1, value, Endian.little);
    return b;
  }

  static String assembleBlockHex({
    required Uint8List header,
    required String coinbaseHex,
    List<String> otherTxHex = const [],
  }) {
    final txCount = 1 + otherTxHex.length;
    final buf = BytesBuilder()
      ..add(header)
      ..add(encodeVarint(txCount))
      ..add(_hexDecode(coinbaseHex));
    for (final tx in otherTxHex) {
      buf.add(_hexDecode(tx));
    }
    return _hexEncode(buf.toBytes());
  }

  static Uint8List computeMerkleRoot(List<String> txHashesDisplayOrder) {
    if (txHashesDisplayOrder.isEmpty) {
      throw ArgumentError('at least one txid (coinbase) is required');
    }
    var level = txHashesDisplayOrder
        .map((h) => reverseHash(_hexDecode(h)))
        .toList();
    while (level.length > 1) {
      final next = <Uint8List>[];
      for (var i = 0; i < level.length; i += 2) {
        final left = level[i];
        final right = (i + 1 < level.length) ? level[i + 1] : level[i];
        final concat = Uint8List(64)
          ..setRange(0, 32, left)
          ..setRange(32, 64, right);
        next.add(_sha256d(concat));
      }
      level = next;
    }
    return level.first;
  }

  static Uint8List reverseHash(Uint8List hash) {
    _check32('hash', hash);
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = hash[31 - i];
    }
    return out;
  }

  static Uint8List _sha256d(Uint8List data) {
    final once = sha256.convert(data).bytes;
    final twice = sha256.convert(once).bytes;
    return Uint8List.fromList(twice);
  }

  static void _check32(String name, Uint8List bytes) {
    if (bytes.length != 32) {
      throw ArgumentError('$name must be 32 bytes (got ${bytes.length})');
    }
  }
}

Uint8List _hexDecode(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('odd-length hex string');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
