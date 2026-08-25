import 'transport.dart';

/// Fallback used when no platform WebSocket library is available.
///
/// Selected on platforms that provide neither `dart:io` nor `dart:html`. Web
/// support (`dart:html`) is added in a later phase; until then the web falls
/// back here.
SocketTransport createTransport() => throw UnsupportedError(
  'socket_io_lite: no WebSocket transport is available on this platform.',
);
