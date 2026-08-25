@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_lite/src/transport/transport_io.dart';

void main() {
  late HttpServer server;
  late Uri url;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('ws://localhost:${server.port}');
    server.transform(WebSocketTransformer()).listen((ws) {
      ws.listen((data) {
        // A sentinel frame asks the server to hang up; anything else is echoed.
        if (data == '__close__') {
          ws.close();
        } else {
          ws.add(data);
        }
      });
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('connects and reports connected state', () async {
    final transport = createTransport();
    await transport.connect(url);
    expect(transport.isConnected, isTrue);
    await transport.close();
  });

  test('sends a frame and receives the echo', () async {
    final transport = createTransport();
    await transport.connect(url);

    final received = transport.messages.first;
    transport.send('42["hi"]');
    expect(await received, '42["hi"]');

    await transport.close();
  });

  test('send before connect throws StateError', () {
    final transport = createTransport();
    expect(() => transport.send('x'), throwsStateError);
  });

  test('done completes and isConnected is false after close', () async {
    final transport = createTransport();
    await transport.connect(url);
    await transport.close();
    expect(transport.isConnected, isFalse);
    await transport.done; // must not hang
  });

  test('done completes when the server closes the socket', () async {
    final transport = createTransport();
    await transport.connect(url);
    transport.send('__close__'); // ask the server to hang up
    await transport.done; // must not hang
    expect(transport.isConnected, isFalse);
  });
}
