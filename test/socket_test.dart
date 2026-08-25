@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_lite/socket_io_lite.dart';
import 'package:socket_io_lite/src/transport/transport.dart';

/// An in-memory transport: the test pushes inbound frames with [serverSend] and
/// inspects outbound frames via [sent].
class FakeTransport implements SocketTransport {
  final StreamController<String> _messages = StreamController<String>.broadcast();
  final Completer<void> _done = Completer<void>();
  final List<String> sent = [];
  bool _connected = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(Uri uri, {Map<String, dynamic>? headers}) async {
    _connected = true;
  }

  @override
  void send(String data) {
    if (!_connected) throw StateError('not connected');
    sent.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _connected = false;
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) _messages.close();
  }

  /// Simulates a frame arriving from the server.
  void serverSend(String raw) => _messages.add(raw);
}

const _openFrame =
    '0{"sid":"eio","upgrades":[],"pingInterval":20000,"pingTimeout":20000}';

/// Lets pending microtasks/stream events settle.
Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  test('connect flow: handshake, CONNECT sent, onConnect fires', () async {
    final fake = FakeTransport();
    final socket =
        SocketIoLite.connect('ws://x', transportFactory: () => fake);
    addTearDown(socket.dispose);

    final connected = Completer<void>();
    socket.onConnect((_) => connected.complete());

    fake.serverSend(_openFrame); // Engine.IO handshake
    await pump();

    // Client should have sent the Socket.IO CONNECT packet.
    expect(fake.sent, contains('40'));

    fake.serverSend('40{"sid":"abc123"}'); // server accepts the connection
    await connected.future.timeout(const Duration(seconds: 1));

    expect(socket.connected, isTrue);
    expect(socket.id, 'abc123');
  });

  test('dispatches an incoming event to on() handlers', () async {
    final fake = FakeTransport();
    final socket =
        SocketIoLite.connect('ws://x', transportFactory: () => fake);
    addTearDown(socket.dispose);

    final received = Completer<dynamic>();
    socket.on('chat:message', received.complete);

    fake.serverSend(_openFrame);
    await pump();
    fake.serverSend('40{"sid":"abc"}');
    await pump();

    fake.serverSend('42["chat:message",{"text":"halo"}]');
    final data = await received.future.timeout(const Duration(seconds: 1));
    expect(data, {'text': 'halo'});
  });

  test('emit sends an event frame once connected', () async {
    final fake = FakeTransport();
    final socket =
        SocketIoLite.connect('ws://x', transportFactory: () => fake);
    addTearDown(socket.dispose);

    fake.serverSend(_openFrame);
    await pump();
    fake.serverSend('40{"sid":"abc"}');
    await pump();

    socket.emit('chat:message', {'text': 'hi'});
    expect(fake.sent, contains('42["chat:message",{"text":"hi"}]'));
  });

  test('emit before connect is buffered, then flushed on connect', () async {
    final fake = FakeTransport();
    final socket =
        SocketIoLite.connect('ws://x', transportFactory: () => fake);
    addTearDown(socket.dispose);

    // Emit while still connecting.
    socket.emit('early', 1);
    fake.serverSend(_openFrame);
    await pump();

    // Not delivered yet (only CONNECT has been sent).
    expect(fake.sent, isNot(contains('42["early",1]')));

    fake.serverSend('40{"sid":"abc"}');
    await pump();

    expect(fake.sent, contains('42["early",1]'));
  });

  test('onDisconnect fires when the connection closes', () async {
    final fake = FakeTransport();
    final socket =
        SocketIoLite.connect('ws://x', transportFactory: () => fake);

    fake.serverSend(_openFrame);
    await pump();
    fake.serverSend('40{"sid":"abc"}');
    await pump();

    final disconnected = Completer<void>();
    socket.onDisconnect((_) => disconnected.complete());

    await fake.close(); // transport drops
    await disconnected.future.timeout(const Duration(seconds: 1));
    expect(socket.connected, isFalse);
  });

  test('connectError surfaces via onError', () async {
    final fake = FakeTransport();
    final socket =
        SocketIoLite.connect('ws://x', transportFactory: () => fake);
    addTearDown(socket.dispose);

    final errored = Completer<Object>();
    socket.onError(errored.complete);

    fake.serverSend(_openFrame);
    await pump();
    fake.serverSend('44{"message":"Invalid namespace"}');

    final error = await errored.future.timeout(const Duration(seconds: 1));
    expect(error, isA<SocketException>());
    expect(error.toString(), contains('Invalid namespace'));
  });

  test('events for a different namespace are ignored', () async {
    final fake = FakeTransport();
    final socket = SocketIoLite.connect(
      'ws://x',
      namespace: '/admin',
      transportFactory: () => fake,
    );
    addTearDown(socket.dispose);

    // CONNECT should target the namespace.
    fake.serverSend(_openFrame);
    await pump();
    expect(fake.sent, contains('40/admin,'));

    fake.serverSend('40/admin,{"sid":"abc"}');
    await pump();

    var called = false;
    socket.on('ping', (_) => called = true);

    // Event on the root namespace must not reach an /admin socket.
    fake.serverSend('42["ping"]');
    await pump();
    expect(called, isFalse);

    // Event on the correct namespace must.
    fake.serverSend('42/admin,["ping"]');
    await pump();
    expect(called, isTrue);
  });
}
