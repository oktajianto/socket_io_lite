import 'package:flutter/material.dart';
import 'package:socket_io_lite/socket_io_lite.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'socket_io_lite example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // Android emulator reaches the host machine at 10.0.2.2; adjust as needed.
  final _urlController = TextEditingController(text: 'ws://10.0.2.2:3000');
  final _messageController = TextEditingController(text: 'halo');
  final _log = <String>[];

  SocketIoLite? _socket;
  bool _connected = false;

  void _connect() {
    _socket?.dispose();
    _append('Connecting to ${_urlController.text} ...');

    final socket = SocketIoLite.connect(
      _urlController.text,
      // Reconnection is on by default; shown here for illustration.
      reconnection: true,
      reconnectionDelay: const Duration(seconds: 1),
    );

    // Lifecycle
    socket.onConnect((_) {
      setState(() => _connected = true);
      _append('Connected (id: ${socket.id})');
    });
    socket.onDisconnect((_) {
      setState(() => _connected = false);
      _append('Disconnected');
    });
    socket.onError((e) => _append('Error: $e'));

    // Reconnection
    socket.onReconnectAttempt((n) => _append('Reconnecting… (attempt $n)'));
    socket.onReconnect((n) => _append('Reconnected after $n attempt(s)'));
    socket.onReconnectFailed(() => _append('Reconnect gave up'));

    // Events
    socket.on('chat:message', (data) => _append('Received: $data'));

    // once: fires at most one time
    socket.once('welcome', (data) => _append('Welcome (once): $data'));

    // onAny: catch-all, handy for debugging
    socket.onAny((event, data) => _append('· any: $event -> $data'));

    _socket = socket;
  }

  void _send() {
    final socket = _socket;
    if (socket == null) return;
    socket.emit('chat:message', {'text': _messageController.text});
    _append('Sent: ${_messageController.text}');
  }

  Future<void> _sendWithAck() async {
    final socket = _socket;
    if (socket == null) return;
    _append('Sending (awaiting ack): ${_messageController.text}');
    try {
      final ack = await socket.emitWithAck('chat:message', {
        'text': _messageController.text,
      });
      _append('Ack: $ack');
    } catch (e) {
      _append('Ack failed: $e');
    }
  }

  Future<void> _disconnect() async {
    await _socket?.disconnect();
    _socket = null;
  }

  void _append(String line) => setState(() => _log.insert(0, line));

  @override
  void dispose() {
    _socket?.dispose();
    _urlController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('socket_io_lite'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              _connected ? Icons.cloud_done : Icons.cloud_off,
              color: _connected ? Colors.greenAccent : null,
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.link),
                    label: const Text('Connect'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _connected ? _disconnect : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
              ],
            ),
            const Divider(height: 32),
            TextField(
              controller: _messageController,
              decoration: const InputDecoration(
                labelText: 'Message',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _connected ? _send : null,
                    child: const Text('Send'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: _connected ? _sendWithAck : null,
                    child: const Text('Send + ack'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(_log[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
