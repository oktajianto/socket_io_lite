import 'dart:async';

import 'engine.dart';
import 'packet.dart';
import 'parser.dart';
import 'transport/transport.dart';

/// Handler for a Socket.IO event. [data] is the event's payload — the single
/// argument when the event carries one, a `List` when it carries several, or
/// `null` when it carries none.
typedef EventHandler = void Function(dynamic data);

/// Handler for lifecycle callbacks ([SocketIoLite.onConnect] /
/// [SocketIoLite.onDisconnect]).
typedef LifecycleHandler = void Function(dynamic data);

/// Handler for errors ([SocketIoLite.onError]).
typedef ErrorHandler = void Function(Object error);

/// A lightweight, zero-dependency Socket.IO client (Engine.IO v4 / Socket.IO
/// v4).
///
/// ```dart
/// final socket = SocketIoLite.connect('ws://localhost:3000');
/// socket.onConnect((_) => print('connected'));
/// socket.on('chat:message', (data) => print(data));
/// socket.emit('chat:message', {'text': 'halo'});
/// ```
///
/// [emit] calls made before the connection is established are buffered and
/// flushed once the server acknowledges the connection.
class SocketIoLite {
  SocketIoLite._(this._engine, this.namespace);

  final EngineIo _engine;

  /// The namespace this socket is attached to. Defaults to the root `/`.
  final String namespace;

  final Map<String, List<EventHandler>> _listeners = {};
  final List<LifecycleHandler> _onConnect = [];
  final List<LifecycleHandler> _onDisconnect = [];
  final List<ErrorHandler> _onError = [];
  final List<String> _outbuffer = [];

  bool _connected = false;
  bool _disposed = false;
  bool _disconnectAnnounced = false;

  /// The server-assigned session id for this namespace, once connected.
  String? id;

  /// Whether the Socket.IO connection is established (handshake + CONNECT).
  bool get connected => _connected;

  /// Opens a connection to [url] (e.g. `ws://localhost:3000` or
  /// `wss://example.com`).
  ///
  /// The returned socket connects in the background; use [onConnect] to learn
  /// when it is ready. Optional [auth] is sent with the CONNECT packet, [query]
  /// is appended to the handshake URL, and [headers] are extra request headers
  /// (native only).
  static SocketIoLite connect(
    String url, {
    String namespace = '/',
    Map<String, dynamic>? auth,
    Map<String, String> query = const {},
    Map<String, dynamic>? headers,
    SocketTransport Function()? transportFactory,
  }) {
    final uri = EngineIo.buildUri(url, query: query);
    final engine = EngineIo(
      uri,
      headers: headers,
      transportFactory: transportFactory,
    );
    final socket = SocketIoLite._(engine, namespace);
    socket._start(auth);
    return socket;
  }

  Future<void> _start(Map<String, dynamic>? auth) async {
    _engine.messages.listen(
      _onEngineMessage,
      onError: (Object e, StackTrace _) => _fireError(e),
      cancelOnError: false,
    );
    unawaited(_engine.done.then((_) => _handleClosed()));

    try {
      await _engine.open();
    } catch (e) {
      _fireError(e);
      return;
    }

    // Request the namespace connection.
    _engine.send(
      SocketParser.encode(
        SocketPacket(
          type: SocketPacketType.connect,
          namespace: namespace,
          data: auth,
        ),
      ),
    );
  }

  void _onEngineMessage(String payload) {
    final SocketPacket packet;
    try {
      packet = SocketParser.decode(payload);
    } catch (e) {
      _fireError(e);
      return;
    }

    // Ignore packets addressed to a different namespace.
    if (packet.namespace != namespace) return;

    switch (packet.type) {
      case SocketPacketType.connect:
        _handleConnect(packet);
      case SocketPacketType.connectError:
        _fireError(_describeError(packet.data));
      case SocketPacketType.disconnect:
        _handleClosed();
      case SocketPacketType.event:
        _handleEvent(packet);
      case SocketPacketType.ack:
        // Acknowledgements are handled in a later phase.
        break;
      case SocketPacketType.binaryEvent:
      case SocketPacketType.binaryAck:
        break;
    }
  }

