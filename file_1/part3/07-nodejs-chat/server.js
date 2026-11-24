// Bài 7 (Phần 3): chat server WebSocket chạy trên MỘT tiến trình Node.js, một event loop.
// - ws://<host>:PORT/chat : client gửi {"type":"chat","text":...} -> server phát lại cho mọi client;
//                           client gửi {"type":"ping","t":...}  -> server trả {"type":"pong","t":...} cho riêng client đó
// - http://<host>:PORT/stats : số kết nối, số tin nhắn, bộ nhớ, độ trễ event loop (để chứng minh server không bị nghẽn)
'use strict';

const http = require('node:http');
const { monitorEventLoopDelay } = require('node:perf_hooks');
const { WebSocketServer, WebSocket } = require('ws');

const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || '127.0.0.1';

const loopDelay = monitorEventLoopDelay({ resolution: 10 });
loopDelay.enable();
let totalMessages = 0;
let peakConnections = 0;

function stats() {
  return {
    connections: wss.clients.size,
    peak_connections: peakConnections,
    messages_received: totalMessages,
    rss_mb: Number((process.memoryUsage().rss / 1048576).toFixed(1)),
    event_loop_delay_p99_ms: Number((loopDelay.percentile(99) / 1e6).toFixed(2)),
    event_loop_delay_max_ms: Number((loopDelay.max / 1e6).toFixed(2)),
    node: process.version,
    pid: process.pid,
  };
}

const server = http.createServer((req, res) => {
  if (req.url === '/stats') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(stats()));
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, path: '/chat' });

wss.on('connection', (ws) => {
  peakConnections = Math.max(peakConnections, wss.clients.size);
  ws.on('message', (data) => {
    totalMessages += 1;
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return; // bỏ qua dữ liệu không phải JSON
    }
    if (msg.type === 'ping') {
      ws.send(JSON.stringify({ type: 'pong', t: msg.t }));
    } else if (msg.type === 'chat') {
      const out = JSON.stringify({ type: 'chat', from: msg.from, text: msg.text });
      for (const client of wss.clients) {
        if (client.readyState === WebSocket.OPEN) client.send(out);
      }
    }
  });
});

server.listen(PORT, HOST, () => {
  console.log(`chat-server ${process.version} pid=${process.pid} lắng nghe ws://${HOST}:${PORT}/chat`);
});

// Ghi thống kê ra journald mỗi 10 giây khi có kết nối
setInterval(() => {
  if (wss.clients.size > 0) console.log('stats', JSON.stringify(stats()));
}, 10_000).unref();

process.on('SIGTERM', () => {
  console.log('Nhận SIGTERM, đóng server');
  for (const client of wss.clients) client.close(1001, 'server shutdown');
  server.close(() => process.exit(0));
});
