import 'transport.dart';
import 'transport_stub.dart'
    if (dart.library.io) 'transport_io.dart'
    if (dart.library.html) 'transport_html.dart'
    as impl;

/// Creates the [SocketTransport] appropriate for the current platform.
///
/// Resolves at compile time via conditional import: `dart:io` on native,
/// `dart:html` on the web, and the throwing stub where neither is available.
SocketTransport createTransport() => impl.createTransport();
