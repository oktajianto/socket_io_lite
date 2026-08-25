import 'dart:convert';

/// Engine.IO packet types.
///
/// Every Engine.IO frame is prefixed with a single digit that identifies its
/// type. See the Engine.IO protocol (v4) for details.
enum EnginePacketType {
  open(0),
  close(1),
  ping(2),
  pong(3),
  message(4),
  upgrade(5),
  noop(6);

  const EnginePacketType(this.id);

  /// The numeric prefix used on the wire.
  final int id;

  /// Resolves a type from its numeric [id], or throws [FormatException].
  static EnginePacketType fromId(int id) {
    for (final t in values) {
      if (t.id == id) return t;
    }
    throw FormatException('Unknown Engine.IO packet type: $id');
  }
}

/// Socket.IO packet types.
///
/// A Socket.IO packet lives inside an Engine.IO [EnginePacketType.message]
/// frame. The digit right after the Engine.IO prefix identifies the type.
enum SocketPacketType {
  connect(0),
  disconnect(1),
  event(2),
  ack(3),
  connectError(4),
  binaryEvent(5),
  binaryAck(6);

  const SocketPacketType(this.id);

  /// The numeric prefix used on the wire.
  final int id;

  /// Whether this type carries binary attachments (not yet supported).
  bool get isBinary =>
      this == SocketPacketType.binaryEvent ||
      this == SocketPacketType.binaryAck;

  /// Resolves a type from its numeric [id], or throws [FormatException].
  static SocketPacketType fromId(int id) {
    for (final t in values) {
      if (t.id == id) return t;
    }
    throw FormatException('Unknown Socket.IO packet type: $id');
  }
}

/// A decoded Engine.IO frame: a [type] and its raw string [data] (may be empty).
class EnginePacket {
  const EnginePacket(this.type, [this.data = '']);

  final EnginePacketType type;
  final String data;

  @override
  bool operator ==(Object other) =>
      other is EnginePacket && other.type == type && other.data == data;

  @override
  int get hashCode => Object.hash(type, data);

  @override
  String toString() => 'EnginePacket(${type.name}, "$data")';
}

/// A decoded Socket.IO packet.
///
/// [data] is the JSON payload — an argument list for [SocketPacketType.event]
/// and [SocketPacketType.ack], or a map (or `null`) for
/// [SocketPacketType.connect] / [SocketPacketType.connectError].
class SocketPacket {
  const SocketPacket({
    required this.type,
    this.namespace = '/',
    this.data,
    this.ackId,
  });

  final SocketPacketType type;

  /// The namespace this packet targets. Defaults to the root namespace `/`.
  final String namespace;

  /// The JSON payload, or `null` when the packet carries none.
  final Object? data;

  /// The acknowledgement id, when the packet expects or carries an ack.
  final int? ackId;

  @override
  bool operator ==(Object other) =>
      other is SocketPacket &&
      other.type == type &&
      other.namespace == namespace &&
      other.ackId == ackId &&
      jsonEncode(other.data) == jsonEncode(data);

  @override
  int get hashCode => Object.hash(type, namespace, ackId, jsonEncode(data));

  @override
  String toString() =>
      'SocketPacket(${type.name}, ns: $namespace, ackId: $ackId, data: $data)';
}

/// The handshake payload sent by the server in the Engine.IO
/// [EnginePacketType.open] frame.
class Handshake {
  const Handshake({
    required this.sid,
    required this.pingInterval,
    required this.pingTimeout,
    this.upgrades = const [],
    this.maxPayload,
  });

  /// The session id assigned by the server.
  final String sid;

  /// Milliseconds between server pings.
  final int pingInterval;

  /// Milliseconds to wait for a ping before considering the connection dead.
  final int pingTimeout;

  /// Transports the server is willing to upgrade to.
  final List<String> upgrades;

  /// Maximum number of bytes per message, when provided by the server.
  final int? maxPayload;

  /// Parses a handshake from the decoded JSON of an [EnginePacketType.open].
  factory Handshake.fromJson(Map<String, dynamic> json) {
    return Handshake(
      sid: json['sid'] as String,
      pingInterval: (json['pingInterval'] as num).toInt(),
      pingTimeout: (json['pingTimeout'] as num).toInt(),
      upgrades:
          (json['upgrades'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      maxPayload: (json['maxPayload'] as num?)?.toInt(),
    );
  }

  @override
  String toString() =>
      'Handshake(sid: $sid, pingInterval: $pingInterval, '
      'pingTimeout: $pingTimeout, upgrades: $upgrades, maxPayload: $maxPayload)';
}
