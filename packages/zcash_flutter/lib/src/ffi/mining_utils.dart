import 'dart:typed_data';

import 'native_result.dart';
import 'zcash_ffi_bindings.dart';

class EquihashSolution {
  final Uint8List nonce;

  final Uint8List solution;

  const EquihashSolution({required this.nonce, required this.solution});
}

EquihashSolution solveEquihash(Uint8List headerPrefix) {
  final raw = ZcashFfiBindings.instance.solveEquihash(headerPrefix);
  final json = parseNativeJsonObject(raw, context: 'solve_equihash');
  final nonce = _hexDecode(
    requiredNativeStringFromObject(json, 'nonce', context: 'solve_equihash'),
  );
  final solution = _hexDecode(
    requiredNativeStringFromObject(json, 'solution', context: 'solve_equihash'),
  );
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
