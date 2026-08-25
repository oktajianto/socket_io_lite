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

    final socket = SocketIoLite.connect(_urlController.text);
    socket.onConnect((_) {
      setState(() => _connected = true);
      _append('Connected (id: ${socket.id})');
    });
    socket.onDisconnect((_) {
      setState(() => _connected = false);
      _append('Disconnected');
    });
    socket.onError((e) => _append('Error: $e'));
    socket.on('chat:message', (data) => _append('Received: $data'));

    _socket = socket;
  }

  void _send() {
    final socket = _socket;
    if (socket == null) return;
    final text = _messageController.text;
    socket.emit('chat:message', {'text': text});
    _append('Sent: $text');
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
            FilledButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.link),
              label: const Text('Connect'),
            ),
            const Divider(height: 32),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _connected ? _send : null,
                  child: const Text('Send'),
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
