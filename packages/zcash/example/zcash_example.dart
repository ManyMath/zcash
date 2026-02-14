import 'package:zcash/zcash.dart';

void main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : 'localhost';
  final port = args.length > 1 ? int.parse(args[1]) : 8232;

  final zebra = ZebraClient(host: host, port: port);

  try {
    print('Connecting to Zebra at $host:$port ...\n');

    final info = await zebra.getInfo();
    print('Node: ${info.subversion}  build: ${info.build}');

    final chain = await zebra.getBlockchainInfo();
    print('Chain:  ${chain.chain}');
    print('Height: ${chain.blocks}');
    print('Tip:    ${chain.bestBlockHash}\n');

    print('Network upgrades:');
    for (final entry in chain.upgrades.entries) {
      final u = entry.value;
      print('  ${u.name.padRight(16)} height=${u.activationHeight}  '
          'status=${u.status}');
    }
    print('');

    final tip = await zebra.getBestBlockHeightAndHash();
    final block = await zebra.getBlock(tip.hash);
    print('Latest block:  height=${block.height}  txs=${block.transactions.length}');

    final mempool = await zebra.getRawMempool();
    print('Mempool:       ${mempool.length} unconfirmed transaction(s)');

    final saplingTree = await zebra.getTreeState(tip.hash);
    if (saplingTree.sapling?.finalState != null) {
      final root = saplingTree.sapling!.finalState!;
      print('Sapling root:  ${root.substring(0, 16)}...');
    }
    if (saplingTree.orchard?.finalState != null) {
      final root = saplingTree.orchard!.finalState!;
      print('Orchard root:  ${root.substring(0, 16)}...');
    }
  } on ZebraRpcException catch (e) {
    print('RPC error: $e');
  } finally {
    zebra.close();
  }
}
