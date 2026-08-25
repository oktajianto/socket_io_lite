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
- Event helpers: `once`, `onAny` / `offAny`, and `onAck` / `offAck` (respond to
  server events that expect an acknowledgement).
- Multiplexed namespaces: `socket.of('/ns')` shares a single WebSocket across
  namespaces (Manager + Socket architecture), each with its own CONNECT,
  listeners, and acks.
- Variadic emit: `emit(event, arg1, arg2, ...)` and the same for `emitWithAck`,
  matching Socket.IO's multi-argument events (e.g. WebRTC signaling). Incoming
  multi-argument events are delivered to handlers as a `List`. An explicitly
  passed `null` is now sent as an argument (previously omitted).
- Web support via `dart:html` WebSocket, selected automatically through a
  conditional import — one API across native, web, and desktop. The web build
  compiles and shares the same protocol layer that is tested on the VM.
- Verified end-to-end against a real `socket.io` v4 server on both native and
  web (browser) transports.

Note: web uses `dart:html`, which compiles with the standard JS web build; the
Wasm build (`--wasm`) is not supported yet.
