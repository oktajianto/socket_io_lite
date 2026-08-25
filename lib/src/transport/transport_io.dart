import 'dart:async';
import 'dart:io';

import 'transport.dart';

/// A [SocketTransport] backed by `dart:io`'s [WebSocket].
///
/// Used on Android, iOS, Windows, macOS, and Linux.
class IoTransport implements SocketTransport {
  WebSocket? _ws;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final Completer<void> _done = Completer<void>();
  bool _isConnected = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isConnected => _isConnected;

  @override
  Future<void> connect(Uri uri, {Map<String, dynamic>? headers}) async {
    final ws = await WebSocket.connect(uri.toString(), headers: headers);
    _ws = ws;
    _isConnected = true;

    ws.listen(
      (dynamic data) {
        // Socket.IO v4 over WebSocket uses text frames. Binary frames belong to
        // binary attachments, which are not supported yet, so they are ignored.
        if (data is String) {
          _messages.add(data);
        }
      },
      onError: _messages.addError,
      onDone: _handleClosed,
      cancelOnError: false,
    );
  }

  @override
  void send(String data) {
    final ws = _ws;
    if (ws == null || !_isConnected) {
      throw StateError('Transport is not connected');
    }
    ws.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    await _ws?.close(code, reason);
    _handleClosed();
  }

  void _handleClosed() {
    _isConnected = false;
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) _messages.close();
  }
}

/// Factory used by the conditional-import selector.
SocketTransport createTransport() => IoTransport();
