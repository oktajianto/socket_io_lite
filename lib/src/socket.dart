import 'dart:async';
import 'dart:math' as math;

import 'engine.dart';
import 'packet.dart';
import 'parser.dart';
import 'transport/transport.dart';

part 'manager.dart';

/// Handler for a Socket.IO event. [data] is the event's payload — the single
/// argument when the event carries one, a `List` when it carries several, or
/// `null` when it carries none.
typedef EventHandler = void Function(dynamic data);

/// Handler for lifecycle callbacks ([SocketIoLite.onConnect] /
/// [SocketIoLite.onDisconnect]).
typedef LifecycleHandler = void Function(dynamic data);

/// Handler for errors ([SocketIoLite.onError]).
typedef ErrorHandler = void Function(Object error);

/// Handler for reconnection progress ([SocketIoLite.onReconnect] /
/// [SocketIoLite.onReconnectAttempt]). [attempt] is the 1-based attempt count.
typedef ReconnectHandler = void Function(int attempt);

/// Handler for [SocketIoLite.onAny], receiving every event's name and payload.
typedef AnyEventHandler = void Function(String event, dynamic data);

/// Handler for [SocketIoLite.onAck]. Its return value (awaited if a `Future`)
/// is sent back to the server as the acknowledgement.
typedef AckEventHandler = FutureOr<Object?> Function(dynamic data);

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
/// A [SocketIoLite] is scoped to a single [namespace]. Additional namespaces on
/// the **same** underlying connection are obtained with [of]:
///
/// ```dart
/// final admin = socket.of('/admin'); // shares one WebSocket
/// ```
///
/// [emit] calls made before the connection is established are buffered and
/// flushed once the server acknowledges the connection. When the connection
/// drops, it reconnects automatically with exponential backoff (unless
/// disabled), re-running each namespace's CONNECT and keeping all listeners.
class SocketIoLite {
  SocketIoLite._(this._manager, this.namespace);

  final SocketManager _manager;

  /// The namespace this socket is attached to. Defaults to the root `/`.
  final String namespace;

  /// Auth payload sent with this namespace's CONNECT packet.
  Map<String, dynamic>? auth;

  /// How long [emitWithAck] waits for the server's acknowledgement before
  /// failing with a [TimeoutException]. `null` means wait indefinitely.
  Duration? ackTimeout;

  final Map<String, List<EventHandler>> _listeners = {};
  final List<AnyEventHandler> _anyListeners = [];
  final Map<String, AckEventHandler> _ackHandlers = {};
  final List<LifecycleHandler> _onConnect = [];
  final List<LifecycleHandler> _onDisconnect = [];
  final List<ErrorHandler> _onError = [];
  final List<ReconnectHandler> _onReconnect = [];
  final List<ReconnectHandler> _onReconnectAttempt = [];
  final List<void Function()> _onReconnectFailed = [];
  final List<String> _outbuffer = [];
  final Map<int, Completer<dynamic>> _pendingAcks = {};
  int _ackCounter = 0;

  bool _hasConnected = false;
  bool _disposed = false;
  bool _connected = false;

  /// The server-assigned session id for this namespace, once connected.
  String? id;

  /// Whether the Socket.IO connection is established (handshake + CONNECT).
  bool get connected => _connected;

