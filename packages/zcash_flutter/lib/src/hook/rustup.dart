import 'dart:io';

Future<void> ensureRustTarget(String triple) async {
  final installed = await Process.run('rustup', [
    'target',
    'list',
    '--installed',
  ]);
  if (installed.exitCode == 0 &&
      (installed.stdout as String).split('\n').contains(triple)) {
    return;
  }
  final added = await Process.run('rustup', ['target', 'add', triple]);
  if (added.exitCode != 0) {
    throw StateError(
      'rustup target add $triple failed (${added.exitCode}): ${added.stderr}',
    );
  }
}
