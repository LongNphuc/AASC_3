#!/usr/bin/env bash
# Thư viện dùng chung cho các run.sh của Phần 3.
# - Ghi toàn bộ lệnh và output ra logs/<tên-bài>-<thời-gian>.log (vừa hiện trên màn hình, vừa ghi file)
# - Mỗi lệnh được in kèm giờ chạy, để người đọc log thấy đúng thứ tự thao tác
# - Mật khẩu không bao giờ được in ra: lệnh dùng biến môi trường, output đi qua hàm mask

set -eEuo pipefail

SECRETS_DIR="$HOME/.aasc3"     # nơi giữ mật khẩu sinh ngẫu nhiên (chmod 600), không nằm trong thư mục nộp bài

# Bắt đầu ghi log. Gọi ở đầu mỗi run.sh, sau khi cd vào thư mục bài.
log_start() {
  local name
  name=$(basename "$PWD")
  mkdir -p logs
  LOG_FILE="logs/${name}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'rc=$?; echo; echo "!!! LỖI (mã thoát $rc) ở lệnh: ${LAST_CMD:-?}"' ERR
  echo "################################################################"
  echo "# Bài      : $name"
  echo "# Thời gian: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# Máy      : $(hostname) | $(cat /etc/rocky-release) | kernel $(uname -r)"
  echo "# User     : $(whoami)"
  echo "# Log      : $LOG_FILE"
  echo "################################################################"
  # Trang kết quả: chỉ chứa các lệnh chứng minh (gọi bằng key), để chụp một màn hình
  SUMMARY_FILE="logs/ket-qua.txt"
  {
    echo "######## KẾT QUẢ $name | $(date '+%Y-%m-%d %H:%M:%S %Z') ########"
    echo "# Máy: $(hostname) | $(cat /etc/rocky-release) | kernel $(uname -r) | user $(whoami)"
  } > "$SUMMARY_FILE"
}

# In tiêu đề một bước.
step() {
  CUR_STEP="$*"
  printf '\n================================================================\n'
  printf '== %s\n' "$*"
  printf '================================================================\n'
}

# Giống run, nhưng còn ghi lệnh và kết quả vào trang kết quả (logs/ket-qua.txt).
# Chỉ dùng cho các lệnh có output chứng minh yêu cầu của đề.
key() {
  LAST_CMD="$*"
  if [ "${KEY_STEP_SHOWN:-}" != "${CUR_STEP:-}" ]; then
    printf '== %s\n' "${CUR_STEP:-}" >> "$SUMMARY_FILE"
    KEY_STEP_SHOWN=${CUR_STEP:-}
  fi
  printf '\n[%s] $ %s\n' "$(date '+%H:%M:%S')" "$*"
  printf '$ %s\n' "$*" >> "$SUMMARY_FILE"
  eval "$@" 2>&1 | tee -a "$SUMMARY_FILE"
}

# In lệnh kèm giờ rồi chạy. Truyền lệnh dạng chuỗi trong nháy đơn để biến như
# $REDISCLI_AUTH được in nguyên văn (không lộ giá trị) và chỉ được thay khi chạy.
run() {
  LAST_CMD="$*"
  printf '\n[%s] $ %s\n' "$(date '+%H:%M:%S')" "$*"
  eval "$@"
}

# Đọc file AOF (định dạng RESP) từ stdin, in mỗi lệnh trên một dòng cho dễ đọc.
aof_to_commands() {
  tr -d '\r' | awk '/^\*[0-9]+$/ { if (cmd != "") print cmd; cmd = ""; next }
                    /^\$[0-9]+$/ { next }
                    { cmd = (cmd == "" ? $0 : cmd " " $0) }
                    END { if (cmd != "") print cmd }'
}

# Che mật khẩu trong output (đọc stdin).
mask() {
  local f expr=""
  for f in "$SECRETS_DIR"/*.pass; do
    [ -f "$f" ] && expr+="s/$(cat "$f")/<REDACTED>/g;"
  done
  if [ -n "$expr" ]; then sed -e "$expr"; else cat; fi
}

# Lấy (hoặc tạo mới) mật khẩu ngẫu nhiên cho một user Redis. Mật khẩu chỉ gồm chữ số hex
# để an toàn khi đưa vào sed và file cấu hình.
redis_password() {
  local user=$1 file="$SECRETS_DIR/redis-$1.pass"
  mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
  if [ ! -s "$file" ]; then
    (umask 077 && openssl rand -hex 24 > "$file")
  fi
  cat "$file"
}

# Đặt một tham số trong file cấu hình Redis: thay dòng đang có (không tính dòng comment),
# nếu chưa có thì thêm vào cuối file.
set_conf() {
  local file=$1 key=$2 value=$3
  if sudo grep -qE "^${key}[[:space:]]" "$file"; then
    sudo sed -i -E "s|^${key}[[:space:]].*|${key} ${value}|" "$file"
  else
    echo "${key} ${value}" | sudo tee -a "$file" >/dev/null
  fi
}

# Chờ Redis sẵn sàng sau khi start/restart (tối đa 30 giây).
wait_redis() {
  local i
  for i in $(seq 1 30); do
    if redis-cli "$@" ping 2>/dev/null | grep -q PONG; then return 0; fi
    sleep 1
  done
  echo "Redis không phản hồi sau 30 giây"; return 1
}
