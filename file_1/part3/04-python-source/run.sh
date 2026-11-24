#!/usr/bin/env bash
# Bài 4 (Phần 3): cài Python 3.11 từ mã nguồn trên Rocky Linux 9 (make altinstall, không đụng python3 của hệ thống),
# cài pip, tạo virtualenv, cài gói requests, kiểm tra phiên bản.
# Cố ý cài 3.11.17 (bản ngay trước bản mới nhất 3.11.18) để Bài 9 có việc cập nhật thật bằng Ansible.
# Chạy trên máy ảo: cd ~/aasc3/part3/04-python-source && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

PY_VERSION=3.11.17
PY_SHA256=53cdee63ac4bf12387b7b33a53d3b1f8f4941cad73807a7b4fe91bb001ef004a   # lấy từ trang python.org/downloads/release/python-31117/
PY_URL=https://www.python.org/ftp/python/$PY_VERSION/Python-$PY_VERSION.tgz
BUILD_DIR=$HOME/build
VENV=$HOME/py311-venv
BUILD_DEPS="gcc make tar openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel sqlite-devel readline-devel ncurses-devel gdbm-devel libuuid-devel tk-devel"

step "1. Python đang có trên máy (python3 của hệ thống phải giữ nguyên vì dnf cần nó)"
run 'python3 --version; command -v python3; rpm -qf "$(readlink -f /usr/bin/python3)"'
run 'ls -l /usr/local/bin/python3.11 2>&1 || true'

step "2. Cài công cụ build và thư viện -devel (gdbm-devel nằm ở kho CRB)"
run "sudo dnf -y --enablerepo=crb install $BUILD_DEPS"

step "3. Tải mã nguồn $PY_VERSION và kiểm tra SHA-256"
run "mkdir -p $BUILD_DIR && (cd $BUILD_DIR && curl -fsSLO $PY_URL && ls -l Python-$PY_VERSION.tgz)"
key "(cd $BUILD_DIR && echo '$PY_SHA256  Python-$PY_VERSION.tgz' | sha256sum -c -)"
run "(cd $BUILD_DIR && rm -rf Python-$PY_VERSION && tar xzf Python-$PY_VERSION.tgz)"

step "4. configure (build bằng user thường, chỉ bước cài mới cần sudo)"
echo "Không bật --enable-optimizations/--with-lto: PGO chạy cả bộ test để lấy profile, trên máy 2 vCPU mất"
echo "nhiều lần thời gian build thường. Production nên bật (nhanh hơn khoảng 10-20%). Xem README."
run "(cd $BUILD_DIR/Python-$PY_VERSION && ./configure --prefix=/usr/local > $PWD/logs/configure.log 2>&1; tail -5 $PWD/logs/configure.log)"

step "5. make (toàn bộ output ở logs/make.log)"
key "(cd $BUILD_DIR/Python-$PY_VERSION && time make -j\$(nproc) > $PWD/logs/make.log 2>&1)"
key "grep -A8 -E 'necessary bits to build these optional modules|Failed to build these modules|Could not build the ssl module' logs/make.log || echo 'Không có module nào bị thiếu'"

step "6. make altinstall (cài python3.11, không tạo/ghi đè lệnh python3)"
run "(cd $BUILD_DIR/Python-$PY_VERSION && sudo make altinstall > $PWD/logs/install.log 2>&1; tail -3 $PWD/logs/install.log)"
key 'ls -l /usr/local/bin/ | grep -E "python3|pip3"'

step "7. Kiểm tra phiên bản và các module chuẩn"
key '/usr/local/bin/python3.11 -VV'
key 'command -v python3.11; python3 --version'
key 'python3.11 -c "import ssl, sqlite3, ctypes, lzma, bz2, readline, zlib, uuid, dbm.gnu, curses; print(\"Các module chuẩn OK |\", ssl.OPENSSL_VERSION)"'

step "8. pip và virtualenv, cài requests"
run 'python3.11 -m pip --version'
run "rm -rf $VENV && python3.11 -m venv $VENV"
run "$VENV/bin/python -m pip install --upgrade pip"
run "$VENV/bin/python -m pip install requests"
run "$VENV/bin/python --version && $VENV/bin/pip --version"
key "$VENV/bin/pip list"
run "$VENV/bin/pip list > logs/pip-list.txt"
key "$VENV/bin/python -c 'import requests, sys; r = requests.get(\"https://www.python.org\", timeout=10); print(sys.version.split()[0], \"| requests\", requests.__version__, \"| python.org ->\", r.status_code)'"

step "XONG Bài 4"
