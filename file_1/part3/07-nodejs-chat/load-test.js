// Bài 7 (Phần 3): kiểm thử tải cho chat server.
// 1. Mở 1000 kết nối WebSocket cùng lúc
// 2. Cả 1000 client gửi ping cùng lúc, đo thời gian khứ hồi (RTT)
// 3. 10 client gửi tin chat, kiểm tra cả 1000 client đều nhận đủ 10 tin (10.000 lượt phát)
// 4. Đọc /stats của server khi đang có 1000 kết nối, rồi đóng hết
'use strict';

const { WebSocket } = require('ws');

const URL = process.env.CHAT_URL || 'ws://127.0.0.1:8080/chat';
const STATS_URL = URL.replace(/^ws/, 'http').replace(/\/chat$/, '/stats');
const N = Number(process.env.CLIENTS || 1000);
const SENDERS = 10;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (arr, p) => arr[Math.min(arr.length - 1, Math.floor((p / 100) * arr.length))];

function open(i) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    ws.chatCount = 0;
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
    ws.on('message', (data) => {
      const msg = JSON.parse(data);
      if (msg.type === 'chat') ws.chatCount += 1;
      if (msg.type === 'pong' && ws.onPong) ws.onPong(msg);
    });
  });
}

async function main() {
  console.log(`Kết nối tới ${URL}, số client: ${N}`);

  let t0 = performance.now();
  const clients = await Promise.all(Array.from({ length: N }, (_, i) => open(i)));
  console.log(`[1] Mở ${clients.length} kết nối đồng thời mất ${(performance.now() - t0).toFixed(0)} ms`);

  t0 = performance.now();
  const rtts = await Promise.all(clients.map((ws) => new Promise((resolve) => {
    const sent = performance.now();
    ws.onPong = () => resolve(performance.now() - sent);
    ws.send(JSON.stringify({ type: 'ping', t: sent }));
  })));
  rtts.sort((a, b) => a - b);
  console.log(`[2] ${rtts.length} ping đồng thời xong sau ${(performance.now() - t0).toFixed(0)} ms | ` +
              `RTT p50=${pct(rtts, 50).toFixed(1)} ms, p95=${pct(rtts, 95).toFixed(1)} ms, max=${rtts.at(-1).toFixed(1)} ms`);

  t0 = performance.now();
  for (let s = 0; s < SENDERS; s += 1) {
    clients[s].send(JSON.stringify({ type: 'chat', from: `user-${s}`, text: `xin chào lần ${s}` }));
  }
  const expected = N * SENDERS;
  let received = 0;
  for (let i = 0; i < 100 && received < expected; i += 1) {
    await sleep(50);
    received = clients.reduce((sum, ws) => sum + ws.chatCount, 0);
  }
  const allGotAll = clients.every((ws) => ws.chatCount === SENDERS);
  console.log(`[3] ${SENDERS} tin chat -> ${received}/${expected} lượt phát tới client sau ${(performance.now() - t0).toFixed(0)} ms; ` +
              `mọi client nhận đủ ${SENDERS} tin: ${allGotAll ? 'ĐÚNG' : 'SAI'}`);

  const stats = await (await fetch(STATS_URL)).json();
  console.log('[4] /stats khi đang có kết nối:', JSON.stringify(stats));

  clients.forEach((ws) => ws.close());
  await sleep(1000);
  const after = await (await fetch(STATS_URL)).json();
  console.log(`[5] Sau khi đóng: connections=${after.connections}, peak_connections=${after.peak_connections}`);

  const ok = clients.length === N && allGotAll && stats.connections >= N;
  console.log(ok ? `=> ĐẠT: server phục vụ ${N} kết nối đồng thời` : '=> KHÔNG ĐẠT');
  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error('Lỗi kiểm thử:', err);
  process.exit(1);
});
