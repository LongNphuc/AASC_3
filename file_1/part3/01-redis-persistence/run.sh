#!/usr/bin/env bash
# Bài 1 (Phần 3): cài Redis 7.2 từ kho chính thức của Rocky Linux 9, cấu hình bảo mật + RDB + AOF,
# ghi dữ liệu mẫu, rồi kiểm tra dữ liệu còn nguyên sau khi restart service và sau khi tiến trình bị kill -9.
# Chạy trên máy ảo: cd ~/aasc3/part3/01-redis-persistence && ./run.sh
cd "$(dirname "$0")"
source ../lib/common.sh
log_start

CONF=/etc/redis/redis.conf
PRIVATE_IP=$(hostname -I | awk '{print $1}')
export REDISCLI_AUTH
REDISCLI_AUTH=$(redis_password default)

# In toàn bộ dữ liệu mẫu (không gồm TTL vì TTL giảm dần theo thời gian), dùng để so sánh trước/sau.
show_data() {
  echo "--- app:name";        redis-cli GET app:name
  echo "--- user:1001";       redis-cli HGETALL user:1001
  echo "--- queue:jobs";      redis-cli LRANGE queue:jobs 0 -1
  echo "--- tags";            redis-cli SMEMBERS tags | sort
  echo "--- leaderboard";     redis-cli ZRANGE leaderboard 0 -1 WITHSCORES
  echo "--- counter:visits";  redis-cli GET counter:visits
  echo "--- DBSIZE";          redis-cli DBSIZE
}

step "1. Cài Redis 7.2 từ AppStream (module redis:7)"
run 'sudo dnf -y module list redis'
run 'sudo dnf -y module reset redis'
run 'sudo dnf -y module enable redis:7'
run 'sudo dnf -y install redis'
key 'rpm -q redis'
key 'redis-server --version'
run 'rpm -q --changelog redis | head -16'
key 'rpm -q --changelog redis | grep -oE "CVE-[0-9]{4}-[0-9]+" | sort -u | tr "\\n" " "; echo'

step "2. Cấu hình bảo mật và bền vững dữ liệu trong $CONF"
run "[ -f $CONF.orig ] || sudo cp -p $CONF $CONF.orig"
run "sudo cp -p $CONF.orig $CONF"
echo "Áp các tham số trong redis.settings (IP nội bộ: $PRIVATE_IP):"
while read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  value=${value//__PRIVATE_IP__/$PRIVATE_IP}
  value=${value//__PASSWORD__/$REDISCLI_AUTH}
  set_conf "$CONF" "$key" "$value"
  echo "  $key $value" | mask
done < redis.settings
run "sudo diff -u $CONF.orig $CONF | mask || true"
key "sudo grep -E '^(bind|protected-mode|port|requirepass|save|appendonly|appendfsync|aof-use-rdb-preamble) ' $CONF | mask"
run 'sudo ls -lZ /etc/redis/'
run 'getenforce'

step "3. Khởi động Redis và bật tự chạy khi boot"
run 'sudo systemctl enable redis'
run 'sudo systemctl restart redis'
wait_redis
run 'systemctl status redis --no-pager | head -12'
key 'sudo ss -tlnp | grep 6379'

step "4. Kiểm tra xác thực (requirepass) và địa chỉ lắng nghe (bind)"
key 'env -u REDISCLI_AUTH redis-cli ping'
key 'redis-cli ping'
key "redis-cli -h $PRIVATE_IP ping"

step "5. Ghi dữ liệu mẫu (nhiều kiểu dữ liệu)"
run 'redis-cli UNLINK app:name user:1001 queue:jobs tags leaderboard counter:visits session:abc crash:test'
run 'redis-cli SET app:name "AASC3 Redis demo"'
run 'redis-cli HSET user:1001 name "Nguyen Van An" email an@example.com age 30'
run 'redis-cli RPUSH queue:jobs job-1 job-2 job-3'
run 'redis-cli SADD tags redis python nodejs ansible'
run 'redis-cli ZADD leaderboard 1500 alice 2300 bob 1800 carol'
run 'redis-cli INCRBY counter:visits 42'
run 'redis-cli SET session:abc "phien tam" EX 3600'
run 'show_data | tee /tmp/aasc3-before.txt'
run 'redis-cli TTL session:abc'

step "6. Ép ghi RDB, chờ AOF fsync, xem file trên đĩa"
run 'redis-cli BGSAVE'
run 'until redis-cli INFO persistence | grep -q "rdb_bgsave_in_progress:0"; do sleep 0.5; done; echo "BGSAVE xong"'
run 'sleep 2'
run 'redis-cli INFO persistence | tr -d "\r" | grep -E "^(rdb_changes_since_last_save|rdb_last_bgsave_status|aof_enabled|aof_last_write_status|aof_last_bgrewrite_status)"'
key 'sudo find /var/lib/redis -type f -printf "%p  (%s byte)\n" | sort'
run 'sudo cat /var/lib/redis/appendonlydir/appendonly.aof.manifest'
key 'sudo sh -c "cat /var/lib/redis/appendonlydir/*.incr.aof" | aof_to_commands | tail -8'

step "7. Restart service rồi kiểm tra dữ liệu"
key 'redis-cli INFO server | tr -d "\r" | grep -E "^(run_id|process_id):"'
run 'sudo systemctl restart redis'
wait_redis
key 'redis-cli INFO server | tr -d "\r" | grep -E "^(run_id|process_id):"'
run 'show_data | tee /tmp/aasc3-after.txt'
key 'diff /tmp/aasc3-before.txt /tmp/aasc3-after.txt && echo "=> Dữ liệu trước và sau restart giống hệt nhau"'
run 'redis-cli TTL session:abc'
key 'sudo grep -E "DB loaded from append only file|Ready to accept" /var/log/redis/redis.log | tail -2'

step "8. Mô phỏng sập đột ngột (kill -9) để kiểm tra AOF"
run 'redis-cli SET crash:test "ghi truoc khi kill -9"'
run 'sleep 2'
key 'sudo kill -9 "$(pidof redis-server)"'
key 'sleep 2; systemctl is-active redis || true'
run 'systemctl is-active --quiet redis || sudo systemctl start redis'
wait_redis
key 'redis-cli GET crash:test'
run 'redis-cli UNLINK crash:test'
key 'show_data | diff /tmp/aasc3-before.txt - && echo "=> Dữ liệu mẫu vẫn còn nguyên sau kill -9"'
run 'sudo grep -E "Loading|loaded|Ready to accept" /var/log/redis/redis.log | tail -4'

step "9. Lưu cấu hình và log server để nộp (mật khẩu đã che)"
run "sudo cat $CONF | mask > logs/redis.conf"
run 'grep -vE "^[[:space:]]*(#|$)" logs/redis.conf > logs/redis.conf.effective'
run 'cat logs/redis.conf.effective'
run 'sudo tail -n 60 /var/log/redis/redis.log > logs/redis-server.log'
run 'ls -la logs/'

step "XONG Bài 1"
