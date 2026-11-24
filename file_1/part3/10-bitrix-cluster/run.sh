#!/usr/bin/env bash
# Bài 10 (Phần 3): cụm Bitrix24 On-Premise mô phỏng trên 3 máy, triển khai bằng Ansible và kiểm thử tích hợp:
#   backend Python 3.11 (rocky-ctl) --HTTP ký HMAC--> push-server pub (node1/node2) --Redis PUBLISH-->
#   push-server sub (mọi node) --WebSocket--> client.
# Yêu cầu: đã chạy Bài 4, 7, 8, 9; đã tạo rocky-node1, rocky-node2, điền IP vào inventory.ini,
# và rocky-ctl SSH được vào 2 node (xem README mục "Chuẩn bị").
# Chạy trên rocky-ctl: cd ~/aasc3/part3/10-bitrix-cluster && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

export PATH=/opt/ansible-core-2.21/bin:$PATH
PY=$HOME/py311-venv/bin/python
NODE_IPS=$(ansible-inventory --list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(d["_meta"]["hostvars"][h]["ansible_host"] for h in d["push_servers"]["hosts"]))')
SUB_URLS=$(for ip in $NODE_IPS; do printf 'ws://%s:8010,' "$ip"; done | sed 's/,$//')
PUB_URLS=$(for ip in $NODE_IPS; do printf 'http://%s:9010,' "$ip"; done | sed 's/,$//')
ADMIN='REDISCLI_AUTH=$(cat ~/.aasc3/redis-admin.pass) redis-cli --user admin'

step "1. Inventory và kết nối tới các máy"
run 'cat inventory.ini'
run 'ansible-inventory --graph'
run "for ip in $NODE_IPS; do ssh-keygen -F \$ip >/dev/null || ssh-keyscan -T 5 -t ed25519 \$ip 2>/dev/null >> ~/.ssh/known_hosts; done"
key 'ansible all -m ansible.builtin.ping | grep -E "\| (SUCCESS|UNREACHABLE|FAILED)"'
run 'ansible all -m ansible.builtin.command -a "cat /etc/rocky-release"'

step "2. Lần chạy 1: dựng toàn bộ cụm"
run 'ansible-playbook site.yml | tee logs/run1.txt'
key 'grep -A4 "PLAY RECAP" logs/run1.txt | grep -E "^rocky"'

step "3. Lần chạy 2: không thay đổi gì (idempotent)"
key 'ansible-playbook site.yml | tee logs/run2.txt | grep -A4 "PLAY RECAP"'
key 'grep -E "^(rocky-ctl|rocky-node)" logs/run2.txt | grep -v "changed=0" || echo "=> ĐẠT: mọi máy đều changed=0"'

step "4. Trạng thái dịch vụ trên các node và Redis"
run 'ansible push_servers -b -m ansible.builtin.shell -a "systemctl is-active push-server@sub push-server@pub; ss -tlnp | grep -E \":(8010|9010) \""'
run "$ADMIN ACL GETUSER pushserver | paste - - | head -6"
key "$ADMIN CLIENT LIST | awk '/user=pushserver/ { for (i = 1; i <= NF; i++) if (\$i ~ /^(addr|cmd|user)=/) printf \"%s \", \$i; print \"\" }'"

step "5. Kiểm thử tích hợp: 200 client chia đều 2 node, backend gửi 10 tin xoay vòng qua pub của 2 node"
run '(cd test && npm ci --no-audit --no-fund)'
run "rm -f /tmp/cluster-test.out; (cd test && SUB_URLS=$SUB_URLS CLIENTS=200 EXPECT=10 exec node cluster-test.js > /tmp/cluster-test.out 2>&1) & echo \$! > /tmp/cluster-test.pid; for i in \$(seq 150); do grep -qE 'READY|Lỗi' /tmp/cluster-test.out && break; sleep 0.2; done; cat /tmp/cluster-test.out"
run "PUSH_SECURITY_KEY=\$(cat ~/.aasc3/push-security.key) $PY backend/backend.py --pub $PUB_URLS --count 10"
key 'while kill -0 "$(cat /tmp/cluster-test.pid)" 2>/dev/null; do sleep 0.5; done; sed "1,2d" /tmp/cluster-test.out'
run 'grep -q "=> ĐẠT" /tmp/cluster-test.out'

step "6. Bảo mật: tin gửi với chữ ký sai bị push-server từ chối (HTTP 403)"
key "PUSH_SECURITY_KEY=\$(cat ~/.aasc3/push-security.key) $PY backend/backend.py --pub $PUB_URLS --bad-signature"

step "7. Redis lưu lịch sử kênh (3 tin gần nhất)"
run "$ADMIN LLEN push:history:chat.general"
run "$ADMIN LRANGE push:history:chat.general 0 2"

step "8. Chịu lỗi: tắt tiến trình sub của node2, client trên node1 vẫn nhận tin gửi qua pub của node2"
NODE1_SUB=${SUB_URLS%%,*}
key 'ansible rocky-node2 -b -m ansible.builtin.command -a "systemctl stop push-server@sub"'
key 'ansible rocky-node2 -b -m ansible.builtin.shell -a "systemctl is-active push-server@sub || true"'
run "rm -f /tmp/cluster-test2.out; (cd test && SUB_URLS=$NODE1_SUB CLIENTS=50 EXPECT=5 exec node cluster-test.js > /tmp/cluster-test2.out 2>&1) & echo \$! > /tmp/cluster-test2.pid; for i in \$(seq 150); do grep -qE 'READY|Lỗi' /tmp/cluster-test2.out && break; sleep 0.2; done"
run "PUSH_SECURITY_KEY=\$(cat ~/.aasc3/push-security.key) $PY backend/backend.py --pub ${PUB_URLS##*,} --count 5"
key 'while kill -0 "$(cat /tmp/cluster-test2.pid)" 2>/dev/null; do sleep 0.5; done; cat /tmp/cluster-test2.out'
key 'ansible-playbook site.yml --limit rocky-node2 | grep -A2 "PLAY RECAP"'
key 'ansible rocky-node2 -b -m ansible.builtin.command -a "systemctl is-active push-server@sub"'

step "9. Thống kê cuối của từng push-server"
run "for ip in $NODE_IPS; do for p in 8010 9010; do curl -s http://\$ip:\$p/server-stat; echo; done; done"

step "XONG Bài 10"
