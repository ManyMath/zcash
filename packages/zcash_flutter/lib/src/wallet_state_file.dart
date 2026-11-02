import 'dart:convert';
import 'dart:io';

import 'package:zcash/zcash.dart';

class ZcashWalletStateFile {
  ZcashWalletStateFile(this.path);

  final String path;

  String get _temporaryPath => '$path.tmp';

  Future<ZcashWalletSyncState?> load() async {
    final file = File(path);
    if (!await file.exists()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw FormatException(
        'wallet state at $path is not JSON (${e.message}); refusing to treat '
        'it as a new wallet',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException(
        'wallet state at $path is not a JSON object; refusing to treat it as '
        'a new wallet',
      );
    }
    return ZcashWalletSyncState.fromJson(decoded);
  }

  Future<void> save(ZcashWalletSyncState state) async {
    final temporary = File(_temporaryPath);
    await temporary.parent.create(recursive: true);
    final sink = temporary.openWrite();
    try {
      sink.write(jsonEncode(state.toJson()));
      await sink.flush();
    } finally {
      await sink.close();
    }
    await temporary.rename(path);
  }

  Future<void> delete() async {
    for (final file in [File(path), File(_temporaryPath)]) {
      if (await file.exists()) await file.delete();
    }
  }
}
