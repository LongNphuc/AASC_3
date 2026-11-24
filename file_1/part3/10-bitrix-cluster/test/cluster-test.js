// Bài 10 (Phần 3): client kiểm thử cụm push-server.
// Mở CLIENTS kết nối WebSocket chia đều cho các node (biến SUB_URLS, cách nhau bởi dấu phẩy), cùng nghe một kênh.
// In "READY" khi tất cả đã kết nối, rồi chờ đủ EXPECT tin (backend Python gửi qua pub của các node).
// Kết quả ĐẠT khi mọi client, dù nối vào node nào, nhận đủ mọi tin, kể cả tin đi vào qua node khác.
'use strict';

const { WebSocket } = require('ws');

const SUB_URLS = (process.env.SUB_URLS || 'ws://127.0.0.1:8010').split(',');
const CHANNEL = process.env.CHANNEL || 'chat.general';
const CLIENTS = Number(process.env.CLIENTS || 200);
const EXPECT = Number(process.env.EXPECT || 10);
const WAIT_MS = Number(process.env.WAIT_MS || 30000);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(i) {
  const base = SUB_URLS[i % SUB_URLS.length];
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${base}/bitrix/subws/?CHANNEL_ID=${CHANNEL}`);
    const client = { ws, base, node: null, got: [] };
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw);
      if (msg.type === 'hello') {
        client.node = msg.node;
        resolve(client);
      } else if (msg.type === 'message') {
        client.got.push(msg);
      }
    });
    ws.on('error', reject);
  });
}

async function main() {
  const clients = await Promise.all(Array.from({ length: CLIENTS }, (_, i) => connect(i)));
  const perNode = clients.reduce((m, c) => ({ ...m, [c.node]: (m[c.node] || 0) + 1 }), {});
  console.log(`Đã kết nối ${clients.length} client vào kênh ${CHANNEL}:`, JSON.stringify(perNode));
  console.log('READY');

  const deadline = Date.now() + WAIT_MS;
  while (Date.now() < deadline && !clients.every((c) => c.got.length >= EXPECT)) await sleep(100);

  const viaCount = {};
  for (const c of clients) {
    for (const m of c.got) {
      const key = `client@${c.node} <- pub@${m.via}`;
      viaCount[key] = (viaCount[key] || 0) + 1;
    }
  }
  const complete = clients.filter((c) => c.got.length === EXPECT).length;
  console.log('Số lượt nhận theo đường đi (client nối vào node nào <- tin vào qua pub của node nào):');
  Object.entries(viaCount).sort().forEach(([k, v]) => console.log(`  ${k.padEnd(40)} ${v}`));
  console.log(`Client nhận đủ ${EXPECT}/${EXPECT} tin: ${complete}/${clients.length}`);

  clients.forEach((c) => c.ws.close());
  const ok = complete === clients.length;
  console.log(ok ? '=> ĐẠT: tin đi qua bất kỳ node nào cũng tới mọi client trên mọi node' : '=> KHÔNG ĐẠT');
  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error('Lỗi:', err.message);
  process.exit(1);
});
