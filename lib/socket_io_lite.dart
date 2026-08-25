/// A lightweight, zero-dependency Socket.IO client for Dart & Flutter.
///
/// Targets Engine.IO v4 / Socket.IO v4. See [SocketIoLite] to get started.
library;

export 'src/socket.dart' show SocketIoLite, SocketException, EventHandler, LifecycleHandler, ErrorHandler;
export 'src/packet.dart' show Handshake;
