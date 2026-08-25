// Minimal Socket.IO server for testing socket_io_lite end-to-end.
//
//   cd example/server
//   npm install
//   npm start            # listens on 0.0.0.0:3000
//
// It echoes every "chat:message" back to the sender and, when the client uses
// emitWithAck, replies through the acknowledgement callback.

const { Server } = require('socket.io');

const io = new Server(3000, {
  cors: { origin: '*' },
});

io.on('connection', (socket) => {
  console.log('client connected:', socket.id);

  socket.on('chat:message', (data, ack) => {
    console.log('recv chat:message:', data);

    // Echo back as a normal event.
    socket.emit('chat:message', { echo: data, from: 'server' });

    // If the client expects an acknowledgement, answer it.
    if (typeof ack === 'function') {
      ack({ ok: true, received: data });
    }
  });

  socket.on('disconnect', (reason) => {
    console.log('client disconnected:', socket.id, reason);
  });
});

console.log('Socket.IO server listening on http://0.0.0.0:3000');