  /// Opens a connection to [url] (e.g. `ws://localhost:3000` or
  /// `wss://example.com`) and returns a socket for [namespace].
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
    Duration? ackTimeout,
    bool reconnection = true,
    int? reconnectionAttempts,
    Duration reconnectionDelay = const Duration(seconds: 1),
    Duration reconnectionDelayMax = const Duration(seconds: 5),
    SocketTransport Function()? transportFactory,
  }) {
    final uri = EngineIo.buildUri(url, query: query);
    final manager = SocketManager(
      uri,
      headers: headers,
      transportFactory: transportFactory,
      reconnection: reconnection,
      reconnectionAttempts: reconnectionAttempts,
      reconnectionDelay: reconnectionDelay,
      reconnectionDelayMax: reconnectionDelayMax,
    );
    final socket = manager.socket(namespace, auth: auth, ackTimeout: ackTimeout);
    manager.open();
    return socket;
  }

  /// Returns a socket for [namespace] on the **same** underlying connection,
  /// creating it if needed. Reusing one connection across namespaces avoids a
  /// second handshake and heartbeat.
  SocketIoLite of(String namespace, {Map<String, dynamic>? auth}) =>
      _manager.socket(namespace, auth: auth);

  // ---- Incoming (called by the manager) -------------------------------------

  void _deliver(SocketPacket packet) {
    switch (packet.type) {
      case SocketPacketType.connect:
        _handleConnect(packet);
      case SocketPacketType.connectError:
        _dispatchError(_describeError(packet.data));
      case SocketPacketType.disconnect:
        _handleServerDisconnect();
      case SocketPacketType.event:
        _handleEvent(packet);
      case SocketPacketType.ack:
        _handleAck(packet);
      case SocketPacketType.binaryEvent:
      case SocketPacketType.binaryAck:
        break;
    }
  }

  void _sendConnect() {
    _manager.send(
      SocketParser.encode(
        SocketPacket(
          type: SocketPacketType.connect,
          namespace: namespace,
          data: auth,
        ),
      ),
    );
  }

  void _onManagerDisconnected() {
    _failPendingAcks(SocketException._('Connection closed while awaiting ack'));
    final wasConnected = _connected;
    _connected = false;
    if (wasConnected) _announceDisconnect();
  }

  void _notifyReconnectAttempt(int attempt) {
    for (final handler in List<ReconnectHandler>.from(_onReconnectAttempt)) {
      handler(attempt);
    }
  }

  void _notifyReconnectFailed() {
    for (final handler in List<void Function()>.from(_onReconnectFailed)) {
      handler();
    }
  }

  void _dispatchError(Object error) {
    for (final handler in List<ErrorHandler>.from(_onError)) {
      handler(error);
    }
  }

  void _handleConnect(SocketPacket packet) {
    final data = packet.data;
    if (data is Map && data['sid'] != null) {
      id = data['sid'].toString();
    }
    final wasReconnecting = _hasConnected;
    final attempt = _manager.reconnectAttempt;
    _manager.markConnected();
    _connected = true;

    _flush();
    for (final handler in List<LifecycleHandler>.from(_onConnect)) {
      handler(data);
    }
    if (wasReconnecting) {
      for (final handler in List<ReconnectHandler>.from(_onReconnect)) {
        handler(attempt);
      }
    }
    _hasConnected = true;
  }

  void _handleServerDisconnect() {
    _failPendingAcks(SocketException._('Server disconnected the namespace'));
    final wasConnected = _connected;
    _connected = false;
    _manager.removeSocket(namespace);
    if (wasConnected) _announceDisconnect();
  }

  void _handleAck(SocketPacket packet) {
    final id = packet.ackId;
    if (id == null) return;
    final completer = _pendingAcks.remove(id);
    if (completer == null || completer.isCompleted) return;
    completer.complete(_payloadOf(packet.data));
  }

  void _handleEvent(SocketPacket packet) {
    final data = packet.data;
    if (data is! List || data.isEmpty) return;
    final event = data.first.toString();
    final payload = _payloadOf(data.sublist(1));

    final handlers = _listeners[event];
    if (handlers != null) {
      for (final handler in List<EventHandler>.from(handlers)) {
        handler(payload);
      }
    }

    for (final handler in List<AnyEventHandler>.from(_anyListeners)) {
      handler(event, payload);
    }

    // If the server expects an acknowledgement and a responder is registered,
    // send its return value back under the same ack id.
    final ackId = packet.ackId;
    if (ackId != null) {
      final responder = _ackHandlers[event];
      if (responder != null) {
        Future.sync(() => responder(payload)).then((result) {
          _sendOrBuffer(
            SocketParser.encode(
              SocketPacket(
                type: SocketPacketType.ack,
                namespace: namespace,
                data: result == null ? const [] : [result],
                ackId: ackId,
              ),
            ),
          );
        });
      }
    }
  }

  // ---- Public API -----------------------------------------------------------

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

  /// Registers [handler] for [event], firing it at most once.
  void once(String event, EventHandler handler) {
    late EventHandler wrapper;
    wrapper = (data) {
      off(event, wrapper);
      handler(data);
    };
    on(event, wrapper);
  }

  /// Registers [handler] to receive every incoming event as `(name, payload)`.
  void onAny(AnyEventHandler handler) => _anyListeners.add(handler);

  /// Removes a specific catch-all [handler], or all of them when omitted.
  void offAny([AnyEventHandler? handler]) {
    if (handler == null) {
      _anyListeners.clear();
    } else {
      _anyListeners.remove(handler);
    }
  }

  /// Registers an acknowledgement responder for [event]: when the server emits
  /// [event] expecting an ack, [handler]'s return value is sent back.
  void onAck(String event, AckEventHandler handler) {
    _ackHandlers[event] = handler;
  }

  /// Removes the acknowledgement responder for [event].
  void offAck(String event) => _ackHandlers.remove(event);

  /// Emits [event] with zero or more positional argument payloads.
  ///
  /// Matches Socket.IO's variadic emit, so `emit('offer', id, sdp)` sends both
  /// arguments (`["offer", id, sdp]` on the wire). Buffered until connected.
  void emit(
    String event, [
    Object? arg1 = _unset,
    Object? arg2 = _unset,
    Object? arg3 = _unset,
    Object? arg4 = _unset,
    Object? arg5 = _unset,
  ]) {
    _sendOrBuffer(
      SocketParser.encode(
        SocketPacket(
          type: SocketPacketType.event,
          namespace: namespace,
          data: _collectArgs(event, arg1, arg2, arg3, arg4, arg5),
        ),
      ),
    );
  }

  /// Emits [event] with zero or more positional arguments and waits for the
  /// server's acknowledgement, completing with the acked value.
  ///
  /// Fails with a [TimeoutException] if [ackTimeout] is set and elapses, or
  /// with a [SocketException] if the socket closes while waiting.
  Future<dynamic> emitWithAck(
    String event, [
    Object? arg1 = _unset,
    Object? arg2 = _unset,
    Object? arg3 = _unset,
    Object? arg4 = _unset,
    Object? arg5 = _unset,
  ]) {
    final id = _ackCounter++;
    final completer = Completer<dynamic>();
    _pendingAcks[id] = completer;

    _sendOrBuffer(
      SocketParser.encode(
        SocketPacket(
          type: SocketPacketType.event,
          namespace: namespace,
          data: _collectArgs(event, arg1, arg2, arg3, arg4, arg5),
          ackId: id,
        ),
      ),
    );

    final timeout = ackTimeout;
    if (timeout != null) {
      Timer(timeout, () {
        final pending = _pendingAcks.remove(id);
        if (pending != null && !pending.isCompleted) {
          pending.completeError(
            TimeoutException('No ack for "$event"', timeout),
          );
        }
      });
    }

    return completer.future;
  }

  /// Registers a callback fired when the connection is established (on the
  /// first connect and after each reconnect).
  void onConnect(LifecycleHandler handler) => _onConnect.add(handler);

  /// Registers a callback fired when the connection is lost.
  void onDisconnect(LifecycleHandler handler) => _onDisconnect.add(handler);

  /// Registers a callback fired on transport or protocol errors.
  void onError(ErrorHandler handler) => _onError.add(handler);

  /// Registers a callback fired when a reconnection succeeds.
  void onReconnect(ReconnectHandler handler) => _onReconnect.add(handler);

  /// Registers a callback fired before each reconnection attempt.
  void onReconnectAttempt(ReconnectHandler handler) =>
      _onReconnectAttempt.add(handler);

  /// Registers a callback fired when reconnection gives up after exhausting
  /// `reconnectionAttempts`.
  void onReconnectFailed(void Function() handler) =>
      _onReconnectFailed.add(handler);

  /// Sends a DISCONNECT packet for this namespace, then tears it down. If this
  /// was the last namespace on the connection, the connection is closed too.
  Future<void> disconnect() async {
    if (_connected) {
      try {
        _manager.send(
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

  /// Detaches this namespace and releases its resources. Closes the underlying
  /// connection when it was the last namespace. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final wasConnected = _connected;
    _connected = false;
    _failPendingAcks(SocketException._('Socket disposed'));
    _manager.removeSocket(namespace);
    if (wasConnected) _announceDisconnect();
  }

  // ---- Internals ------------------------------------------------------------

  void _sendOrBuffer(String packet) {
    if (_connected) {
      _manager.send(packet);
    } else {
      _outbuffer.add(packet);
    }
  }

  void _flush() {
    if (_outbuffer.isEmpty) return;
    for (final packet in _outbuffer) {
      _manager.send(packet);
    }
    _outbuffer.clear();
  }

  /// Builds the wire args list `[event, ...provided]`, stopping at the first
  /// argument left at its [_unset] default. This lets an explicit `null` be
  /// distinguished from an omitted argument.
  static List<Object?> _collectArgs(
    String event,
    Object? a1,
    Object? a2,
    Object? a3,
    Object? a4,
    Object? a5,
  ) {
    final args = <Object?>[event];
    for (final a in [a1, a2, a3, a4, a5]) {
      if (identical(a, _unset)) break;
      args.add(a);
    }
    return args;
  }

  /// Normalizes an argument list into a single value, a list, or `null`.
  static dynamic _payloadOf(Object? data) {
    if (data is! List) return data;
    if (data.isEmpty) return null;
    return data.length == 1 ? data.first : data;
  }

  void _announceDisconnect() {
    for (final handler in List<LifecycleHandler>.from(_onDisconnect)) {
      handler(null);
    }
  }

  void _failPendingAcks(Object error) {
    if (_pendingAcks.isEmpty) return;
    for (final completer in _pendingAcks.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pendingAcks.clear();
  }

  Object _describeError(Object? data) {
    if (data is Map && data['message'] != null) {
      return SocketException._(data['message'].toString());
    }
    return SocketException._('connect_error: $data');
  }
}

/// Sentinel marking an omitted positional emit argument, so an explicit `null`
/// argument is not confused with "not provided".
class _UnsetArg {
  const _UnsetArg();
}

const Object _unset = _UnsetArg();

/// A Socket.IO protocol-level error (e.g. a CONNECT_ERROR from the server).
class SocketException implements Exception {
  SocketException._(this.message);

  /// A human-readable description of what went wrong.
  final String message;

  @override
  String toString() => 'SocketException: $message';
}
