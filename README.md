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

> **Protocol support:** targets **Engine.IO v4** and **Socket.IO v4** — the
> versions used by the modern `socket.io` server (v3/v4) and NestJS gateways.
> The client connects over WebSocket transport with `?EIO=4`.

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
