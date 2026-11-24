// Bài 10 (Phần 3): push-server mô phỏng kiến trúc push-server Node.js của Bitrix24 On-Premise.
// Một file, hai vai trò (biến môi trường PUSH_ROLE), mỗi vai trò là một tiến trình systemd riêng:
//   sub : giữ kết nối WebSocket của trình duyệt tại ws://<node>:8010/bitrix/subws/?CHANNEL_ID=<kênh>[,<kênh>...]
//         và nghe Redis (PSUBSCRIBE push:*) để đẩy tin tới client đang nghe kênh đó trên node này.
//   pub : nhận tin từ backend tại POST http://<node>:9010/bitrix/pub/?CHANNEL_ID=<kênh>, kiểm tra chữ ký
//         HMAC-SHA256 (header X-Signature, khóa bí mật SECURITY_KEY dùng chung với backend), rồi PUBLISH
//         lên Redis và lưu 100 tin gần nhất của kênh (LPUSH/LTRIM).
// Vì mọi tiến trình sub ở mọi node cùng nghe Redis, tin gửi qua pub của node1 vẫn tới client đang nối vào node2.
// Đây là bản mô phỏng để thực hành, không phải mã nguồn push-server thật của Bitrix.
'use strict';

const crypto = require('node:crypto');
const http = require('node:http');
const os = require('node:os');
const { createClient } = require('redis');
const { WebSocketServer, WebSocket } = require('ws');

const ROLE = process.env.PUSH_ROLE;
const PORT = Number(process.env.PORT || (ROLE === 'pub' ? 9010 : 8010));
const HOST = process.env.HOST || '0.0.0.0';
const SECURITY_KEY = process.env.SECURITY_KEY || '';
const REDIS_URL = process.env.REDIS_URL || 'redis://127.0.0.1:6379';
const HISTORY_SIZE = 100;
const NODE = os.hostname();

if (!['sub', 'pub'].includes(ROLE) || !SECURITY_KEY) {
  console.error('Cần PUSH_ROLE=sub|pub và SECURITY_KEY');
  process.exit(1);
}

const redisOptions = {
  url: REDIS_URL,
  username: process.env.REDIS_USER,
  password: process.env.REDIS_PASSWORD,
  socket: { reconnectStrategy: (retries) => Math.min(retries * 200, 5000) },
};

const counters = { published: 0, rejected: 0, delivered: 0 };

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function channelsFrom(url) {
  const ids = new URL(url, 'http://x').searchParams.get('CHANNEL_ID') || '';
  return ids.split(',').map((s) => s.trim()).filter((s) => /^[\w.:-]{1,64}$/.test(s));
}

function verifySignature(body, signature) {
  const expected = crypto.createHmac('sha256', SECURITY_KEY).update(body).digest('hex');
  const given = Buffer.from(String(signature || ''), 'utf8');
  const want = Buffer.from(expected, 'utf8');
  return given.length === want.length && crypto.timingSafeEqual(given, want);
}

async function startSub() {
  const channels = new Map(); // tên kênh -> Set các kết nối WebSocket trên node này
  const server = http.createServer((req, res) => {
    if (req.url === '/server-stat') {
      return sendJson(res, 200, {
        node: NODE, role: 'sub', connections: wss.clients.size,
        channels: Object.fromEntries([...channels].map(([k, v]) => [k, v.size])),
        delivered: counters.delivered, rss_mb: Math.round(process.memoryUsage().rss / 1048576),
      });
    }
    return sendJson(res, 404, { error: 'not found' });
  });
  const wss = new WebSocketServer({ server, path: '/bitrix/subws/' });

  wss.on('connection', (ws, req) => {
    const ids = channelsFrom(req.url);
    if (ids.length === 0) return ws.close(4000, 'CHANNEL_ID required');
    ids.forEach((id) => {
      if (!channels.has(id)) channels.set(id, new Set());
      channels.get(id).add(ws);
    });
    ws.send(JSON.stringify({ type: 'hello', node: NODE, channels: ids }));
    ws.on('close', () => ids.forEach((id) => {
      channels.get(id)?.delete(ws);
      if (channels.get(id)?.size === 0) channels.delete(id);
    }));
  });

  const subscriber = createClient(redisOptions);
  subscriber.on('error', (err) => console.error('Redis lỗi:', err.message));
  await subscriber.connect();
  await subscriber.pSubscribe('push:*', (message, redisChannel) => {
    const id = redisChannel.slice('push:'.length);
    for (const ws of channels.get(id) || []) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(message);
        counters.delivered += 1;
      }
    }
  });

  server.listen(PORT, HOST, () => console.log(`push-server sub node=${NODE} ws://${HOST}:${PORT}/bitrix/subws/`));
  return server;
}

async function startPub() {
  const redis = createClient(redisOptions);
  redis.on('error', (err) => console.error('Redis lỗi:', err.message));
  await redis.connect();

  const server = http.createServer(async (req, res) => {
    const path = new URL(req.url, 'http://x').pathname;
    if (req.method === 'GET' && path === '/server-stat') {
      return sendJson(res, 200, { node: NODE, role: 'pub', published: counters.published, rejected: counters.rejected });
    }
    if (req.method !== 'POST' || path !== '/bitrix/pub/') return sendJson(res, 404, { error: 'not found' });

    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > 64 * 1024) return sendJson(res, 413, { error: 'payload too large' });
      chunks.push(chunk);
    }
    const body = Buffer.concat(chunks);
    if (!verifySignature(body, req.headers['x-signature'])) {
      counters.rejected += 1;
      return sendJson(res, 403, { error: 'invalid signature' });
    }
    const ids = channelsFrom(req.url);
    if (ids.length === 0) return sendJson(res, 400, { error: 'CHANNEL_ID required' });

    let data;
    try {
      data = JSON.parse(body);
    } catch {
      return sendJson(res, 400, { error: 'body must be JSON' });
    }
    const results = {};
    for (const id of ids) {
      const message = JSON.stringify({
        type: 'message', channel: id, id: crypto.randomUUID(), via: NODE, ts: Date.now(), data,
      });
      const [subscribers] = await redis.multi()
        .publish(`push:${id}`, message)
        .lPush(`push:history:${id}`, message)
        .lTrim(`push:history:${id}`, 0, HISTORY_SIZE - 1)
        .exec();
      results[id] = { redis_subscribers: subscribers };
      counters.published += 1;
    }
    return sendJson(res, 202, { node: NODE, published: results });
  });

  server.listen(PORT, HOST, () => console.log(`push-server pub node=${NODE} http://${HOST}:${PORT}/bitrix/pub/`));
  return server;
}

(ROLE === 'sub' ? startSub() : startPub()).then((server) => {
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
}).catch((err) => {
  console.error('Không khởi động được:', err);
  process.exit(1);
});
