@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('code_assets remains resolvable with Stack Wallet native packages', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains("code_assets: '>=1.2.1 <3.0.0'"));
  });
}
