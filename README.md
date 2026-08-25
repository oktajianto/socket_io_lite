# socket_io_lite

[![flutter](https://img.shields.io/badge/flutter-website-deepskyblue.svg)](https://flutter.dev)
[![dart](https://img.shields.io/badge/dart-website-00B4AB.svg)](https://dart.dev)
[![platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20Web%20%7C%20Mac%20%7C%20Linux%20%7C%20Windows-brightgreen.svg)](https://flutter.dev)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![pub](https://img.shields.io/pub/v/socket_io_lite.svg)](https://pub.dev/packages/socket_io_lite)
[![pub points](https://img.shields.io/pub/points/socket_io_lite.svg)](https://pub.dev/packages/socket_io_lite/score)
[![likes](https://img.shields.io/pub/likes/socket_io_lite.svg)](https://pub.dev/packages/socket_io_lite/score)
[![stars](https://img.shields.io/github/stars/oktajianto/socket_io_lite.svg?style=social)](https://github.com/oktajianto/socket_io_lite)
[![CI](https://github.com/oktajianto/socket_io_lite/actions/workflows/ci.yml/badge.svg)](https://github.com/oktajianto/socket_io_lite/actions/workflows/ci.yml)

A lightweight, **zero-dependency** Socket.IO client for Dart & Flutter. It speaks
the standard Socket.IO wire protocol, so it connects to any real Socket.IO
server — Node.js, NestJS (`@nestjs/websockets`), or your own — in production and
on `localhost` during development.

**Works on every Flutter platform:** Android · iOS · Web · Windows · macOS ·
Linux. It is a pure-Dart package (no third-party dependencies), built entirely
on the Dart SDK's own `WebSocket`, so it runs anywhere Flutter runs.

> **Protocol support:** targets **Engine.IO v4**, so it works with a
> **Socket.IO server v3 or v4** — plain Node.js `socket.io`, an Express app, or
> a NestJS gateway (all built on the same `socket.io` library). The client
> connects over WebSocket transport with `?EIO=4`.

## Why another Socket.IO client?

Most existing clients pull in extra packages and lag behind the current
protocol. `socket_io_lite` focuses on being small and honest:

- **Zero dependencies** — only the Dart/Flutter SDK. Nothing to audit, nothing
  to fall out of date.
- **Standard-compatible** — talks the same Engine.IO/Socket.IO frames as the
  official JS client, so real servers can't tell the difference.
- **Pure Dart, all platforms** — WebSocket from the SDK, with a conditional
  import so the same API works on native and Web.
- **Heartbeat handled for you** — responds to the server's ping/pong and treats
  a missed heartbeat as a dropped connection.
- **Auto-reconnect** — exponential backoff out of the box, with events you can
  listen to.
- **Acknowledgements** — `emitWithAck` returns a `Future` that completes with
  the server's callback value.
- **Testable core** — the packet parser is pure (string in, object out), so it
  is unit-tested without a network.

## Getting started

Add it with a single command:

```bash
flutter pub add socket_io_lite
```

Then import it:

```dart
import 'package:socket_io_lite/socket_io_lite.dart';
```

## Usage

```dart
final socket = SocketIoLite.connect('ws://localhost:3000');

socket.onConnect((_) => print('connected'));
socket.onDisconnect((_) => print('disconnected'));

// Listen for an event
socket.on('chat:message', (data) {
  print('received: $data');
});

// Emit an event
socket.emit('chat:message', {'text': 'halo'});

// Emit and wait for the server's acknowledgement
final reply = await socket.emitWithAck('chat:message', {'text': 'halo'});
print('ack: $reply');

// Clean up
socket.dispose();
```

### More listeners

```dart
// Fire once, then auto-remove
socket.once('welcome', (data) => print(data));

// Catch every event (great for debugging/logging)
socket.onAny((event, data) => print('$event -> $data'));

// Respond when the server emits an event expecting an acknowledgement;
// the return value is sent back as the ack.
socket.onAck('ping', (data) => {'pong': true});
```

### Multiple arguments (WebRTC-style signaling)

`emit` is variadic, matching Socket.IO's `emit(event, ...args)` — handy for
signaling servers that use several positional arguments:

```dart
// emit('offer', id, description)  →  ["offer", id, description] on the wire
socket.emit('offer', peerId, {'type': 'offer', 'sdp': sdp});
socket.emit('candidate', peerId, candidate.toMap());
```

When an incoming event carries several arguments, the handler receives them as
a `List`:

```dart
socket.on('offer', (data) {
  final id = data[0];
  final description = data[1];
});
```

This makes the plugin a drop-in signaling channel for `flutter_webrtc`, while
the media itself flows over WebRTC (or you play HLS via `video_player`).

### Reconnection

Enabled by default with exponential backoff. Tune it via `connect`:

```dart
final socket = SocketIoLite.connect(
  'ws://localhost:3000',
  reconnection: true,           // default
  reconnectionAttempts: null,   // null = unlimited
  reconnectionDelay: Duration(seconds: 1),
  reconnectionDelayMax: Duration(seconds: 5),
);

socket.onReconnect((attempt) => print('reconnected after $attempt tries'));
socket.onReconnectAttempt((attempt) => print('retrying #$attempt'));
socket.onReconnectFailed(() => print('gave up'));
```

### Namespaces & auth

Connect straight to a namespace:

```dart
final admin = SocketIoLite.connect(
  'ws://localhost:3000',
  namespace: '/admin',
  auth: {'token': 'secret'},   // sent with the CONNECT packet
  query: {'v': '1'},           // appended to the handshake URL
);
```

Or share **one** WebSocket across several namespaces with `of()`:

```dart
final chat  = SocketIoLite.connect('ws://localhost:3000'); // root '/'
final admin = chat.of('/admin');   // same connection, second namespace
final notes = chat.of('/notes', auth: {'token': 'secret'});

admin.on('kick', (data) => ...);
notes.emit('mark-read', 42);
```

`of()` returns the same instance for a given namespace, so calling it again is
cheap. The underlying connection closes automatically once the last namespace is
disposed.

### Connecting to localhost during development

`localhost` inside an emulator/simulator does **not** mean your PC. Use the
right host for your target:

| Environment          | Server URL                 |
| -------------------- | -------------------------- |
| Android Emulator     | `ws://10.0.2.2:3000`       |
| iOS Simulator        | `ws://localhost:3000`      |
| Physical device      | `ws://<your-PC-LAN-IP>:3000` (same Wi-Fi) |
| Flutter Web / Desktop| `ws://localhost:3000`      |

On Android, non-TLS (`ws://` / `http://`) traffic is blocked by default. For
**debug builds only**, allow cleartext in `AndroidManifest.xml`:

```xml
<application android:usesCleartextTraffic="true" ... >
```

In production use `wss://your-domain.com`.

### Example NestJS server

```typescript
@WebSocketGateway({ cors: { origin: '*' } })
export class ChatGateway {
  @SubscribeMessage('chat:message')
  handleMessage(@MessageBody() data: any) {
    return { echo: data }; // return value becomes the ACK
  }
}
```

## How it works

Socket.IO is a thin protocol layered on top of a WebSocket:

- **Engine.IO** handles the transport and heartbeat. Every frame is prefixed
  with one digit — `0` open (handshake), `2` ping, `3` pong, `4` message.
- **Socket.IO** rides inside the `4` (message) frames. The next digit is the
  packet type — `0` CONNECT, `1` DISCONNECT, `2` EVENT, `3` ACK.

So an event on the wire looks like `42["chat:message",{"text":"halo"}]`:
`4` = Engine.IO message, `2` = Socket.IO EVENT, then a JSON array of
`[eventName, ...args]`. `socket_io_lite` encodes and decodes these frames for
you and exposes a simple `on`/`emit` API.

## Compatibility

| Server                                   | Supported |
| ---------------------------------------- | --------- |
| `socket.io` v4 (Node.js)                 | ✅        |
| `socket.io` v3 (Node.js)                 | ✅        |
| NestJS `@nestjs/websockets` (socket.io)  | ✅        |
| `socket.io` v2 / Engine.IO v3            | ❌ (use EIO v4 server) |
| Raw WebSocket servers (non–Socket.IO)    | ❌ (different protocol) |

### Platforms

| Platform                    | Transport            |
| --------------------------- | -------------------- |
| Android · iOS · Win/mac/Linux | `dart:io` WebSocket |
| Web                         | `dart:html` WebSocket |

> On the web this uses `dart:html` (to stay dependency-free), which compiles
> with the standard JS web build. The Wasm build (`flutter build web --wasm`)
> is not supported yet.

## License

MIT — see [LICENSE](LICENSE).
