// This file is the web-only transport. Using dart:html (instead of package:web
// + dart:js_interop) is a deliberate choice to keep the package dependency-free.
// It is selected only on the web via a conditional import, so these web-library
// lints do not apply.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;

import 'transport.dart';

/// A [SocketTransport] backed by the browser's WebSocket (`dart:html`).
///
/// Used on Flutter Web. Custom request headers cannot be set from the browser,
/// so [connect]'s `headers` argument is ignored here.
class HtmlTransport implements SocketTransport {
  html.WebSocket? _ws;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final Completer<void> _done = Completer<void>();
  bool _connected = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(Uri uri, {Map<String, dynamic>? headers}) async {
    final ws = html.WebSocket(uri.toString());
    _ws = ws;

    final opened = Completer<void>();

    ws.onOpen.first.then((_) {
      _connected = true;
      if (!opened.isCompleted) opened.complete();
    });

    ws.onMessage.listen((html.MessageEvent event) {
      final data = event.data;
      // Socket.IO v4 over WebSocket uses text frames; ignore binary ones.
      if (data is String) _messages.add(data);
    });

    ws.onError.listen((html.Event _) {
      final error = StateError('WebSocket error');
      if (!opened.isCompleted) {
        opened.completeError(error);
      } else if (!_messages.isClosed) {
        _messages.addError(error);
      }
    });

    ws.onClose.first.then((_) => _handleClosed());

    await opened.future;
  }

  @override
  void send(String data) {
    final ws = _ws;
    if (ws == null || !_connected) {
      throw StateError('Transport is not connected');
    }
    ws.sendString(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _ws?.close(code, reason);
    _handleClosed();
  }

  void _handleClosed() {
    _connected = false;
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) _messages.close();
  }
}

/// Factory used by the conditional-import selector.
SocketTransport createTransport() => HtmlTransport();
