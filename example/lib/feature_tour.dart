// A compile-checked tour of every socket_io_lite feature.
//
// This file is a reference, not a runnable app — call [featureTour] from your
// own code, or just read it. The interactive demo lives in `main.dart`.
//
// ignore_for_file: avoid_print, unused_local_variable

import 'package:socket_io_lite/socket_io_lite.dart';

Future<void> featureTour() async {
  // --- Connecting -----------------------------------------------------------

  // Simplest: connect to the root namespace.
  final socket = SocketIoLite.connect('ws://localhost:3000');

  // With options: namespace, auth (sent with CONNECT), query (added to the
  // handshake URL), extra headers (native only), and an ack timeout.
  final admin = SocketIoLite.connect(
    'ws://localhost:3000',
    namespace: '/admin',
    auth: {'token': 'secret'},
    query: {'v': '1'},
    headers: {'x-app': 'example'},
    ackTimeout: const Duration(seconds: 5),
  );

  // Tune reconnection (all optional; on by default).
  final tuned = SocketIoLite.connect(
    'ws://localhost:3000',
    reconnection: true,
    reconnectionAttempts: null, // null = unlimited
    reconnectionDelay: const Duration(seconds: 1),
    reconnectionDelayMax: const Duration(seconds: 5),
  );

  // --- Lifecycle callbacks --------------------------------------------------

  socket.onConnect((_) => print('connected: ${socket.id}'));
  socket.onDisconnect((_) => print('disconnected'));
  socket.onError((e) => print('error: $e'));

  socket.onReconnectAttempt((n) => print('retry #$n'));
  socket.onReconnect((n) => print('reconnected after $n'));
  socket.onReconnectFailed(() => print('gave up'));

  // --- Receiving events -----------------------------------------------------

  // Named listener (multiple handlers per event are allowed).
  socket.on('chat:message', (data) => print('message: $data'));

  // Fire at most once.
  socket.once('welcome', (data) => print('welcome: $data'));

  // Catch-all, useful for logging/debugging.
  socket.onAny((event, data) => print('any: $event -> $data'));

  // A multi-argument event arrives as a List.
  socket.on('offer', (data) {
    final id = data[0];
    final description = data[1];
    print('offer from $id: $description');
  });

  // Remove listeners.
  void handler(dynamic _) {}
  socket.on('typing', handler);
  socket.off('typing', handler); // one handler
  socket.off('typing'); // all handlers for the event
  socket.offAny(); // all catch-all handlers

  // --- Sending events -------------------------------------------------------

  // Single payload.
  socket.emit('chat:message', {'text': 'halo'});

  // No payload.
  socket.emit('ping');

  // Multiple positional arguments (e.g. WebRTC signaling).
  socket.emit('candidate', 'peer-1', {'sdpMid': '0'});

  // --- Acknowledgements -----------------------------------------------------

  // Emit and await the server's ack.
  final reply = await socket.emitWithAck('chat:message', {'text': 'halo'});
  print('ack: $reply');

  // Multi-argument emit with ack.
  final joined = await socket.emitWithAck('join', 'room-1', {'role': 'viewer'});

  // Respond when the *server* emits an event expecting an ack; the return
  // value is sent back automatically.
  socket.onAck('whoami', (data) => {'user': 'flutter-client'});

  // --- Multiplexed namespaces (one connection) ------------------------------

  // of() reuses the same WebSocket for another namespace.
  final chat = socket.of('/chat');
  final notes = socket.of('/notes', auth: {'token': 'secret'});
  chat.on('msg', (data) => print('chat: $data'));
  notes.emit('mark-read', 42);

  // --- Tear down ------------------------------------------------------------

  // Graceful: sends DISCONNECT for this namespace, then releases it. Closes the
  // underlying connection when it was the last namespace.
  await socket.disconnect();

  // Or just release resources without a DISCONNECT packet.
  await admin.dispose();
  await tuned.dispose();
}
