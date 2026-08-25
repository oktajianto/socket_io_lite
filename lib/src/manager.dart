part of 'socket.dart';

/// Owns a single Engine.IO connection and multiplexes one or more
/// [SocketIoLite] namespaces over it.
///
/// Responsibilities: opening the transport, dispatching incoming packets to the
/// right namespace, and driving automatic reconnection. It is created for you
/// by [SocketIoLite.connect] and is not part of the public API.
class SocketManager {
  SocketManager(
    this.uri, {
    this.headers,
    this.transportFactory,
    this.reconnection = true,
    this.reconnectionAttempts,
    this.reconnectionDelay = const Duration(seconds: 1),
    this.reconnectionDelayMax = const Duration(seconds: 5),
  });

  final Uri uri;
  final Map<String, dynamic>? headers;
  final SocketTransport Function()? transportFactory;
  final bool reconnection;
  final int? reconnectionAttempts;
  final Duration reconnectionDelay;
  final Duration reconnectionDelayMax;

  final Map<String, SocketIoLite> _sockets = {};
  EngineIo? _engine;
  StreamSubscription<String>? _engineSub;
  Timer? _reconnectTimer;
  bool _engineConnected = false;
  bool _closed = false;
  bool _opening = false;

  /// The current 1-based reconnection attempt count (0 while connected).
  int reconnectAttempt = 0;

  /// Returns the socket for [namespace], creating it if needed. A brand-new
  /// socket sends its CONNECT immediately when the connection is already up.
  SocketIoLite socket(
    String namespace, {
    Map<String, dynamic>? auth,
    Duration? ackTimeout,
  }) {
    final existing = _sockets[namespace];
    if (existing != null) return existing;

    final s =
        SocketIoLite._(this, namespace)
          ..auth = auth
          ..ackTimeout = ackTimeout;
    _sockets[namespace] = s;
    if (_engineConnected) s._sendConnect();
    return s;
  }

  /// Removes a namespace; closes the connection when it was the last one.
  void removeSocket(String namespace) {
    _sockets.remove(namespace);
    if (_sockets.isEmpty) close();
  }

  /// Sends a raw Socket.IO packet string over the Engine.IO connection.
  void send(String socketIoPacket) => _engine?.send(socketIoPacket);

  /// Resets the reconnection counter after a successful (re)connect.
  void markConnected() {
    reconnectAttempt = 0;
    _reconnectTimer?.cancel();
  }

  /// Opens (or reopens) the Engine.IO transport.
  Future<void> open() async {
    if (_opening || _closed) return;
    _opening = true;

    final engine = EngineIo(
      uri,
      headers: headers,
      transportFactory: transportFactory,
    );
    _engine = engine;
    _engineSub = engine.messages.listen(
      _onMessage,
      onError: (Object e, StackTrace _) => _dispatchError(e),
      cancelOnError: false,
    );
    unawaited(engine.done.then((_) => _onEngineDown(engine)));

    try {
      await engine.open();
    } catch (e) {
      _opening = false;
      _dispatchError(e);
      _onEngineDown(engine);
      return;
    }

    _opening = false;
    _engineConnected = true;
    // The Engine.IO handshake is up; ask every namespace to CONNECT.
    for (final s in List<SocketIoLite>.from(_sockets.values)) {
      s._sendConnect();
    }
  }

  void _onMessage(String payload) {
    final SocketPacket packet;
    try {
      packet = SocketParser.decode(payload);
    } catch (e) {
      _dispatchError(e);
      return;
    }
    _sockets[packet.namespace]?._deliver(packet);
  }

  void _onEngineDown(EngineIo engine) {
    if (!identical(engine, _engine)) return;
    _engine = null;
    _engineSub?.cancel();
    _engineSub = null;
    _engineConnected = false;

    for (final s in List<SocketIoLite>.from(_sockets.values)) {
      s._onManagerDisconnected();
    }

    if (_closed) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!reconnection || _closed || _sockets.isEmpty) return;

    final max = reconnectionAttempts;
    if (max != null && reconnectAttempt >= max) {
      for (final s in List<SocketIoLite>.from(_sockets.values)) {
        s._notifyReconnectFailed();
      }
      return;
    }

    reconnectAttempt++;
    final backoff =
        reconnectionDelay.inMilliseconds * math.pow(2, reconnectAttempt - 1);
    final delayMs =
        math
            .min(backoff, reconnectionDelayMax.inMilliseconds.toDouble())
            .toInt();

    for (final s in List<SocketIoLite>.from(_sockets.values)) {
      s._notifyReconnectAttempt(reconnectAttempt);
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), open);
  }

  void _dispatchError(Object error) {
    for (final s in List<SocketIoLite>.from(_sockets.values)) {
      s._dispatchError(error);
    }
  }

  /// Closes the connection and cancels any pending reconnect. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reconnectTimer?.cancel();
    final engine = _engine;
    _engine = null;
    await _engineSub?.cancel();
    _engineSub = null;
    await engine?.close();
  }
}
