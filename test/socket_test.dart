@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_lite/socket_io_lite.dart';
import 'package:socket_io_lite/src/transport/transport.dart';

/// An in-memory transport: the test pushes inbound frames with [serverSend] and
/// inspects outbound frames via [sent].
class FakeTransport implements SocketTransport {
  FakeTransport({this.failOnConnect = false});

  /// When true, [connect] throws — used to simulate an unreachable server.
  final bool failOnConnect;

  final StreamController<String> _messages =
      StreamController<String>.broadcast();
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
    if (failOnConnect) throw StateError('connection refused');
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
    final socket = SocketIoLite.connect('ws://x', transportFactory: () => fake);
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
    final socket = SocketIoLite.connect('ws://x', transportFactory: () => fake);
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
    final socket = SocketIoLite.connect('ws://x', transportFactory: () => fake);
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
    final socket = SocketIoLite.connect('ws://x', transportFactory: () => fake);
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

  test('emitWithAck resolves with the server ack payload', () async {
    final fake = FakeTransport();
    final socket = SocketIoLite.connect('ws://x', transportFactory: () => fake);
    addTearDown(socket.dispose);

    fake.serverSend(_openFrame);
    await pump();
    fake.serverSend('40{"sid":"abc"}');
    await pump();

    final future = socket.emitWithAck('chat:message', {'text': 'hi'});

    // First ack id is 0 → engine message frame '4' + socket event '20[...]'.
    expect(fake.sent, contains('420["chat:message",{"text":"hi"}]'));

    // Server replies with an ACK for id 0.
    fake.serverSend('430[{"ok":true}]');
    final result = await future.timeout(const Duration(seconds: 1));
    expect(result, {'ok': true});
  });

