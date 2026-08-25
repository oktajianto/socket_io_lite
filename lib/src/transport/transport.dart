/// The transport layer beneath Engine.IO: a bidirectional stream of text
/// frames over a WebSocket.
///
/// Implementations are platform-specific ([dart:io] on native, [dart:html] on
/// the web) but share this interface, so the layers above never touch a
/// platform library directly.
abstract interface class SocketTransport {
  /// Opens the connection to [uri].
  ///
  /// [headers] are extra request headers (native only; ignored where the
  /// platform does not allow setting them). Completes once the socket is open,
  /// or throws if the connection fails.
  Future<void> connect(Uri uri, {Map<String, dynamic>? headers});

  /// Sends a text [data] frame. Throws [StateError] if not connected.
  void send(String data);

  /// Incoming text frames. A broadcast stream; errors are forwarded here.
  Stream<String> get messages;

  /// Completes when the connection closes (cleanly or otherwise).
  Future<void> get done;

  /// Whether the connection is currently open.
  bool get isConnected;

  /// Closes the connection, optionally with a WebSocket close [code]/[reason].
  Future<void> close([int? code, String? reason]);
}
