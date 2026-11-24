#!/usr/bin/env bash
# Bài 5 (Phần 3): asyncio.TaskGroup chạy 5 tác vụ tải URL không đồng bộ, timeout 5 giây.
# Yêu cầu: đã chạy Bài 4 (có Python 3.11 và venv ~/py311-venv).
# Chạy trên máy ảo: cd ~/aasc3/part3/05-python-taskgroup && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

VENV=$HOME/py311-venv

step "1. Môi trường Python 3.11 (venv từ Bài 4) và thư viện HTTP bất đồng bộ aiohttp"
key "$VENV/bin/python --version"
run "$VENV/bin/python -m pip install aiohttp"
run "$VENV/bin/pip list | grep -iE '^(aiohttp|requests) '"

step "2. Mã nguồn script.py"
run 'cat script.py'

step "3. Chạy script.py"
key "time $VENV/bin/python script.py"

step "XONG Bài 5"
