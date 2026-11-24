#!/usr/bin/env bash
# Đưa rocky-ctl về trạng thái trước Bài 1 (như lúc vừa tạo image rocky9-base), để chạy lại Bài 1-10 cho log sạch.
# Gỡ: Redis (Bài 1-3, 8), Python 3.11 tự build (Bài 4, 9), Node.js + chat-server (Bài 7), ansible-core (Bài 8),
#      push-server nếu có (Bài 10), mật khẩu đã sinh, log của các bài.
# Không đụng tới: python3 của hệ thống, các gói có sẵn trong image, SSH key.
# Chạy trên máy ảo: ~/aasc3/part3/tools/reset-all.sh [--yes]   rồi: sudo reboot
set -euo pipefail
if [ "${1:-}" != "--yes" ]; then
  echo "Sẽ gỡ mọi thứ đã cài trong Bài 1-10 trên $(hostname). Gõ YES để tiếp tục:"
  read -r answer
  [ "$answer" = "YES" ] || { echo "Hủy."; exit 1; }
fi
HERE=$(cd "$(dirname "$0")" && pwd)
set -x
# Bài 1-3, 8: Redis
"$HERE/reset-redis.sh" --yes
# Bài 10: push-server (nếu từng chạy thử trên máy này)
sudo systemctl disable --now push-server@sub push-server@pub 2>/dev/null || true
sudo rm -rf /opt/push-server /etc/systemd/system/push-server@.service
sudo userdel pushsrv 2>/dev/null || true
# Bài 7: chat-server và Node.js
sudo systemctl disable --now chat-server 2>/dev/null || true
sudo rm -rf /opt/chat-server /etc/systemd/system/chat-server.service
sudo userdel chatsrv 2>/dev/null || true
sudo dnf -y remove nodejs npm nodejs-full-i18n 2>/dev/null || true
sudo dnf -y module reset nodejs
# Bài 4, 9: Python 3.11 cài bằng make altinstall vào /usr/local
sudo rm -rf /usr/local/bin/python3.11 /usr/local/bin/python3.11-config /usr/local/bin/pip3.11 \
  /usr/local/bin/pydoc3.11 /usr/local/bin/idle3.11 /usr/local/bin/2to3-3.11 \
  /usr/local/lib/python3.11 /usr/local/lib/libpython3.11.a /usr/local/lib/pkgconfig/python-3.11*.pc \
  /usr/local/include/python3.11 /usr/local/share/man/man1/python3.11.1 /usr/local/src/Python-3.11.*
sudo rm -rf "$HOME/build" "$HOME/py311-venv"   # build/ có file do "sudo make altinstall" tạo, chủ sở hữu là root
# Bài 8: ansible-core trong virtualenv Python 3.12, collection đã cài
sudo rm -rf /opt/ansible-core-2.21 /etc/profile.d/ansible-core.sh
rm -rf "$HOME/.ansible"
sudo dnf -y remove python3.12 python3.12-pip python3.12-libs python3.12-pip-wheel 2>/dev/null || true
# Mật khẩu, log, file tạm của các bài
rm -rf "$HOME/.aasc3" /tmp/aasc3-*.txt /tmp/cluster-test*.out /tmp/cluster-test*.pid
rm -rf "$HOME"/aasc3/part3/*/logs "$HOME"/aasc3/part3/*/test/node_modules
sudo systemctl daemon-reload
set +x
echo "Đã gỡ xong. Chạy: sudo reboot"
