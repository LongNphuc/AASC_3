#!/usr/bin/env bash
# Bài 7 (Phần 3): cài Node.js 20 từ AppStream (module nodejs:20), chạy chat server WebSocket bằng systemd,
# kiểm thử 1000 kết nối đồng thời trên một event loop.
# Chạy trên máy ảo: cd ~/aasc3/part3/07-nodejs-chat && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

APP_DIR=/opt/chat-server

step "1. Cài Node.js 20 (module nodejs:20 của AppStream)"
run 'sudo dnf -y module list nodejs'
run 'sudo dnf -y module reset nodejs'
run 'sudo dnf -y module enable nodejs:20'
run 'sudo dnf -y install nodejs npm'
key 'node --version && npm --version'
echo "Lưu ý: Node.js 20 đã hết hỗ trợ (EOL) từ 30/04/2026. Bài làm dùng 20 theo đúng đề;"
echo "hệ thống thật nên dùng module nodejs:22 hoặc nodejs:24 (cùng cách cài, chỉ đổi số stream)."

step "2. Triển khai ứng dụng vào $APP_DIR, chạy bằng user hệ thống riêng"
run 'id chatsrv 2>/dev/null || sudo useradd --system --no-create-home --shell /sbin/nologin chatsrv'
run "sudo mkdir -p $APP_DIR && sudo cp server.js load-test.js package.json $APP_DIR/"
run "[ -f package-lock.json ] && sudo cp package-lock.json $APP_DIR/ || true"
run "(cd $APP_DIR && if [ -f package-lock.json ]; then sudo npm ci --omit=dev; else sudo npm install --omit=dev; fi)"
run "cp $APP_DIR/package-lock.json logs/package-lock.json"
run "sudo chown -R root:chatsrv $APP_DIR && ls -l $APP_DIR"

step "3. Chạy bằng systemd (LimitNOFILE=65535 để giữ được hàng nghìn kết nối)"
run 'cat chat-server.service'
run 'sudo cp chat-server.service /etc/systemd/system/chat-server.service'
run 'sudo systemctl daemon-reload'
run 'sudo systemctl enable chat-server'
run 'sudo systemctl restart chat-server'
run 'sleep 1; systemctl status chat-server --no-pager | head -12'
key 'systemctl is-active chat-server'
key 'sudo ss -tlnp | grep 8080'
key 'grep "open files" /proc/$(systemctl show -p MainPID --value chat-server)/limits'
run 'curl -s http://127.0.0.1:8080/stats; echo'

step "4. Kiểm thử 1000 kết nối đồng thời"
run 'ulimit -n'
echo "Client kiểm thử mở 1000 socket trong một tiến trình nên nâng giới hạn file của riêng tiến trình đó lên 4096."
key "(ulimit -n 4096 && cd $APP_DIR && node load-test.js)"

step "5. Tài nguyên server: một tiến trình, vài luồng nội bộ của V8/libuv"
key 'ps -o pid,nlwp,rss,etime,cmd -p "$(systemctl show -p MainPID --value chat-server)"'
run 'sudo journalctl -u chat-server --no-pager -n 8'

step "XONG Bài 7"