  void _handleConnect(SocketPacket packet) {
    final data = packet.data;
    if (data is Map && data['sid'] != null) {
      id = data['sid'].toString();
    }
    _connected = true;
    _flush();
    for (final handler in List<LifecycleHandler>.from(_onConnect)) {
      handler(data);
    }
  }

  void _handleEvent(SocketPacket packet) {
    final data = packet.data;
    if (data is! List || data.isEmpty) return;
    final event = data.first.toString();
    final args = data.sublist(1);
    final payload = args.isEmpty
        ? null
        : (args.length == 1 ? args.first : args);

    final handlers = _listeners[event];
    if (handlers == null) return;
    for (final handler in List<EventHandler>.from(handlers)) {
      handler(payload);
    }
  }

  /// Registers [handler] for [event]. Multiple handlers per event are allowed.
  void on(String event, EventHandler handler) {
    (_listeners[event] ??= []).add(handler);
  }

  /// Removes a specific [handler] for [event], or all handlers for [event] when
  /// [handler] is omitted.
  void off(String event, [EventHandler? handler]) {
    if (handler == null) {
      _listeners.remove(event);
    } else {
      _listeners[event]?.remove(handler);
    }
  }

  /// Emits [event] with an optional [data] payload. Buffered until connected.
  void emit(String event, [Object? data]) {
    final args = data == null ? [event] : [event, data];
    _sendOrBuffer(
      SocketParser.encode(
        SocketPacket(
          type: SocketPacketType.event,
          namespace: namespace,
          data: args,
        ),
      ),
    );
  }

  /// Registers a callback fired when the connection is established.
  void onConnect(LifecycleHandler handler) => _onConnect.add(handler);

  /// Registers a callback fired when the connection is lost.
  void onDisconnect(LifecycleHandler handler) => _onDisconnect.add(handler);

  /// Registers a callback fired on transport or protocol errors.
  void onError(ErrorHandler handler) => _onError.add(handler);

  /// Sends a DISCONNECT packet, then tears down the connection.
  Future<void> disconnect() async {
    if (_connected) {
      try {
        _engine.send(
          SocketParser.encode(
            SocketPacket(
              type: SocketPacketType.disconnect,
              namespace: namespace,
            ),
          ),
        );
      } catch (_) {
        // Best effort; we are closing anyway.
      }
    }
    await dispose();
  }

  /// Closes the connection and releases all resources. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _engine.close();
  }

  void _sendOrBuffer(String packet) {
    if (_connected) {
      _engine.send(packet);
    } else {
      _outbuffer.add(packet);
    }
  }

  void _flush() {
    if (_outbuffer.isEmpty) return;
    for (final packet in _outbuffer) {
      _engine.send(packet);
    }
    _outbuffer.clear();
  }

  void _handleClosed() {
    final wasConnected = _connected;
    _connected = false;
    if (_disconnectAnnounced) return;
    _disconnectAnnounced = true;
    // Announce a disconnect only if we ever connected, or the user explicitly
    // disposed. A failure before connecting is reported via onError instead.
    if (wasConnected || _disposed) {
      for (final handler in List<LifecycleHandler>.from(_onDisconnect)) {
        handler(null);
      }
    }
  }

  void _fireError(Object error) {
    for (final handler in List<ErrorHandler>.from(_onError)) {
      handler(error);
    }
  }

  Object _describeError(Object? data) {
    if (data is Map && data['message'] != null) {
      return SocketException._(data['message'].toString());
    }
    return SocketException._('connect_error: $data');
  }
}

/// A Socket.IO protocol-level error (e.g. a CONNECT_ERROR from the server).
class SocketException implements Exception {
  SocketException._(this.message);

  /// A human-readable description of what went wrong.
  final String message;

  @override
  String toString() => 'SocketException: $message';
}
