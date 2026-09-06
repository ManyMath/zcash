@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:zcash_ffi/zcash_ffi.dart';

void main() {
  late Directory dir;
  late ZcashWalletStateFile file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zcash_wallet_state_');
    file = ZcashWalletStateFile('${dir.path}/wallet.json');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ZcashWalletSyncState walletAt(int height) => ZcashWalletSyncState.atBirthday(
    cursor: ZcashLightwalletdSyncCursor.origin(height: height),
    accountFingerprint: 'state-file-test',
  );

  test('nothing saved loads as null', () async {
    expect(await file.load(), isNull);
  });

  test('a saved wallet loads back at the same position', () async {
    await file.save(walletAt(3500000));
    final loaded = await file.load();
    expect(loaded!.cursor.nextHeight, 3500000);
    expect(loaded.accountFingerprint, 'state-file-test');
  });

  test('a later save replaces the earlier one', () async {
    await file.save(walletAt(100));
    await file.save(walletAt(200));
    expect((await file.load())!.cursor.nextHeight, 200);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('a save interrupted before its rename leaves the old state', () async {
    await file.save(walletAt(100));
    File('${file.path}.tmp').writeAsStringSync('{"sync_state_ver');
    expect((await file.load())!.cursor.nextHeight, 100);
    await file.save(walletAt(300));
    expect((await file.load())!.cursor.nextHeight, 300);
  });

  test('a corrupt file is an error, not a new wallet', () async {
    File(file.path).writeAsStringSync('{"truncated": ');
    await expectLater(file.load(), throwsA(isA<FormatException>()));
    File(file.path).writeAsStringSync('[1, 2]');
    await expectLater(file.load(), throwsA(isA<FormatException>()));
  });

  test('a document the state refuses stays refused', () async {
    File(file.path).writeAsStringSync('{"version": 99}');
    await expectLater(file.load(), throwsA(isA<ZcashModelException>()));
  });

  test('delete removes the state and any leftover temporary file', () async {
    await file.save(walletAt(100));
    File('${file.path}.tmp').writeAsStringSync('partial');
    await file.delete();
    expect(await file.load(), isNull);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });
}
