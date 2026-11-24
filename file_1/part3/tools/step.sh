#!/usr/bin/env bash
# In riêng một (hoặc vài) bước trong log mới nhất của bài đang đứng, kèm dòng tiêu đề, để chụp màn hình.
# Cách dùng (đứng trong thư mục bài):
#   ../tools/step.sh 7              in bước 7
#   ../tools/step.sh 3 4            in từ bước 3 đến hết bước 4
#   TAIL=25 ../tools/step.sh 1      chỉ in 25 dòng cuối của bước (vẫn giữ tiêu đề), dùng cho bước có output dài
set -euo pipefail
from=${1:?Cần số bước, ví dụ: ../tools/step.sh 7}
to=${2:-$from}
f=$(ls -t logs/*-[0-9]*.log 2>/dev/null | head -1 || true)
[ -n "$f" ] || { echo "Chưa có log trong $(pwd)/logs"; exit 1; }

grep -E "^# (Bài|Thời gian|Máy)[ :]" "$f" | head -3
section=$(awk -v a="$from" -v b="$to" '
  /^== XONG/ { show = 0; next }
  /^== [0-9]+\./ { split($2, p, "."); n = p[1] + 0; show = (n >= a && n <= b) }
  show && !/^=+$/' "$f")

if [ -n "${TAIL:-}" ]; then
  printf '%s\n' "$section" | head -1
  echo "   (... lược bớt phần đầu của bước, xem đầy đủ trong $f ...)"
  printf '%s\n' "$section" | tail -n "$TAIL"
else
  printf '%s\n' "$section"
fi
