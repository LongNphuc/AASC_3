"""Bài 2 (Phần 3): so sánh DEL và UNLINK khi xóa một key rất lớn.

DEL giải phóng bộ nhớ ngay trên luồng chính, nên trong lúc xóa, mọi client khác phải chờ.
UNLINK chỉ gỡ key khỏi keyspace rồi trả lời ngay; việc giải phóng bộ nhớ chạy ở luồng nền (lazyfree).
"""
import os
import time

import redis

MEMBERS = 1_000_000   # số phần tử của mỗi Set lớn
BATCH = 10_000        # số phần tử mỗi lệnh SADD khi tạo dữ liệu

r = redis.Redis(
    host=os.environ.get("REDIS_HOST", "127.0.0.1"),
    username=os.environ.get("REDIS_USER", "default"),
    password=os.environ["REDISCLI_AUTH"],
    decode_responses=True,
)


def build(key):
    r.unlink(key)
    pipe = r.pipeline(transaction=False)
    for start in range(0, MEMBERS, BATCH):
        pipe.sadd(key, *(f"member:{i}" for i in range(start, start + BATCH)))
    pipe.execute()


def timed(cmd, key):
    start = time.perf_counter()
    r.execute_command(cmd, key)
    return (time.perf_counter() - start) * 1000


def main():
    print(f"{'Lệnh':<8}{'Số phần tử':>12}{'Bộ nhớ key (MB)':>18}{'Thời gian lệnh (ms)':>22}")
    for cmd, key in (("DEL", "big:del"), ("UNLINK", "big:unlink")):
        build(key)
        size = r.scard(key)
        mem_mb = r.memory_usage(key) / 1024 / 1024
        ms = timed(cmd, key)
        print(f"{cmd:<8}{size:>12,}{mem_mb:>18.1f}{ms:>22.3f}")
    info = r.info("memory")
    print(f"\nlazyfree_pending_objects ngay sau UNLINK: {info.get('lazyfree_pending_objects')}")
    print(f"Key còn tồn tại: big:del={r.exists('big:del')}, big:unlink={r.exists('big:unlink')}")


if __name__ == "__main__":
    main()
