class PeerInfo {
  final String addr;
  final int? bytesSent;
  final int? bytesRecv;
  final int? connTime;
  final bool? inbound;
  final String? subver;

  const PeerInfo({
    required this.addr,
    this.bytesSent,
    this.bytesRecv,
    this.connTime,
    this.inbound,
    this.subver,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> json) => PeerInfo(
    addr: json['addr'] as String,
    bytesSent: json['bytessent'] != null
        ? (json['bytessent'] as num).toInt()
        : null,
    bytesRecv: json['bytesrecv'] != null
        ? (json['bytesrecv'] as num).toInt()
        : null,
    connTime: json['conntime'] != null
        ? (json['conntime'] as num).toInt()
        : null,
    inbound: json['inbound'] as bool?,
    subver: json['subver'] as String?,
  );

  @override
  String toString() => 'PeerInfo(addr: $addr, inbound: $inbound)';
}

class NetworkInfo {
  final int version;
  final String subversion;
  final int protocolVersion;
  final List<String> localAddresses;

  const NetworkInfo({
    required this.version,
    required this.subversion,
    required this.protocolVersion,
    required this.localAddresses,
  });

  factory NetworkInfo.fromJson(Map<String, dynamic> json) => NetworkInfo(
    version: (json['version'] as num).toInt(),
    subversion: json['subversion'] as String,
    protocolVersion: (json['protocolversion'] as num).toInt(),
    localAddresses: (json['localaddresses'] as List? ?? [])
        .map((e) => (e as Map<String, dynamic>)['address'] as String)
        .toList(),
  );

  @override
  String toString() =>
      'NetworkInfo(version: $version, subversion: $subversion)';
}
