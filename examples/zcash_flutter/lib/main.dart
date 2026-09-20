import 'package:flutter/material.dart';

import 'device_check.dart';

void main() => runApp(const ZcashDeviceCheckApp());

class ZcashDeviceCheckApp extends StatelessWidget {
  const ZcashDeviceCheckApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'zcash_ffi device check',
    theme: ThemeData(colorSchemeSeed: const Color(0xFFF4B728)),
    home: const _CheckPage(),
  );
}

class _CheckPage extends StatefulWidget {
  const _CheckPage();

  @override
  State<_CheckPage> createState() => _CheckPageState();
}

class _CheckPageState extends State<_CheckPage> {
  final _check = DeviceCheck(lightwalletd: 'zec.rocks:443');
  final _lines = <String>[];
  var _running = false;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _lines.clear();
    });
    void log(String line) => setState(() => _lines.add(line));
    try {
      log('zcash-ffi ${_check.nativeVersion()}');
      final caps = _check.capabilities().toJson()['capabilities'] as Map;
      log('ironwood_note_discovery: ${caps['ironwood_note_discovery']}');
      log('ironwood_transaction_build: ${caps['ironwood_transaction_build']}');
      final ufvk = _check.freshMainnetUfvk();
      log('derived a mainnet UFVK (${ufvk.length} chars)');
      log('syncing ${_check.syncBlocks} mainnet blocks…');
      log('mainnet sync: ${await _check.mainnetSync()}');
    } on Object catch (e) {
      log('failed: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('zcash_ffi device check')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [for (final line in _lines) Text(line)],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _running ? null : _run,
      label: Text(_running ? 'Running…' : 'Run'),
    ),
  );
}
