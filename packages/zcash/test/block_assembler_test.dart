@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zcash/zcash.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexs(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

void main() {
  group('BlockAssembler', () {
    test('encodeVarint covers the four standard ranges', () {
      expect(_hexs(BlockAssembler.encodeVarint(0)), '00');
      expect(_hexs(BlockAssembler.encodeVarint(0xfc)), 'fc');
      expect(_hexs(BlockAssembler.encodeVarint(0xfd)), 'fdfd00');
      expect(_hexs(BlockAssembler.encodeVarint(1344)), 'fd4005');
      expect(_hexs(BlockAssembler.encodeVarint(0xffff)), 'fdffff');
      expect(_hexs(BlockAssembler.encodeVarint(0x10000)), 'fe00000100');
    });

    test('reverseHash is its own inverse', () {
      final h = _hex(
          '029f11d80ef9765602235e1bc9727e3eb6ba20839319f761fee920d63401e327');
      expect(
        BlockAssembler.reverseHash(BlockAssembler.reverseHash(h)),
        equals(h),
      );
    });

    test('buildHeaderPrefix is 108 bytes with correct field layout', () {
      final prev = _hex(
          '029f11d80ef9765602235e1bc9727e3eb6ba20839319f761fee920d63401e327');
      final merkle = _hex(
          '29b0a11f5984650e4f94cadb5fcef195038b66107456ba5be7667d02f6593ed0');
      final commit = _hex(
          'd895b50a5ceb6dff7da902ffb6ece3b6a448612e5985e1e9ee72d9006e0e84b0');

      final prefix = BlockAssembler.buildHeaderPrefix(
        version: 4,
        prevBlockHash: BlockAssembler.reverseHash(prev),
        merkleRoot: BlockAssembler.reverseHash(merkle),
        blockCommitments: BlockAssembler.reverseHash(commit),
        time: 1296694002,
        bits: 0x200ca63f,
      );
      expect(prefix.length, 108);
      expect(prefix.sublist(0, 4), [4, 0, 0, 0]);
      // bits little-endian (0x200ca63f -> 3f a6 0c 20)
      expect(prefix.sublist(104, 108), [0x3f, 0xa6, 0x0c, 0x20]);
    });

    test('buildHeader produces 1487 bytes', () {
      final prefix = Uint8List(108);
      final nonce = Uint8List(32);
      final solution = Uint8List(1344);
      final header =
          BlockAssembler.buildHeader(headerPrefix: prefix, nonce: nonce, solution: solution);
      expect(header.length, 1487);
      // Solution-size varint occupies bytes 140..143: 0xfd 0x40 0x05
      expect(header.sublist(140, 143), [0xfd, 0x40, 0x05]);
    });

    test('computeMerkleRoot of a single txid equals reversed display hash', () {
      const txid =
          '29b0a11f5984650e4f94cadb5fcef195038b66107456ba5be7667d02f6593ed0';
      final root = BlockAssembler.computeMerkleRoot([txid]);
      expect(_hexs(root), _hexs(BlockAssembler.reverseHash(_hex(txid))));
    });

    test('computeMerkleRoot of two txids matches direct sha256d', () {
      const a =
          '29b0a11f5984650e4f94cadb5fcef195038b66107456ba5be7667d02f6593ed0';
      const b =
          'f0e33cfec824944388eaf56634ca0fd5ab6678072b06a006f584bc60abd6f869';
      final ar = BlockAssembler.reverseHash(_hex(a));
      final br = BlockAssembler.reverseHash(_hex(b));
      final concat = Uint8List(64)
        ..setRange(0, 32, ar)
        ..setRange(32, 64, br);
      final once = sha256.convert(concat).bytes;
      final twice = sha256.convert(once).bytes;

      final root = BlockAssembler.computeMerkleRoot([a, b]);
      expect(_hexs(root), _hexs(twice));
    });

    test('assembleBlockHex prefixes a varint(1) for a coinbase-only block', () {
      final header = Uint8List(1487);
      const coinbase = 'aabbccdd';
      final hex = BlockAssembler.assembleBlockHex(
        header: header,
        coinbaseHex: coinbase,
      );
      expect(hex.length, 2974 + 2 + coinbase.length);
      expect(hex.substring(2974, 2976), '01');
      expect(hex.substring(2976), coinbase);
    });
  });
}
