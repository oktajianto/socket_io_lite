/// A lightweight, zero-dependency Socket.IO client for Dart & Flutter.
///
/// Targets Engine.IO v4 / Socket.IO v4.
///
/// This barrel currently exposes the protocol layer (packets + parser). The
/// higher-level client facade is added in later phases — see
/// `implementasi_plan.md`.
library;

export 'src/packet.dart';
export 'src/parser.dart';
