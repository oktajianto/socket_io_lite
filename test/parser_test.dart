import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_lite/src/packet.dart';
import 'package:socket_io_lite/src/parser.dart';

void main() {
  group('EngineParser', () {
    test('encodes frames with and without data', () {
      expect(EngineParser.encode(EnginePacketType.ping), '2');
      expect(EngineParser.encode(EnginePacketType.pong), '3');
      expect(
        EngineParser.encode(EnginePacketType.message, '2["hi"]'),
        '42["hi"]',
      );
    });

    test('decodes frames into type + data', () {
      expect(
        EngineParser.decode('2'),
        const EnginePacket(EnginePacketType.ping),
      );
      expect(
        EngineParser.decode('3'),
        const EnginePacket(EnginePacketType.pong),
      );
      expect(
        EngineParser.decode('42["hi"]'),
        const EnginePacket(EnginePacketType.message, '2["hi"]'),
      );
    });

    test('throws on empty or invalid frames', () {
      expect(() => EngineParser.decode(''), throwsFormatException);
      expect(() => EngineParser.decode('x'), throwsFormatException);
    });

    test('parses the handshake open payload', () {
      const raw =
          '{"sid":"lv_VI97HAXpY6yYWAAAC","upgrades":["websocket"],'
          '"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}';
      final hs = EngineParser.parseHandshake(raw);
      expect(hs.sid, 'lv_VI97HAXpY6yYWAAAC');
      expect(hs.pingInterval, 25000);
      expect(hs.pingTimeout, 20000);
      expect(hs.upgrades, ['websocket']);
      expect(hs.maxPayload, 1000000);
    });
  });

  group('SocketParser.encode', () {
    test('connect (default namespace)', () {
      expect(
        SocketParser.encode(const SocketPacket(type: SocketPacketType.connect)),
        '0',
      );
    });

    test('connect with auth payload', () {
      expect(
        SocketParser.encode(
          const SocketPacket(
            type: SocketPacketType.connect,
            data: {'token': 'abc'},
          ),
        ),
        '0{"token":"abc"}',
      );
    });

    test('connect on a named namespace', () {
      expect(
        SocketParser.encode(
          const SocketPacket(
            type: SocketPacketType.connect,
            namespace: '/admin',
          ),
        ),
        '0/admin,',
      );
    });

    test('event (default namespace)', () {
      expect(
        SocketParser.encode(
          const SocketPacket(
            type: SocketPacketType.event,
            data: [
              'chat:message',
              {'text': 'halo'},
            ],
          ),
        ),
        '2["chat:message",{"text":"halo"}]',
      );
    });

    test('event with an ack id', () {
      expect(
        SocketParser.encode(
          const SocketPacket(
            type: SocketPacketType.event,
            data: ['hi'],
            ackId: 12,
          ),
        ),
        '212["hi"]',
      );
    });

    test('event on a namespace with an ack id', () {
      expect(
        SocketParser.encode(
          const SocketPacket(
            type: SocketPacketType.event,
            namespace: '/admin',
            data: ['hi'],
            ackId: 3,
          ),
        ),
        '2/admin,3["hi"]',
      );
    });

    test('ack packet', () {
      expect(
        SocketParser.encode(
          const SocketPacket(
            type: SocketPacketType.ack,
            data: ['ok'],
            ackId: 1,
          ),
        ),
        '31["ok"]',
      );
    });

    test('disconnect', () {
      expect(
        SocketParser.encode(
          const SocketPacket(type: SocketPacketType.disconnect),
        ),
        '1',
      );
    });

    test('binary packets are rejected', () {
      expect(
        () => SocketParser.encode(
          const SocketPacket(type: SocketPacketType.binaryEvent, data: ['x']),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('SocketParser.decode', () {
    test('connect with a session id', () {
      final p = SocketParser.decode('0{"sid":"abc123"}');
      expect(p.type, SocketPacketType.connect);
      expect(p.namespace, '/');
      expect(p.ackId, isNull);
      expect(p.data, {'sid': 'abc123'});
    });

    test('connect response on a namespace', () {
      final p = SocketParser.decode('0/admin,{"sid":"abc"}');
      expect(p.type, SocketPacketType.connect);
      expect(p.namespace, '/admin');
      expect(p.data, {'sid': 'abc'});
    });

    test('event with args', () {
      final p = SocketParser.decode('2["chat:message",{"text":"halo"}]');
      expect(p.type, SocketPacketType.event);
      expect(p.namespace, '/');
      expect(p.ackId, isNull);
      expect(p.data, [
        'chat:message',
        {'text': 'halo'},
      ]);
    });

    test('event with an ack id', () {
      final p = SocketParser.decode('212["hi"]');
      expect(p.type, SocketPacketType.event);
      expect(p.ackId, 12);
      expect(p.data, ['hi']);
    });

    test('event on a namespace with an ack id', () {
      final p = SocketParser.decode('2/admin,3["hi"]');
      expect(p.type, SocketPacketType.event);
      expect(p.namespace, '/admin');
      expect(p.ackId, 3);
      expect(p.data, ['hi']);
    });

    test(
      'a comma inside the payload is not read as the namespace separator',
      () {
        final p = SocketParser.decode('2/room,["msg","a,b,c"]');
        expect(p.namespace, '/room');
        expect(p.data, ['msg', 'a,b,c']);
      },
    );

    test('ack packet', () {
      final p = SocketParser.decode('31["ok"]');
      expect(p.type, SocketPacketType.ack);
      expect(p.ackId, 1);
      expect(p.data, ['ok']);
    });

    test('bare connect / disconnect', () {
      expect(SocketParser.decode('0').type, SocketPacketType.connect);
      expect(SocketParser.decode('1').type, SocketPacketType.disconnect);
    });

    test('binary packets are rejected', () {
      expect(() => SocketParser.decode('51-["x"]'), throwsUnsupportedError);
    });

    test('throws on empty or invalid input', () {
      expect(() => SocketParser.decode(''), throwsFormatException);
      expect(() => SocketParser.decode('x'), throwsFormatException);
    });
  });

  group('round-trip encode ∘ decode', () {
    final packets = <SocketPacket>[
      const SocketPacket(type: SocketPacketType.connect),
      const SocketPacket(
        type: SocketPacketType.connect,
        data: {'token': 'abc'},
      ),
      const SocketPacket(
        type: SocketPacketType.disconnect,
        namespace: '/admin',
      ),
      const SocketPacket(type: SocketPacketType.event, data: ['hi', 1, true]),
      const SocketPacket(
        type: SocketPacketType.event,
        namespace: '/admin',
        data: ['hi'],
        ackId: 7,
      ),
      const SocketPacket(type: SocketPacketType.ack, data: ['ok'], ackId: 42),
    ];

    for (final packet in packets) {
      test('$packet', () {
        expect(SocketParser.decode(SocketParser.encode(packet)), packet);
      });
    }
  });
}
