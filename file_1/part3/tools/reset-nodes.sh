#!/usr/bin/env bash
# Chạy trên rocky-ctl: gỡ những gì Bài 10 cài lên các node (push-server, Node.js), để chạy lại Bài 10 từ đầu.
# Danh sách node lấy từ 10-bitrix-cluster/inventory.ini. SSH key của rocky-ctl trên các node được giữ lại.
set -euo pipefail
INV="$(cd "$(dirname "$0")/.." && pwd)/10-bitrix-cluster/inventory.ini"
NODES=$(awk '/^\[push_servers\]/{f=1; next} /^\[/{f=0} f && /ansible_host=/ {for (i = 1; i <= NF; i++) if ($i ~ /^ansible_host=/) {sub("ansible_host=", "", $i); print $i}}' "$INV")
for ip in $NODES; do
  echo "== Dọn $ip"
  ssh -o BatchMode=yes "rocky@$ip" 'set -x
    sudo systemctl disable --now push-server@sub push-server@pub 2>/dev/null || true
    sudo rm -rf /opt/push-server /etc/systemd/system/push-server@.service
    sudo userdel pushsrv 2>/dev/null || true
    sudo dnf -y -q remove nodejs npm 2>/dev/null || true
    sudo dnf -y -q module reset nodejs
    sudo systemctl daemon-reload' 2>&1 | grep -v "^+ " || true
done
echo "Đã dọn xong các node: $NODES"
