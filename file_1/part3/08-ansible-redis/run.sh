#!/usr/bin/env bash
# Bài 8 (Phần 3): cài ansible-core bản còn hỗ trợ (2.21, chạy trên Python 3.12 như Phần 1 câu 9 khuyến nghị),
# rồi dùng playbook triển khai Redis 7.2 lên localhost. Chạy playbook nhiều lần để chứng minh tính idempotent
# và khả năng sửa lại cấu hình bị lệch.
# Chạy trên máy ảo: cd ~/aasc3/part3/08-ansible-redis && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

ANSIBLE_VENV=/opt/ansible-core-2.21
export PATH=$ANSIBLE_VENV/bin:$PATH
RECAP='grep -A2 "PLAY RECAP"'

step "1. Cài Python 3.12 (AppStream) và ansible-core 2.21 trong virtualenv"
run 'dnf -q list python3.12'
run 'sudo dnf -y install python3.12 python3.12-pip'
run "[ -d $ANSIBLE_VENV ] || sudo python3.12 -m venv $ANSIBLE_VENV"
run "sudo $ANSIBLE_VENV/bin/pip install -q --upgrade pip"
run "sudo $ANSIBLE_VENV/bin/pip install -q 'ansible-core>=2.21,<2.22'"
run "echo 'export PATH=$ANSIBLE_VENV/bin:\$PATH' | sudo tee /etc/profile.d/ansible-core.sh"
key 'ansible --version'
run 'ansible-galaxy collection install -r requirements.yml'
run 'ansible-galaxy collection list ansible.posix'

step "2. Gỡ bản Redis cài tay ở Bài 1-3 để chứng minh playbook dựng được từ đầu"
run '../tools/reset-redis.sh --yes 2>&1 | grep -vE "^\+ " | tail -3'
run 'rpm -q redis || true'

step "3. Kiểm tra cú pháp và inventory"
run 'cat playbook.yaml'
run 'ansible-playbook playbook.yaml --syntax-check'
run 'ansible-inventory --graph'
run 'ansible redis_servers -m ansible.builtin.ping'

step "4. Lần chạy 1: triển khai từ đầu"
run "ansible-playbook playbook.yaml | tee logs/run1.txt"
key 'grep -A1 "PLAY RECAP" logs/run1.txt | tail -1'

step "5. Kiểm tra Redis sau triển khai"
run 'sudo cat /etc/redis/redis.conf'
run 'sudo cat /etc/redis/users.acl'
run 'REDISCLI_AUTH=$(cat ~/.aasc3/redis-admin.pass) redis-cli --user admin CONFIG GET maxmemory*'
run 'REDISCLI_AUTH=$(cat ~/.aasc3/redis-admin.pass) redis-cli --user admin ACL LIST'
key 'REDISCLI_AUTH=$(cat ~/.aasc3/redis-reader.pass) redis-cli --user reader SET x 1'
run 'cat /sys/kernel/mm/transparent_hugepage/enabled; sysctl vm.overcommit_memory'

step "6. Lần chạy 2: không thay đổi gì (idempotent, phải thấy changed=0)"
key "ansible-playbook playbook.yaml | tee logs/run2.txt | $RECAP"
key 'grep -q "changed=0" logs/run2.txt && echo "=> ĐẠT: lần chạy 2 không thay đổi gì"'

step "7. Cố ý sửa tay redis.conf (lệch cấu hình), chạy lại với --diff để Ansible sửa về đúng"
run "sudo sed -i 's/^maxmemory-policy .*/maxmemory-policy noeviction/' /etc/redis/redis.conf"
key 'sudo grep "^maxmemory-policy" /etc/redis/redis.conf'
run "ansible-playbook playbook.yaml --diff | tee logs/run3-drift.txt"
key 'grep -E "^[-+]maxmemory-policy|^RUNNING HANDLER" logs/run3-drift.txt; grep -A1 "PLAY RECAP" logs/run3-drift.txt | tail -1'
key 'sudo grep "^maxmemory-policy" /etc/redis/redis.conf'

step "8. Lần chạy 4 ở chế độ --check (chạy thử, không thay đổi gì)"
key "ansible-playbook playbook.yaml --check | tee logs/run4-check.txt | $RECAP"

step "9. Lưu cấu hình được sinh ra để nộp"
run 'sudo cat /etc/redis/redis.conf > logs/redis.conf'
run 'sudo cat /etc/redis/users.acl > logs/users.acl'

step "XONG Bài 8"
