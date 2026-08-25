@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_lite/src/engine.dart';

/// Builds an Engine.IO `open` handshake frame.
String openFrame({int pingInterval = 20000, int pingTimeout = 20000}) =>
    '0{"sid":"test","upgrades":[],"pingInterval":$pingInterval,'
    '"pingTimeout":$pingTimeout,"maxPayload":1000000}';

/// Starts a loopback server that hands each new socket to [onSocket].
Future<HttpServer> startServer(void Function(WebSocket ws) onSocket) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.transform(WebSocketTransformer()).listen(onSocket);
  return server;
}

void main() {
  test('buildUri normalizes scheme, path and adds EIO/transport', () {
    final uri = EngineIo.buildUri('http://localhost:3000');
    expect(uri.scheme, 'ws');
    expect(uri.host, 'localhost');
    expect(uri.port, 3000);
    expect(uri.path, '/socket.io/');
    expect(uri.queryParameters['EIO'], '4');
    expect(uri.queryParameters['transport'], 'websocket');

    final secure = EngineIo.buildUri('https://example.com');
    expect(secure.scheme, 'wss');
  });

  test('open() completes with the parsed handshake', () async {
    final server = await startServer((ws) {
      ws.add(openFrame(pingInterval: 25000, pingTimeout: 20000));
    });
    addTearDown(() => server.close(force: true));

    final engine = EngineIo(EngineIo.buildUri('ws://localhost:${server.port}'));
    final hs = await engine.open();

    expect(hs.sid, 'test');
    expect(hs.pingInterval, 25000);
    expect(hs.pingTimeout, 20000);
    expect(engine.isConnected, isTrue);

    await engine.close();
  });

  test(
    'send() wraps the payload in a message frame; messages unwraps it',
    () async {
      final server = await startServer((ws) {
        ws.add(openFrame());
        ws.listen((data) {
          // Echo message frames back verbatim.
          if (data is String && data.startsWith('4')) ws.add(data);
        });
      });
      addTearDown(() => server.close(force: true));

      final engine = EngineIo(
        EngineIo.buildUri('ws://localhost:${server.port}'),
      );
      await engine.open();

      final echoed = engine.messages.first;
      engine.send('2["hi"]'); // becomes '42["hi"]' on the wire
      expect(
        await echoed,
        '2["hi"]',
      ); // unwrapped back to the Socket.IO payload

      await engine.close();
    },
  );

  test('replies to a server ping with a pong', () async {
    final pongReceived = Completer<void>();
    final server = await startServer((ws) {
      ws.add(openFrame());
      ws.listen((data) {
        if (data == '3' && !pongReceived.isCompleted) pongReceived.complete();
      });
      // Send a ping shortly after the handshake.
      Timer(const Duration(milliseconds: 50), () => ws.add('2'));
    });
    addTearDown(() => server.close(force: true));

    final engine = EngineIo(EngineIo.buildUri('ws://localhost:${server.port}'));
    await engine.open();

    await pongReceived.future.timeout(const Duration(seconds: 2));

    await engine.close();
  });

  test('closes when no ping arrives within the heartbeat window', () async {
    // Tiny window: pingInterval + pingTimeout = 200ms, and we never ping.
    final server = await startServer((ws) {
      ws.add(openFrame(pingInterval: 100, pingTimeout: 100));
    });
    addTearDown(() => server.close(force: true));

    final engine = EngineIo(EngineIo.buildUri('ws://localhost:${server.port}'));
    await engine.open();

    await engine.done.timeout(const Duration(seconds: 2));
    expect(engine.isConnected, isFalse);
  });

  test('open() throws if the socket closes before the handshake', () async {
    final server = await startServer((ws) {
      ws.close(); // hang up immediately, no handshake
    });
    addTearDown(() => server.close(force: true));

    final engine = EngineIo(EngineIo.buildUri('ws://localhost:${server.port}'));
    await expectLater(engine.open(), throwsStateError);
  });
}
