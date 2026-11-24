#!/usr/bin/env bash
# Bài 2 (Phần 3): tối ưu Redis cho hiệu năng.
#   - maxmemory = 80% RAM (CONFIG SET + CONFIG REWRITE để ghi lại vào redis.conf)
#   - tinh chỉnh hệ điều hành: tắt Transparent Huge Pages, bật vm.overcommit_memory=1
#   - đo thời gian gửi 100 lệnh SET có và không có pipelining (bench_pipeline.py), kèm redis-benchmark
#   - so sánh DEL và UNLINK khi xóa key lớn (bigkey_unlink.py)
# Yêu cầu: đã chạy Bài 1. Chạy: cd ~/aasc3/part3/02-redis-performance && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

CONF=/etc/redis/redis.conf
VENV=$HOME/aasc3-venv
export REDISCLI_AUTH
REDISCLI_AUTH=$(redis_password default)

step "1. Tính maxmemory = 80% RAM và áp dụng khi Redis đang chạy"
run 'free -h'
MEM_BYTES=$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)
MAXMEM=$(( MEM_BYTES * 80 / 100 ))
key "echo 'MemTotal = $MEM_BYTES byte  =>  maxmemory (80%) = $MAXMEM byte ($(( MAXMEM / 1024 / 1024 )) MB)'"
run 'redis-cli CONFIG GET maxmemory'
run "redis-cli CONFIG SET maxmemory $MAXMEM"
run 'redis-cli CONFIG SET maxmemory-policy allkeys-lru'
run 'redis-cli CONFIG REWRITE'
key "sudo grep -nE '^(maxmemory|maxmemory-policy) ' $CONF"
run 'redis-cli INFO memory | tr -d "\r" | grep -E "^(used_memory_human|maxmemory_human|maxmemory_policy):"'

step "2. Tinh chỉnh hệ điều hành: tắt THP, bật overcommit"
key 'cat /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag'
key 'sysctl vm.overcommit_memory'
run 'sudo grep -E "WARNING.*(overcommit|Transparent)" /var/log/redis/redis.log | tail -2 || true'
run 'sudo tee /etc/systemd/system/disable-thp.service >/dev/null <<EOF
[Unit]
Description=Tắt Transparent Huge Pages cho Redis
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=redis.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=basic.target
EOF'
run 'sudo systemctl daemon-reload'
run 'sudo systemctl enable --now disable-thp.service'
run 'echo "vm.overcommit_memory = 1" | sudo tee /etc/sysctl.d/99-redis.conf'
key 'sudo sysctl -p /etc/sysctl.d/99-redis.conf'
key 'cat /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag'
run 'sudo systemctl restart redis'
wait_redis
key 'sudo tail -n 30 /var/log/redis/redis.log | grep -E "WARNING|Server initialized|Ready to accept" || true'
run 'redis-cli CONFIG GET maxmemory'

step "3. Chuẩn bị Python (venv + redis-py) cho script đo"
run 'sudo dnf -y install python3-pip'
run "[ -d $VENV ] || python3 -m venv $VENV"
run "$VENV/bin/pip install -q --upgrade pip"
run "$VENV/bin/pip install -q redis"
run "$VENV/bin/python --version && $VENV/bin/pip show redis | grep -E '^(Name|Version):'"

step "4. Đo 100 lệnh SET: không pipelining và có pipelining"
run 'cat bench_pipeline.py'
key "$VENV/bin/python bench_pipeline.py"

step "5. Đối chiếu bằng redis-benchmark (100.000 lệnh SET, -P 1 so với -P 100)"
key 'redis-benchmark -a "$REDISCLI_AUTH" -q -t set -n 100000 -P 1 2>&1 | tr "\r" "\n" | grep "requests per second"'
key 'redis-benchmark -a "$REDISCLI_AUTH" -q -t set -n 100000 -P 100 2>&1 | tr "\r" "\n" | grep "requests per second"'
run 'redis-cli UNLINK key:__rand_int__'

step "6. Xóa key lớn: DEL so với UNLINK"
key "$VENV/bin/python bigkey_unlink.py"
run 'redis-cli CONFIG GET lazyfree-lazy-user-del'
run 'redis-cli INFO memory | tr -d "\r" | grep -E "^(used_memory_human|maxmemory_human):"'

step "7. Lưu cấu hình sau tinh chỉnh (mật khẩu đã che)"
run "sudo cat $CONF | mask > logs/redis.conf"
run 'grep -vE "^[[:space:]]*(#|$)" logs/redis.conf'

step "XONG Bài 2"
