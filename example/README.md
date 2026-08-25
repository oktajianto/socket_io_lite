# socket_io_lite example

A small Flutter app that connects to a Socket.IO server, sends `chat:message`
events, and prints what it receives.

## 1. Run the test server

A minimal Node.js Socket.IO server lives in [`server/`](server).

```bash
cd example/server
npm install
npm start
```

It listens on `0.0.0.0:3000` and echoes every `chat:message` back to the sender.

## 2. Run the app

```bash
cd example
flutter pub get
flutter run
```

Set the **Server URL** for your target:

| Environment           | URL                          |
| --------------------- | ---------------------------- |
| Android Emulator      | `ws://10.0.2.2:3000`         |
| iOS Simulator         | `ws://localhost:3000`        |
| Physical device       | `ws://<your-PC-LAN-IP>:3000` |
| Flutter Web / Desktop | `ws://localhost:3000`        |

> On Android, allow cleartext (`ws://`) for debug builds — see the main README.

## What's demonstrated

- [`lib/main.dart`](lib/main.dart) — a runnable app: connect/disconnect,
  `emit`, `emitWithAck`, lifecycle + reconnection callbacks, `once`, and
  `onAny`.
- [`lib/feature_tour.dart`](lib/feature_tour.dart) — a compile-checked reference
  covering **every** API: namespaces & `of()`, auth/query/headers, multi-argument
  emit, `onAck`, listener removal, and reconnection tuning.
