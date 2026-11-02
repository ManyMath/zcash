import 'dart:convert';
import 'dart:io';

import 'package:zcash_flutter/zcash_flutter.dart';

// Bytes 0x00..0x3f: a deterministic dev seed, not a published vector.
const _seedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const _network = 'regtest';

const _usage = '''
zcash_cli — native-backed zcash_flutter developer CLI

Usage: dart run zcash_cli <command> [options]

Commands:
  capabilities   Print the native zcash-ffi version and compiled capability
                 matrix (default feature/build gates surfaced verbatim).
  address        Decode/validate an address into network, receiver type, pool,
                 and receiver presence: address <addr> [--network <net>].
  derive         Print deterministic key-derivation output for a seed:
                 derive [--seed <hex>] [--network <net>]. Defaults to a fixed
                 development seed on regtest.
  scan           Scan compact blocks from a JSON file and print a redacted
                 summary: scan <input.json> [--network <net>]. The file holds
                 {"ufvk": ..., "network"?: ..., "blocks": [{"data": <base64>,
                 "height"?: N}, ...]}.
  help           Print this message.

Options:
  --json         Emit machine-readable JSON instead of labeled lines.
  --network      Network label (main|test|regtest). Default: main for address,
                 regtest for derive.
  --seed         Development-only seed hex for derive (default: fixed test seed).
''';

void main(List<String> args) {
  final command = args.isEmpty ? 'help' : args.first;
  final options = args.skip(1).toList();
  final asJson = options.contains('--json');

  try {
    switch (command) {
      case 'capabilities':
        _runCapabilities(asJson: asJson);
      case 'address':
        _runAddress(options, asJson: asJson);
      case 'derive':
        _runDerive(options, asJson: asJson);
      case 'scan':
        _runScan(options, asJson: asJson);
      case 'help':
      case '--help':
      case '-h':
        stdout.write(_usage);
      default:
        stderr.writeln('zcash_cli: unknown command "$command"');
        stderr.write(_usage);
        exitCode = 2;
    }
  } catch (error, stackTrace) {
    stderr.writeln('zcash_cli $command failure: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

void _runCapabilities({required bool asJson}) {
  final version = zcashNativeVersion();
  final capabilities = zcashNativeCapabilities();

  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'zcash_ffi_version': version, ...capabilities.toJson()}),
    );
    return;
  }

  stdout.writeln('zcash_ffi_version: $version');
  for (final capability in NativeCapability.values) {
    stdout.writeln(
      'capability ${capability.jsonKey}: '
      '${capabilities.statusFor(capability).name}',
    );
  }
}

void _runAddress(List<String> options, {required bool asJson}) {
  final network = _optionValue(options, '--network') ?? 'main';
  final positional = _positionalArgs(
    options,
    valueOptions: const {'--network'},
  );
  if (positional.isEmpty) {
    throw const FormatException(
      'address command requires an <address> argument',
    );
  }
  final address = positional.first;

  final metadata = zcashNativeDecodeAddress(address: address, network: network);

  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(metadata.toJson()),
    );
    return;
  }

  final receivers = metadata.receivers;
  stdout.writeln('network: ${metadata.network.name}');
  stdout.writeln('receiver_type: ${metadata.receiverType.name}');
  stdout.writeln('pool: ${metadata.pool.name}');
  stdout.writeln('receiver_transparent: ${receivers.transparent}');
  stdout.writeln('receiver_sapling: ${receivers.sapling}');
  stdout.writeln('receiver_orchard: ${receivers.orchard}');
}

List<String> _positionalArgs(
  List<String> options, {
  required Set<String> valueOptions,
}) {
  final positional = <String>[];
  for (var i = 0; i < options.length; i++) {
    final option = options[i];
    if (valueOptions.contains(option)) {
      i++;
      continue;
    }
    if (option.startsWith('--')) {
      continue;
    }
    positional.add(option);
  }
  return positional;
}

