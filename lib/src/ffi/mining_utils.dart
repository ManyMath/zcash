import 'dart:convert';
import 'dart:typed_data';

import 'zcash_ffi_bindings.dart';

class EquihashSolution {
  final Uint8List nonce;

  final Uint8List solution;

  const EquihashSolution({required this.nonce, required this.solution});
}

/// [headerPrefix] is the 108 header bytes before the nonce.
EquihashSolution solveEquihash(Uint8List headerPrefix) {
  final raw = ZcashFfiBindings.instance.solveEquihash(headerPrefix);
  final json = jsonDecode(raw) as Map<String, dynamic>;
  if (json.containsKey('error')) {
    throw StateError('Equihash solver: ${json['error']}');
  }
  final nonce = _hexDecode(json['nonce'] as String);
  final solution = _hexDecode(json['solution'] as String);
  if (nonce.length != 32) {
    throw StateError('expected 32-byte nonce, got ${nonce.length}');
  }
  if (solution.length != 1344) {
    throw StateError('expected 1344-byte solution, got ${solution.length}');
  }
  return EquihashSolution(nonce: nonce, solution: solution);
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
