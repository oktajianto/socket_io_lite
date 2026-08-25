import 'dart:async';
import 'dart:math' as math;

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
/// [emit] calls made before the connection is established are buffered and
/// flushed once the server acknowledges the connection. When the connection
/// drops, the socket reconnects automatically with exponential backoff (unless
/// disabled), re-running the namespace CONNECT and keeping all listeners.
class SocketIoLite {
  SocketIoLite._(this._uri, this.namespace);

  final Uri _uri;

  /// The namespace this socket is attached to. Defaults to the root `/`.
  final String namespace;

  // Connection configuration.
  Map<String, dynamic>? _auth;
  Map<String, dynamic>? _headers;
  SocketTransport Function()? _transportFactory;

  /// Whether to reconnect automatically after a drop. Default `true`.
  bool reconnection = true;

  /// Maximum reconnection attempts before giving up. `null` means unlimited.
  int? reconnectionAttempts;

  /// Base backoff delay; doubles each attempt up to [reconnectionDelayMax].
  Duration reconnectionDelay = const Duration(seconds: 1);

  /// Upper bound for the backoff delay.
  Duration reconnectionDelayMax = const Duration(seconds: 5);

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

  EngineIo? _engine;
  StreamSubscription<String>? _engineSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _hasConnected = false;
  bool _closedByUser = false;
  bool _connected = false;

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
    Duration? ackTimeout,
    bool reconnection = true,
    int? reconnectionAttempts,
    Duration reconnectionDelay = const Duration(seconds: 1),
    Duration reconnectionDelayMax = const Duration(seconds: 5),
    SocketTransport Function()? transportFactory,
  }) {
    final uri = EngineIo.buildUri(url, query: query);
    final socket = SocketIoLite._(uri, namespace)
      .._auth = auth
      .._headers = headers
      .._transportFactory = transportFactory
      ..ackTimeout = ackTimeout
      ..reconnection = reconnection
      ..reconnectionAttempts = reconnectionAttempts
      ..reconnectionDelay = reconnectionDelay
      ..reconnectionDelayMax = reconnectionDelayMax;
    socket._openConnection();
    return socket;
  }

  Future<void> _openConnection() async {
    final engine = EngineIo(
      _uri,
      headers: _headers,
      transportFactory: _transportFactory,
    );
    _engine = engine;
    _engineSub = engine.messages.listen(
      _onEngineMessage,
      onError: (Object e, StackTrace _) => _fireError(e),
      cancelOnError: false,
    );
    unawaited(engine.done.then((_) => _handleEngineDown(engine)));

    try {
      await engine.open();
    } catch (e) {
      _fireError(e);
      _handleEngineDown(engine);
      return;
    }

    // Request the namespace connection.
    engine.send(
      SocketParser.encode(
        SocketPacket(
          type: SocketPacketType.connect,
          namespace: namespace,
          data: _auth,
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
        _handleEngineDown(_engine);
      case SocketPacketType.event:
        _handleEvent(packet);
      case SocketPacketType.ack:
        _handleAck(packet);
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
    _reconnectTimer?.cancel();
    _connected = true;

    final wasReconnecting = _hasConnected;
    final attempt = _reconnectAttempt;
    _reconnectAttempt = 0;

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

  /// Emits [event] with an optional [data] payload and waits for the server's
  /// acknowledgement, completing with the acked value.
  ///
  /// Fails with a [TimeoutException] if [ackTimeout] is set and elapses, or
  /// with a [SocketException] if the socket closes while waiting.
  Future<dynamic> emitWithAck(String event, [Object? data]) {
    final id = _ackCounter++;
    final completer = Completer<dynamic>();
    _pendingAcks[id] = completer;

    final args = data == null ? [event] : [event, data];
    _sendOrBuffer(
      SocketParser.encode(
        SocketPacket(
          type: SocketPacketType.event,
          namespace: namespace,
          data: args,
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
  /// [reconnectionAttempts].
  void onReconnectFailed(void Function() handler) =>
      _onReconnectFailed.add(handler);

  /// Sends a DISCONNECT packet, then tears down the connection (no reconnect).
  Future<void> disconnect() async {
    final engine = _engine;
    if (_connected && engine != null) {
      try {
        engine.send(
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

  /// Closes the connection, cancels any pending reconnect, and releases all
  /// resources. Idempotent.
  Future<void> dispose() async {
    if (_closedByUser) return;
    _closedByUser = true;
    _reconnectTimer?.cancel();

    final engine = _engine;
    _engine = null;
    await _engineSub?.cancel();
    _engineSub = null;
    await engine?.close();

    _failPendingAcks(SocketException._('Socket disposed'));
    if (_connected) {
      _connected = false;
      _announceDisconnect();
    }
  }

  void _sendOrBuffer(String packet) {
    if (_connected) {
      _engine?.send(packet);
    } else {
      _outbuffer.add(packet);
    }
  }

  void _flush() {
    if (_outbuffer.isEmpty) return;
    for (final packet in _outbuffer) {
      _engine?.send(packet);
    }
    _outbuffer.clear();
  }

  /// Normalizes an argument list into a single value, a list, or `null`.
  static dynamic _payloadOf(Object? data) {
    if (data is! List) return data;
    if (data.isEmpty) return null;
    return data.length == 1 ? data.first : data;
  }

  /// Handles the current [engine] going down: cleans up, announces a
  /// disconnect, and schedules a reconnect. Ignores stale engines.
  void _handleEngineDown(EngineIo? engine) {
    if (engine == null || !identical(engine, _engine)) return;
    _engine = null;
    _engineSub?.cancel();
    _engineSub = null;

    _failPendingAcks(SocketException._('Connection closed while awaiting ack'));

    final wasConnected = _connected;
    _connected = false;
    if (wasConnected) _announceDisconnect();

    if (_closedByUser) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!reconnection || _closedByUser) return;

    final max = reconnectionAttempts;
    if (max != null && _reconnectAttempt >= max) {
      for (final handler in List<void Function()>.from(_onReconnectFailed)) {
        handler();
      }
      return;
    }

    _reconnectAttempt++;
    final backoff =
        reconnectionDelay.inMilliseconds * math.pow(2, _reconnectAttempt - 1);
    final delayMs =
        math.min(backoff, reconnectionDelayMax.inMilliseconds.toDouble())
            .toInt();

    for (final handler in List<ReconnectHandler>.from(_onReconnectAttempt)) {
      handler(_reconnectAttempt);
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), _openConnection);
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