String? _optionValue(List<String> options, String name) {
  for (var i = 0; i < options.length; i++) {
    final option = options[i];
    if (option == name && i + 1 < options.length) {
      return options[i + 1];
    }
    final prefix = '$name=';
    if (option.startsWith(prefix)) {
      return option.substring(prefix.length);
    }
  }
  return null;
}

void _runDerive(List<String> options, {required bool asJson}) {
  final seedHex = _optionValue(options, '--seed') ?? _seedHex;
  final network = _optionValue(options, '--network') ?? _network;

  final version = zcashNativeVersion();
  final ufvk = zcashNativeSeedToAccountUfvk(seedHex: seedHex, network: network);
  final address = zcashNativeUfvkToAddress(ufvk: ufvk, network: network);
  final transparentXpub = zcashNativeSeedToTransparentXpub(
    seedHex: seedHex,
    network: network,
  );
  final transparentAddress = zcashNativeTransparentAddress(
    xpub: transparentXpub,
    network: network,
  );

  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'zcash_ffi_version': version,
        'network': network,
        'ufvk': ufvk,
        'unified_address': address.ua,
        'sapling': address.sapling,
        'orchard': address.orchard,
        'transparent': address.transparent,
        'transparent_xpub': transparentXpub,
        'transparent_address': transparentAddress,
      }),
    );
    return;
  }

  stdout.writeln('zcash_ffi_version: $version');
  stdout.writeln('network: $network');
  stdout.writeln('ufvk: $ufvk');
  stdout.writeln('unified_address: ${address.ua}');
  stdout.writeln('sapling: ${address.sapling ?? '<absent>'}');
  stdout.writeln('orchard: ${address.orchard ?? '<absent>'}');
  stdout.writeln('transparent: ${address.transparent ?? '<absent>'}');
  stdout.writeln('transparent_xpub: $transparentXpub');
  stdout.writeln('transparent_address: $transparentAddress');
}

void _runScan(List<String> options, {required bool asJson}) {
  final positional = _positionalArgs(
    options,
    valueOptions: const {'--network'},
  );
  if (positional.isEmpty) {
    throw const FormatException(
      'scan command requires an <input.json> file argument',
    );
  }
  final file = File(positional.first);
  if (!file.existsSync()) {
    throw FormatException('scan input file not found: ${file.path}');
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException {
    throw const FormatException('scan input file is not valid JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('scan input must be a JSON object');
  }

  final ufvk = decoded['ufvk'];
  if (ufvk is! String || ufvk.isEmpty) {
    throw const FormatException(
      'scan input requires a non-empty "ufvk" string',
    );
  }
  final network =
      _optionValue(options, '--network') ??
      (decoded['network'] is String ? decoded['network'] as String : _network);

  final rawBlocks = decoded['blocks'] ?? const <Object?>[];
  if (rawBlocks is! List) {
    throw const FormatException('scan input "blocks" must be a JSON array');
  }
  final blocks = <CompactBlockScanInput>[];
  for (final entry in rawBlocks) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException('each scan block must be a JSON object');
    }
    final data = entry['data'];
    if (data is! String) {
      throw const FormatException(
        'each scan block requires a base64 "data" string',
      );
    }
    final height = entry['height'];
    blocks.add(
      CompactBlockScanInput.fromBytes(
        base64Decode(data),
        height: height is num ? height.toInt() : null,
      ),
    );
  }

  final result = zcashNativeScanCompactBlocks(
    ufvk: ufvk,
    network: network,
    blocks: blocks,
  );

  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'network': network,
        'scanned_blocks': result.scannedBlocks,
        'discovered_notes': result.discoveredNotes,
        'total_value': result.totalValue,
        'orchard_actions': result.orchardActions,
        'diagnostics_count': result.diagnostics.length,
      }),
    );
    return;
  }

  stdout.writeln('network: $network');
  stdout.writeln('scanned_blocks: ${result.scannedBlocks}');
  stdout.writeln('discovered_notes: ${result.discoveredNotes}');
  stdout.writeln('total_value: ${result.totalValue}');
  stdout.writeln('orchard_actions: ${result.orchardActions ?? 0}');
  stdout.writeln('diagnostics_count: ${result.diagnostics.length}');
}
