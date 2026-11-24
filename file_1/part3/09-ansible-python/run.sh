#!/usr/bin/env bash
# Bài 9 (Phần 3): dùng Ansible cập nhật Python 3.11 (3.11.17 -> 3.11.18) trên máy chủ, chạy playbook
# nhiều lần để chứng minh idempotent: lần 1 build và cài, các lần sau changed=0.
# Yêu cầu: đã chạy Bài 4 (có 3.11.17) và Bài 8 (có ansible-core).
# Chạy trên máy ảo: cd ~/aasc3/part3/09-ansible-python && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

export PATH=/opt/ansible-core-2.21/bin:$PATH
RECAP='grep -A2 "PLAY RECAP"'

step "1. Trạng thái trước khi cập nhật"
run 'ansible --version | head -1'
key 'python3.11 --version'
key '~/py311-venv/bin/python --version'
run 'cat ../roles/python311/defaults/main.yml'
run 'cat ../roles/python311/tasks/main.yml'
run 'cat playbook.yaml'
run 'ansible-playbook playbook.yaml --syntax-check'

step "2. Lần chạy 1: phát hiện 3.11.17 khác mục tiêu 3.11.18 -> build và cài"
run "ansible-playbook playbook.yaml | tee logs/run1.txt"
key 'grep -E "python3.11 hệ thống|venv ~/py311-venv" logs/run1.txt | sed "s/^ *//"'
key 'python3.11 --version; ~/py311-venv/bin/python --version'

step "3. Lần chạy 2: đã đúng phiên bản, không build lại (phải thấy changed=0)"
run "ansible-playbook playbook.yaml | tee logs/run2.txt"
key 'grep -q "changed=0" logs/run2.txt && echo "=> ĐẠT: lần chạy 2 không thay đổi gì"'

step "4. Lần chạy 3: chạy thêm lần nữa, vẫn changed=0"
run "ansible-playbook playbook.yaml | tee logs/run3.txt | $RECAP"
key 'grep -q "changed=0" logs/run3.txt && echo "=> ĐẠT: lần chạy 3 không thay đổi gì"'

step "5. Tổng hợp PLAY RECAP của 3 lần chạy"
key 'for f in logs/run1.txt logs/run2.txt logs/run3.txt; do echo "--- $f"; grep -A1 "PLAY RECAP" "$f" | tail -1; done'

step "XONG Bài 9"
