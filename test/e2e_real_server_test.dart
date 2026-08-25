@TestOn('vm')
@Tags(['e2e'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_lite/socket_io_lite.dart';

/// End-to-end check against a real `socket.io` server running on
/// ws://localhost:3000 (see example/server). Run manually with:
///   flutter test test/e2e_real_server_test.dart
void main() {
  test('connects to a real socket.io server, emits and receives echo',
      () async {
    final socket = SocketIoLite.connect('ws://localhost:3000');
    addTearDown(socket.dispose);

    final connected = Completer<void>();
    final echoed = Completer<dynamic>();

    socket.onConnect((_) => connected.complete());
    socket.onError((e) => fail('unexpected error: $e'));
    socket.on('chat:message', (data) {
      if (!echoed.isCompleted) echoed.complete(data);
    });

    await connected.future.timeout(const Duration(seconds: 5));
    expect(socket.connected, isTrue);

    socket.emit('chat:message', {'text': 'halo'});

    final reply = await echoed.future.timeout(const Duration(seconds: 5));
    expect(reply, {
      'echo': {'text': 'halo'},
      'from': 'server',
    });
  });

  test('emitWithAck resolves with the real server acknowledgement', () async {
    final socket = SocketIoLite.connect('ws://localhost:3000');
    addTearDown(socket.dispose);

    final connected = Completer<void>();
    socket.onConnect((_) => connected.complete());
    socket.onError((e) => fail('unexpected error: $e'));

    await connected.future.timeout(const Duration(seconds: 5));

    final ack = await socket
        .emitWithAck('chat:message', {'text': 'halo'})
        .timeout(const Duration(seconds: 5));

    expect(ack, {
      'ok': true,
      'received': {'text': 'halo'},
    });
  });
}
