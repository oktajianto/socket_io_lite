import 'dart:async';

import 'packet.dart';
import 'parser.dart';
import 'transport/transport.dart';
import 'transport/transport_factory.dart';

/// The Engine.IO layer: it owns the [SocketTransport], performs the handshake,
/// keeps the connection alive with ping/pong, and surfaces the payloads of
/// Engine.IO `message` frames (the Socket.IO packets) to the layer above.
///
/// Targets Engine.IO v4, where the **server** sends `ping` and the client
/// replies with `pong`.
class EngineIo {
  EngineIo(this.uri, {this.headers, SocketTransport Function()? transportFactory})
    : _transportFactory = transportFactory ?? createTransport;

  /// The fully-built Engine.IO endpoint
  /// (`.../socket.io/?EIO=4&transport=websocket`).
  final Uri uri;

  /// Extra request headers (native only).
  final Map<String, dynamic>? headers;

  final SocketTransport Function() _transportFactory;

  SocketTransport? _transport;
  final StreamController<String> _messages = StreamController<String>.broadcast();
  final Completer<Handshake> _opened = Completer<Handshake>();
  final Completer<void> _done = Completer<void>();
  Timer? _pingTimeoutTimer;
  bool _closed = false;

  /// The handshake received from the server, once [open] completes.
  Handshake? handshake;

  /// Payloads of Engine.IO `message` frames — feed these to `SocketParser`.
  Stream<String> get messages => _messages.stream;

  /// Completes when the connection closes (cleanly, on error, or on a missed
  /// heartbeat).
  Future<void> get done => _done.future;

  /// Whether the underlying transport is currently open.
  bool get isConnected => !_closed && (_transport?.isConnected ?? false);

  /// Opens the transport and completes with the server [Handshake].
  ///
  /// Throws if the transport fails to connect, or if the connection closes
  /// before the handshake arrives.
  Future<Handshake> open() async {
    final transport = _transportFactory();
    _transport = transport;
    transport.messages.listen(
      _onData,
      onError: _onError,
      onDone: _onTransportDone,
      cancelOnError: false,
    );
    await transport.connect(uri, headers: headers);
    return _opened.future;
  }

  /// Wraps [socketIoPacket] in an Engine.IO `message` frame and sends it.
  void send(String socketIoPacket) {
    _sendFrame(EnginePacketType.message, socketIoPacket);
  }

  /// Closes the connection and releases resources. Idempotent.
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    _pingTimeoutTimer?.cancel();
    await _transport?.close(code, reason);
    _finish();
  }

  void _onData(String raw) {
    final EnginePacket packet;
    try {
      packet = EngineParser.decode(raw);
    } catch (e, st) {
      _messages.addError(e, st);
      return;
    }

    switch (packet.type) {
      case EnginePacketType.open:
        _handleOpen(packet.data);
      case EnginePacketType.ping:
        _sendFrame(EnginePacketType.pong);
        _resetPingTimeout();
      case EnginePacketType.message:
        _messages.add(packet.data);
      case EnginePacketType.close:
        close();
      case EnginePacketType.pong:
      case EnginePacketType.upgrade:
      case EnginePacketType.noop:
        break;
    }
  }

  void _handleOpen(String data) {
    try {
      handshake = EngineParser.parseHandshake(data);
    } catch (e) {
      if (!_opened.isCompleted) _opened.completeError(e);
      return;
    }
    _resetPingTimeout();
    if (!_opened.isCompleted) _opened.complete(handshake);
  }

  /// Resets the "no ping heard" watchdog. If a ping fails to arrive within
  /// `pingInterval + pingTimeout`, the connection is considered dead.
  void _resetPingTimeout() {
    final hs = handshake;
    if (hs == null) return;
    _pingTimeoutTimer?.cancel();
    _pingTimeoutTimer = Timer(
      Duration(milliseconds: hs.pingInterval + hs.pingTimeout),
      _onHeartbeatTimeout,
    );
  }

  void _onHeartbeatTimeout() {
    // The server went quiet; drop the connection.
    close(4000, 'ping timeout');
  }

  void _sendFrame(EnginePacketType type, [String data = '']) {
    _transport?.send(EngineParser.encode(type, data));
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_messages.isClosed) _messages.addError(error, stackTrace);
  }

  void _onTransportDone() {
    close();
  }

  void _finish() {
    if (!_opened.isCompleted) {
      _opened.completeError(
        StateError('Connection closed before the Engine.IO handshake'),
      );
    }
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) _messages.close();
  }

  /// Builds an Engine.IO endpoint from a base [url].
  ///
  /// Normalizes the scheme to `ws`/`wss`, sets [path] (default `/socket.io/`),
  /// and adds `EIO=4` + `transport=websocket` plus any [query] params.
  static Uri buildUri(
    String url, {
    String path = '/socket.io/',
    Map<String, String> query = const {},
  }) {
    final parsed = Uri.parse(url);
    final scheme = switch (parsed.scheme) {
      'https' || 'wss' => 'wss',
      _ => 'ws',
    };
    return parsed.replace(
      scheme: scheme,
      path: path,
      queryParameters: {
        'EIO': '4',
        'transport': 'websocket',
        ...query,
      },
    );
  }
}