  test('emitWithAck times out when no ack arrives', () async {
    final fake = FakeTransport();
    final socket = SocketIoLite.connect(
      'ws://x',
      ackTimeout: const Duration(milliseconds: 50),
      transportFactory: () => fake,
    );
    addTearDown(socket.dispose);

    fake.serverSend(_openFrame);
    await pump();
    fake.serverSend('40{"sid":"abc"}');
    await pump();

    await expectLater(
      socket.emitWithAck('slow'),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('pending acks fail when the connection closes', () async {
    final fake = FakeTransport();
    final socket = SocketIoLite.connect(
      'ws://x',
      reconnection: false,
      transportFactory: () => fake,
    );
    addTearDown(socket.dispose);

    fake.serverSend(_openFrame);
    await pump();
    fake.serverSend('40{"sid":"abc"}');
    await pump();

    final future = socket.emitWithAck('never');
    await fake.close();

    await expectLater(future, throwsA(isA<SocketException>()));
  });

  test('onDisconnect fires when the connection closes', () async {
    final fake = FakeTransport();
    final socket = SocketIoLite.connect(
      'ws://x',
      reconnection: false,
      transportFactory: () => fake,
    );
    addTearDown(socket.dispose);

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
    final socket = SocketIoLite.connect('ws://x', transportFactory: () => fake);
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

  group('event helpers', () {
    Future<SocketIoLite> connected(FakeTransport fake) async {
      final socket = SocketIoLite.connect(
        'ws://x',
        transportFactory: () => fake,
      );
      fake.serverSend(_openFrame);
      await pump();
      fake.serverSend('40{"sid":"abc"}');
      await pump();
      return socket;
    }

    test('once fires only for the first matching event', () async {
      final fake = FakeTransport();
      final socket = await connected(fake);
      addTearDown(socket.dispose);

      var count = 0;
      socket.once('ping', (_) => count++);

      fake.serverSend('42["ping"]');
      fake.serverSend('42["ping"]');
      await pump();

      expect(count, 1);
    });

    test('onAny receives every event with name and payload', () async {
      final fake = FakeTransport();
      final socket = await connected(fake);
      addTearDown(socket.dispose);

      final seen = <String>[];
      socket.onAny((event, data) => seen.add('$event:$data'));

      fake.serverSend('42["a",1]');
      fake.serverSend('42["b",{"x":2}]');
      await pump();

      expect(seen, ['a:1', 'b:{x: 2}']);
    });

    test('onAck responds to an ack-requesting event', () async {
      final fake = FakeTransport();
      final socket = await connected(fake);
      addTearDown(socket.dispose);

      socket.onAck('needs-ack', (data) => {'answer': 42});

      // Server event with ack id 5.
      fake.serverSend('425["needs-ack",{"q":1}]');
      await pump();

      // Client should reply with an ACK for id 5.
      expect(fake.sent, contains('435[{"answer":42}]'));
    });
  });

  group('multi-argument emit / receive', () {
    Future<(SocketIoLite, FakeTransport)> connected() async {
      final fake = FakeTransport();
      final socket = SocketIoLite.connect(
        'ws://x',
        transportFactory: () => fake,
      );
      fake.serverSend(_openFrame);
      await pump();
      fake.serverSend('40{"sid":"abc"}');
      await pump();
      return (socket, fake);
    }

    test('emit sends multiple positional arguments', () async {
      final (socket, fake) = await connected();
      addTearDown(socket.dispose);

      // WebRTC-style signaling: emit('offer', id, sdp).
      socket.emit('offer', 'peer-1', {'type': 'offer', 'sdp': 'x'});
      expect(
        fake.sent,
        contains('42["offer","peer-1",{"type":"offer","sdp":"x"}]'),
      );
    });

    test('single-argument emit is unchanged (backward compatible)', () async {
      final (socket, fake) = await connected();
      addTearDown(socket.dispose);

      socket.emit('msg', {'text': 'hi'});
      expect(fake.sent, contains('42["msg",{"text":"hi"}]'));

      socket.emit('ping');
      expect(fake.sent, contains('42["ping"]'));
    });

    test('an incoming multi-arg event arrives as a List', () async {
      final (socket, fake) = await connected();
      addTearDown(socket.dispose);

      dynamic got;
      socket.on('candidate', (data) => got = data);

      fake.serverSend('42["candidate","peer-1",{"sdpMid":"0"}]');
      await pump();

      expect(got, [
        'peer-1',
        {'sdpMid': '0'},
      ]);
    });

    test('emitWithAck supports multiple arguments', () async {
      final (socket, fake) = await connected();
      addTearDown(socket.dispose);

      final future = socket.emitWithAck('join', 'room-1', {'role': 'viewer'});
      expect(fake.sent, contains('420["join","room-1",{"role":"viewer"}]'));

      fake.serverSend('430[{"ok":true}]');
      expect(await future.timeout(const Duration(seconds: 1)), {'ok': true});
    });
  });

  group('of() multi-namespace', () {
    test('shares one connection and connects both namespaces', () async {
      final fakes = <FakeTransport>[];
      FakeTransport factory() {
        final f = FakeTransport();
        fakes.add(f);
        return f;
      }

      final root = SocketIoLite.connect('ws://x', transportFactory: factory);
      final admin = root.of('/admin');
      addTearDown(() async {
        await admin.dispose();
        await root.dispose();
      });

      fakes[0].serverSend(_openFrame);
      await pump();

      // Only ONE transport, and both namespaces requested CONNECT over it.
      expect(fakes.length, 1);
      expect(fakes[0].sent, containsAll(['40', '40/admin,']));

      fakes[0].serverSend('40{"sid":"r"}');
      fakes[0].serverSend('40/admin,{"sid":"a"}');
      await pump();

      expect(root.connected, isTrue);
      expect(admin.connected, isTrue);
      expect(root.id, 'r');
      expect(admin.id, 'a');
    });

    test('routes events and emits to the right namespace', () async {
      final fake = FakeTransport();
      final root = SocketIoLite.connect('ws://x', transportFactory: () => fake);
      final admin = root.of('/admin');
      addTearDown(() async {
        await admin.dispose();
        await root.dispose();
      });

      fake.serverSend(_openFrame);
      await pump();
      fake.serverSend('40{"sid":"r"}');
      fake.serverSend('40/admin,{"sid":"a"}');
      await pump();

      dynamic rootGot;
      dynamic adminGot;
      root.on('msg', (d) => rootGot = d);
      admin.on('msg', (d) => adminGot = d);

      fake.serverSend('42["msg","for-root"]');
      fake.serverSend('42/admin,["msg","for-admin"]');
      await pump();

      expect(rootGot, 'for-root');
      expect(adminGot, 'for-admin');

      // Emits carry the namespace prefix.
      admin.emit('do', 1);
      expect(fake.sent, contains('42/admin,["do",1]'));
    });

    test('of() returns the same instance for a namespace', () async {
      final fake = FakeTransport();
      final root = SocketIoLite.connect('ws://x', transportFactory: () => fake);
      addTearDown(root.dispose);

      expect(identical(root.of('/admin'), root.of('/admin')), isTrue);
    });
  });

  group('reconnection', () {
    test('reconnects with a fresh engine and fires onReconnect', () async {
      final fakes = <FakeTransport>[];
      FakeTransport factory() {
        final f = FakeTransport();
        fakes.add(f);
        return f;
      }

      final socket = SocketIoLite.connect(
        'ws://x',
        reconnectionDelay: const Duration(milliseconds: 20),
        transportFactory: factory,
      );
      addTearDown(socket.dispose);

      // First connection.
      fakes[0].serverSend(_openFrame);
      await pump();
      fakes[0].serverSend('40{"sid":"a"}');
      await pump();
      expect(socket.connected, isTrue);
      expect(socket.id, 'a');

      final reconnected = Completer<int>();
      socket.onReconnect(reconnected.complete);

      // Drop the connection.
      await fakes[0].close();
      await pump();
      expect(socket.connected, isFalse);

      // The backoff timer should spin up a second transport.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fakes.length, greaterThanOrEqualTo(2));

      // Drive the new engine's handshake + connect.
      fakes[1].serverSend(_openFrame);
      await pump();
      fakes[1].serverSend('40{"sid":"b"}');
      await pump();

      final attempt = await reconnected.future.timeout(
        const Duration(seconds: 2),
      );
      expect(attempt, 1);
      expect(socket.connected, isTrue);
      expect(socket.id, 'b');
    });

    test(
      'gives up after reconnectionAttempts and fires onReconnectFailed',
      () async {
        var attempts = 0;
        final failed = Completer<void>();

        final socket = SocketIoLite.connect(
          'ws://x',
          reconnectionAttempts: 2,
          reconnectionDelay: const Duration(milliseconds: 10),
          transportFactory: () => FakeTransport(failOnConnect: true),
        );
        addTearDown(socket.dispose);

        socket.onError((_) {}); // swallow the connection errors
        socket.onReconnectAttempt((_) => attempts++);
        socket.onReconnectFailed(failed.complete);

        await failed.future.timeout(const Duration(seconds: 2));
        expect(attempts, 2);
        expect(socket.connected, isFalse);
      },
    );

    test('no reconnect when reconnection is disabled', () async {
      final fakes = <FakeTransport>[];
      FakeTransport factory() {
        final f = FakeTransport();
        fakes.add(f);
        return f;
      }

      final socket = SocketIoLite.connect(
        'ws://x',
        reconnection: false,
        transportFactory: factory,
      );
      addTearDown(socket.dispose);

      fakes[0].serverSend(_openFrame);
      await pump();
      fakes[0].serverSend('40{"sid":"a"}');
      await pump();

      await fakes[0].close();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(fakes.length, 1); // no new transport was created
      expect(socket.connected, isFalse);
    });
  });
}
