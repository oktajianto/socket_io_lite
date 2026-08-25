import 'dart:convert';

import 'packet.dart';

/// Encodes and decodes Engine.IO frames — the outer transport layer.
///
/// An Engine.IO frame is a single type digit followed by its (possibly empty)
/// string payload, e.g. `2` (ping), `3` (pong), or `4{"...":...}` (a message
/// carrying a Socket.IO packet).
class EngineParser {
  const EngineParser._();

  /// Encodes an Engine.IO frame into its wire string.
  static String encode(EnginePacketType type, [String data = '']) {
    return '${type.id}$data';
  }

  /// Decodes a raw Engine.IO frame.
  ///
  /// Throws [FormatException] if [raw] is empty or its prefix is not a valid
  /// Engine.IO type.
  static EnginePacket decode(String raw) {
    if (raw.isEmpty) {
      throw const FormatException('Empty Engine.IO frame');
    }
    final id = int.tryParse(raw[0]);
    if (id == null) {
      throw FormatException('Invalid Engine.IO type prefix: "${raw[0]}"');
    }
    return EnginePacket(EnginePacketType.fromId(id), raw.substring(1));
  }

  /// Parses the [Handshake] from an [EnginePacketType.open] frame's data.
  static Handshake parseHandshake(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    return Handshake.fromJson(json);
  }
}

/// Encodes and decodes Socket.IO packets — the payload of an Engine.IO
/// [EnginePacketType.message] frame.
///
/// Wire shape: `<type>[<namespace>,][<ackId>][<jsonPayload>]`, e.g.
/// `2["chat",{"x":1}]` (event), `2/admin,3["hi"]` (event on `/admin`, ack id
/// 3), or `0{"sid":"abc"}` (connect with a session id).
///
/// Binary packets ([SocketPacketType.binaryEvent] /
/// [SocketPacketType.binaryAck]) are not yet supported and throw
/// [UnsupportedError] on decode.
class SocketParser {
  const SocketParser._();

  /// Encodes a Socket.IO packet into its wire string (without the Engine.IO
  /// message prefix).
  static String encode(SocketPacket packet) {
    if (packet.type.isBinary) {
      throw UnsupportedError('Binary Socket.IO packets are not yet supported');
    }
    final buffer = StringBuffer()..write(packet.type.id);

    // Namespace, when not the default root. Always terminated by a comma.
    if (packet.namespace.isNotEmpty && packet.namespace != '/') {
      buffer
        ..write(packet.namespace)
        ..write(',');
    }

    // Acknowledgement id, when present.
    if (packet.ackId != null) {
      buffer.write(packet.ackId);
    }

    // JSON payload, when present.
    if (packet.data != null) {
      buffer.write(jsonEncode(packet.data));
    }

    return buffer.toString();
  }

  /// Decodes a Socket.IO packet string (without the Engine.IO message prefix).
  ///
  /// Throws [FormatException] on malformed input and [UnsupportedError] for
  /// binary packet types.
  static SocketPacket decode(String str) {
    if (str.isEmpty) {
      throw const FormatException('Empty Socket.IO packet');
    }

    var i = 0;

    // 1) Packet type.
    final typeId = int.tryParse(str[i]);
    if (typeId == null) {
      throw FormatException('Invalid Socket.IO type prefix: "${str[i]}"');
    }
    final type = SocketPacketType.fromId(typeId);
    i++;

    if (type.isBinary) {
      throw UnsupportedError('Binary Socket.IO packets are not yet supported');
    }

    // 2) Namespace, when the next char starts one. Runs up to the first comma;
    //    if there is no comma, the whole remainder is the namespace (e.g.
    //    "0/admin"). The separator comma always precedes any JSON payload, so
    //    a comma inside the payload is never mistaken for it.
    var namespace = '/';
    if (i < str.length && str[i] == '/') {
      final comma = str.indexOf(',', i);
      if (comma == -1) {
        namespace = str.substring(i);
        i = str.length;
      } else {
        namespace = str.substring(i, comma);
        i = comma + 1;
      }
    }

    // 3) Acknowledgement id: the run of digits before the JSON payload.
    final digitsStart = i;
    while (i < str.length && _isDigit(str.codeUnitAt(i))) {
      i++;
    }
    final ackId =
        i > digitsStart ? int.parse(str.substring(digitsStart, i)) : null;

    // 4) JSON payload: whatever remains.
    Object? data;
    if (i < str.length) {
      data = jsonDecode(str.substring(i));
    }

    return SocketPacket(
      type: type,
      namespace: namespace,
      data: data,
      ackId: ackId,
    );
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
}
