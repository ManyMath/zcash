import '../grpc/compact_formats.pb.dart' as compact;
import '../grpc/service.pb.dart' as lwd;
import 'shielded_capability.dart';
import 'tree_state.dart' as json_rpc;

enum OrchardParsedDataSurface {
  compactBlockActions,
  compactBlockChainMetadata,
  lightwalletdTreeState,
  jsonRpcTreeState,
  subtreeRootsArg,
  subtreeRoot,
}

class OrchardParsedOnlyClassification {
  const OrchardParsedOnlyClassification({
    required this.surface,
    required this.present,
    required this.count,
    required this.description,
    this.boundary = _defaultBoundary,
  });

  static const _defaultBoundary =
      'Parsed-only Orchard model data; not Orchard note discovery, wallet history, or wallet send support.';

  final OrchardParsedDataSurface surface;
  final bool present;
  final int count;
  final String description;
  final String boundary;

  CapabilityStatus get status => CapabilityStatus.parsedOnly;

  bool get impliesWalletSupport => false;

  @override
  String toString() =>
      'OrchardParsedOnlyClassification(surface: $surface, present: $present, count: $count, description: $description)';
}

class OrchardDataClassifier {
  const OrchardDataClassifier._();

  static OrchardParsedOnlyClassification compactBlockActions(
    compact.CompactBlock block,
  ) {
    final actionCount = block.vtx.fold<int>(
      0,
      (count, tx) => count + tx.actions.length,
    );
    return OrchardParsedOnlyClassification(
      surface: OrchardParsedDataSurface.compactBlockActions,
      present: actionCount > 0,
      count: actionCount,
      description: actionCount > 0
          ? 'CompactBlock contains $actionCount Orchard action(s).'
          : 'CompactBlock contains no Orchard actions.',
    );
  }

  static OrchardParsedOnlyClassification compactTxActions(
    compact.CompactTx tx,
  ) {
    final actionCount = tx.actions.length;
    return OrchardParsedOnlyClassification(
      surface: OrchardParsedDataSurface.compactBlockActions,
      present: actionCount > 0,
      count: actionCount,
      description: actionCount > 0
          ? 'CompactTx contains $actionCount Orchard action(s).'
          : 'CompactTx contains no Orchard actions.',
    );
  }

  static OrchardParsedOnlyClassification chainMetadata(
    compact.ChainMetadata? metadata,
  ) {
    final present = metadata?.hasOrchardCommitmentTreeSize() ?? false;
    final size = metadata?.orchardCommitmentTreeSize;
    return OrchardParsedOnlyClassification(
      surface: OrchardParsedDataSurface.compactBlockChainMetadata,
      present: present,
      count: present ? 1 : 0,
      description: present
          ? 'ChainMetadata contains orchardCommitmentTreeSize=$size.'
          : 'ChainMetadata has no orchardCommitmentTreeSize field.',
    );
  }

  static OrchardParsedOnlyClassification lightwalletdTreeState(
    lwd.TreeState treeState,
  ) {
    final present =
        treeState.hasOrchardTree() && treeState.orchardTree.trim().isNotEmpty;
    return OrchardParsedOnlyClassification(
      surface: OrchardParsedDataSurface.lightwalletdTreeState,
      present: present,
      count: present ? 1 : 0,
      description: present
          ? 'lightwalletd TreeState contains orchardTree (${treeState.orchardTree.length} chars).'
          : 'lightwalletd TreeState has no non-empty orchardTree field.',
    );
  }

  static OrchardParsedOnlyClassification jsonRpcTreeState(
    json_rpc.TreeState treeState,
  ) {
    final finalState = treeState.orchard?.finalState;
    final present = finalState != null && finalState.trim().isNotEmpty;
    return OrchardParsedOnlyClassification(
      surface: OrchardParsedDataSurface.jsonRpcTreeState,
      present: present,
      count: present ? 1 : 0,
      description: present
          ? 'JSON-RPC TreeState contains Orchard finalState=$finalState.'
          : 'JSON-RPC TreeState has no non-empty Orchard finalState.',
    );
  }

  static OrchardParsedOnlyClassification subtreeRootsArg(
    lwd.GetSubtreeRootsArg arg,
  ) {
    final present =
        arg.hasShieldedProtocol() &&
        arg.shieldedProtocol == lwd.ShieldedProtocol.orchard;
    return OrchardParsedOnlyClassification(
      surface: OrchardParsedDataSurface.subtreeRootsArg,
      present: present,
      count: present ? 1 : 0,
      description: present
          ? 'GetSubtreeRootsArg requests Orchard subtree roots from startIndex=${arg.startIndex}, maxEntries=${arg.maxEntries}.'
          : 'GetSubtreeRootsArg does not request Orchard subtree roots.',
    );
  }

  static OrchardParsedOnlyClassification subtreeRoot(lwd.SubtreeRoot root) {
    final present =
        root.rootHash.isNotEmpty ||
        root.completingBlockHash.isNotEmpty ||
        root.hasCompletingBlockHeight();
    return OrchardParsedOnlyClassification(
      surface: OrchardParsedDataSurface.subtreeRoot,
      present: present,
      count: present ? 1 : 0,
      description: present
          ? 'SubtreeRoot shape contains rootHashBytes=${root.rootHash.length}, completingBlockHashBytes=${root.completingBlockHash.length}, height=${root.completingBlockHeight}.'
          : 'SubtreeRoot shape contains no root fields.',
    );
  }
}
