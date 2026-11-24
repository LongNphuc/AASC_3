#!/usr/bin/env bash
# Bài 3 (Phần 3): phân quyền Redis bằng ACL.
#   - chuyển từ requirepass sang file ACL (/etc/redis/users.acl); Redis không cho dùng cả hai cùng lúc
#   - tạo 3 user: admin (toàn quyền), app (ứng dụng, cấm lệnh nguy hiểm và Lua), reader (chỉ đọc)
#   - tắt user default, thử các lệnh bị chặn, xem ACL LOG, restart để kiểm tra ACL được lưu
# Yêu cầu: đã chạy Bài 1. Chạy: cd ~/aasc3/part3/03-redis-acl && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

CONF=/etc/redis/redis.conf
ACLFILE=/etc/redis/users.acl
DEFAULT_PASS=$(redis_password default)
ADMIN_PASS=$(redis_password admin)
APP_PASS=$(redis_password app)
READER_PASS=$(redis_password reader)

# Gọi redis-cli với từng user; mật khẩu đi qua biến môi trường, không xuất hiện trên dòng lệnh.
as_default() { REDISCLI_AUTH=$DEFAULT_PASS redis-cli "$@"; }
as_admin()   { REDISCLI_AUTH=$ADMIN_PASS   redis-cli --user admin  "$@"; }
as_app()     { REDISCLI_AUTH=$APP_PASS     redis-cli --user app    "$@"; }
as_reader()  { REDISCLI_AUTH=$READER_PASS  redis-cli --user reader "$@"; }

step "1. Trạng thái trước khi đổi: chỉ có user default dùng requirepass"
run 'as_default ACL LIST | mask'
run "sudo grep -nE '^(requirepass|aclfile) ' $CONF | mask"

step "2. Chuyển sang file ACL"
echo "File ACL ban đầu chỉ chứa user default với mã băm SHA-256 của mật khẩu hiện tại,"
echo "để Redis vẫn được bảo vệ ngay khi khởi động lại với file ACL."
DEFAULT_HASH=$(printf '%s' "$DEFAULT_PASS" | sha256sum | cut -d' ' -f1)
run "echo 'user default on #$DEFAULT_HASH ~* &* +@all' | sudo install -o redis -g root -m 640 /dev/stdin $ACLFILE"
run "sudo restorecon -v $ACLFILE"
run "sudo sed -i -E 's/^requirepass .*/# requirepass: đã chuyển sang aclfile (Bài 3)/' $CONF"
echo "CONFIG REWRITE (Bài 2) có ghi user default vào redis.conf; phải xóa dòng 'user ...' vì Redis"
echo "không cho khai báo user ở cả redis.conf lẫn aclfile."
run "sudo sed -i -E '/^user /d' $CONF"
run "echo 'aclfile $ACLFILE' | sudo tee -a $CONF"
run "sudo grep -nE '^(# requirepass|requirepass|user|aclfile) ' $CONF || true"
run 'sudo systemctl restart redis'
REDISCLI_AUTH=$DEFAULT_PASS wait_redis
run 'as_default ACL LIST'

step "3. Tạo user admin, app, reader"
run 'as_default ACL SETUSER admin on ">$ADMIN_PASS" "~*" "&*" +@all'
run 'as_default ACL SETUSER app on ">$APP_PASS" "~*" "&*" +@all -@dangerous -@scripting'
run 'as_default ACL SETUSER reader on ">$READER_PASS" "~*" resetchannels -@all +@read +@connection -@dangerous "+acl|whoami"'
run 'as_admin ACL WHOAMI'

step "4. Tắt user default (từ giờ phải đăng nhập bằng user có tên)"
run 'as_admin ACL SETUSER default off'
run 'as_default ping'
run 'env -u REDISCLI_AUTH redis-cli ping'

step "5. Lưu ACL ra file và xem nội dung (chỉ có mã băm, không có mật khẩu)"
run 'as_admin ACL SAVE'
key "sudo cat $ACLFILE"
run 'as_admin ACL LIST'

step "6. User reader: đọc được, mọi lệnh ghi và lệnh nguy hiểm bị chặn"
run 'as_reader ACL WHOAMI'
key 'as_reader GET app:name'
run 'as_reader HGETALL user:1001'
run 'as_reader SCAN 0 COUNT 100'
key 'as_reader SET app:name "bi sua"'
key 'as_reader DEL user:1001'
key 'as_reader FLUSHALL'
key 'as_reader KEYS "*"'
key 'as_reader CONFIG GET maxmemory'
key 'as_reader GET app:name'

step "7. User app: ghi được, nhưng không chạy được FLUSHALL, CONFIG, KEYS, Lua"
key 'as_app SET app:status ok'
run 'as_app GET app:status'
key 'as_app FLUSHALL'
key 'as_app CONFIG SET maxmemory 1mb'
run 'as_app KEYS "*"'
key 'as_app EVAL "return 1" 0'

step "8. Admin xem nhật ký các lần bị từ chối (ACL LOG)"
key 'as_admin ACL LOG 6 | paste - - | grep -E "^(reason|object|username)" | paste - - - | column -t'

step "9. Restart Redis: ACL được nạp lại từ file"
run 'sudo systemctl restart redis'
REDISCLI_AUTH=$ADMIN_PASS wait_redis --user admin
run 'as_admin ACL LIST'
key 'as_reader FLUSHALL'
run 'as_admin DBSIZE'
key 'as_admin ACL USERS'

step "10. Lưu file ACL và redis.conf để nộp"
run "sudo cat $ACLFILE > logs/users.acl"
run "sudo cat $CONF | mask > logs/redis.conf"
run 'grep -vE "^[[:space:]]*(#|$)" logs/redis.conf'

step "XONG Bài 3"
