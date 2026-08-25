import 'transport.dart';
import 'transport_stub.dart'
    if (dart.library.io) 'transport_io.dart' as impl;

/// Creates the [SocketTransport] appropriate for the current platform.
///
/// Resolves at compile time via conditional import: `dart:io` on native, and
/// the throwing stub elsewhere (web support arrives in a later phase).
SocketTransport createTransport() => impl.createTransport();
