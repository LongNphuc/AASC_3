#!/usr/bin/env bash
# Bài 6 (Phần 3): chạy script gây ZeroDivisionError trong biểu thức lồng nhau, ghi lại traceback.
# So sánh Python 3.11 (Bài 4) với Python 3.9 có sẵn của Rocky Linux 9 để thấy điểm cải tiến.
# Chạy trên máy ảo: cd ~/aasc3/part3/06-python-traceback && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

step "1. Mã nguồn script.py"
run 'cat -n script.py'

step "2. Python 3.11: traceback đánh dấu đúng phép chia gây lỗi, kèm ghi chú add_note()"
key 'python3.11 --version'
key 'python3.11 script.py 2>&1 | tee logs/traceback-python311.txt || echo "=> script thoát với mã $? (đúng như mong đợi)"'

step "3. Python 3.9 (python3 của hệ thống) với cùng script: chỉ có số dòng"
key '/usr/bin/python3 --version'
key '/usr/bin/python3 script.py 2>&1 | tee logs/traceback-python39.txt || echo "=> script thoát với mã $? (đúng như mong đợi)"'

step "4. Python 3.11 khi tắt thông tin vị trí cột (-X no_debug_ranges): quay lại kiểu cũ"
run 'python3.11 -X no_debug_ranges script.py 2>&1 | tail -5 || true'

step "XONG Bài 6"
