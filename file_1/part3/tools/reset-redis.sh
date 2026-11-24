#!/usr/bin/env bash
# Đưa máy ảo về trạng thái chưa cài Redis, để chạy lại Bài 1-3 từ đầu cho log sạch.
# Xóa: gói redis, cấu hình, dữ liệu, log, mật khẩu Redis đã sinh, venv, các tinh chỉnh OS của Bài 2.
# Chạy trên máy ảo: ~/aasc3/part3/tools/reset-redis.sh [--yes]   (nên reboot sau khi chạy để THP về mặc định)
# --yes: không hỏi lại (Bài 8 dùng để gỡ bản Redis cài tay trước khi cho Ansible dựng lại từ đầu)
set -euo pipefail
if [ "${1:-}" != "--yes" ]; then
  echo "Sẽ xóa toàn bộ Redis và dữ liệu Redis trên $(hostname). Gõ YES để tiếp tục:"
  read -r answer
  [ "$answer" = "YES" ] || { echo "Hủy."; exit 1; }
fi
set -x
sudo systemctl disable --now redis 2>/dev/null || true
sudo dnf -y remove redis
sudo dnf -y module reset redis
sudo rm -rf /etc/redis /var/lib/redis /var/log/redis
sudo systemctl disable --now disable-thp.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/disable-thp.service /etc/sysctl.d/99-redis.conf
sudo systemctl daemon-reload
rm -f "$HOME"/.aasc3/redis-*.pass
rm -rf "$HOME/aasc3-venv"
set +x
echo "Đã xóa xong Redis."
