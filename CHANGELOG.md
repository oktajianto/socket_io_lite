## 0.1.0 (unreleased)

Work in progress — see `implementasi_plan.md`.

- Zero-dependency Socket.IO client for Dart & Flutter (Engine.IO v4 /
  Socket.IO v4).
- Native WebSocket transport (`dart:io`) with automatic heartbeat (server
  ping / client pong) and a missed-heartbeat watchdog.
- `SocketIoLite.connect`, `on`, `off`, `emit`, `onConnect`, `onDisconnect`,
  `onError`, `disconnect`, and `dispose`.
- Namespaces, connection auth payload, query params, and pre-connect emit
  buffering.
- Acknowledgements: `emitWithAck` with optional `ackTimeout`.
- Automatic reconnection with exponential backoff (`reconnection`,
  `reconnectionAttempts`, `reconnectionDelay`, `reconnectionDelayMax`) and
  `onReconnect` / `onReconnectAttempt` / `onReconnectFailed`.
- Verified end-to-end against a real `socket.io` v4 server.

Planned next: web support (`dart:html`).
