#!/usr/bin/env bash
# Chạy trên WSL: đồng bộ thư mục part3 giữa WSL và máy ảo.
#   ./sync.sh push   đưa script lên máy ảo vào ~/aasc3/part3 (không đụng tới logs/ trên máy ảo)
#   ./sync.sh pull   lấy các thư mục logs/ của từng bài từ máy ảo về WSL
# Đổi máy đích bằng biến HOST, ví dụ: HOST=rocky-node1 ./sync.sh push
set -euo pipefail
HOST=${HOST:-rocky-ctl}
cd "$(dirname "$0")/../.."     # thư mục file_1

case "${1:-}" in
  push)
    tar czf - --exclude='logs' --exclude='node_modules' --exclude='__pycache__' part3 | ssh "$HOST" 'mkdir -p ~/aasc3 && tar xzf - -C ~/aasc3 && find ~/aasc3/part3 -name "*.sh" -exec chmod +x {} +'
    echo "Đã đưa part3 lên $HOST:~/aasc3/part3"
    ;;
  pull)
    ssh "$HOST" 'cd ~/aasc3 && find part3 -path "*/logs/*" -type f | tar czf - -T -' | tar xzvf -
    echo "Đã lấy logs từ $HOST về $(pwd)/part3"
    ;;
  *)
    echo "Cách dùng: $0 push|pull"; exit 1
    ;;
esac
