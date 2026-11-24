"""Bài 2 (Phần 3): đo thời gian gửi 100 lệnh SET, gửi từng lệnh so với gửi bằng pipelining.

Không pipelining: mỗi SET là một vòng gửi lệnh rồi chờ trả lời (100 round-trip).
Có pipelining: gom 100 SET gửi một lần, đọc 100 trả lời một lần (1 round-trip).
Mật khẩu lấy từ biến môi trường REDISCLI_AUTH, không ghi trong code.
"""
import os
import statistics
import time

import redis

N = 100        # số lệnh SET mỗi lần đo
ROUNDS = 5     # số lần đo, báo cáo trung vị để bớt nhiễu

r = redis.Redis(
    host=os.environ.get("REDIS_HOST", "127.0.0.1"),
    port=int(os.environ.get("REDIS_PORT", "6379")),
    username=os.environ.get("REDIS_USER", "default"),
    password=os.environ["REDISCLI_AUTH"],
    decode_responses=True,
)


def no_pipeline():
    for i in range(N):
        r.set(f"bench:nopipe:{i}", f"value-{i}")


def with_pipeline():
    pipe = r.pipeline(transaction=False)  # chỉ gom lệnh, không bọc MULTI/EXEC
    for i in range(N):
        pipe.set(f"bench:pipe:{i}", f"value-{i}")
    replies = pipe.execute()
    assert replies == [True] * N, "có lệnh SET thất bại"


def measure(fn):
    times = []
    for _ in range(ROUNDS):
        start = time.perf_counter()
        fn()
        times.append((time.perf_counter() - start) * 1000)
    return times


def main():
    r.ping()  # mở kết nối trước để không tính thời gian kết nối vào lần đo đầu
    print(f"Redis {r.info('server')['redis_version']} tại {r.connection_pool.connection_kwargs['host']}")
    print(f"Mỗi lần đo gửi {N} lệnh SET, đo {ROUNDS} lần\n")

    t_plain = measure(no_pipeline)
    t_pipe = measure(with_pipeline)

    print(f"{'Cách gửi':<18}{'các lần đo (ms)':<44}{'trung vị (ms)':>14}")
    for name, times in (("Từng lệnh", t_plain), ("Pipelining", t_pipe)):
        detail = ", ".join(f"{t:.2f}" for t in times)
        print(f"{name:<18}{detail:<44}{statistics.median(times):>14.3f}")
    speedup = statistics.median(t_plain) / statistics.median(t_pipe)
    print(f"\n=> Pipelining nhanh hơn khoảng {speedup:.1f} lần")

    keys = list(r.scan_iter("bench:pipe:*", count=1000))
    print(f"Số key bench:pipe:* đã ghi: {len(keys)}; ví dụ bench:pipe:99 = {r.get('bench:pipe:99')}")
    removed = r.unlink(*keys, *r.scan_iter("bench:nopipe:*", count=1000))
    print(f"Đã dọn {removed} key benchmark bằng UNLINK")


if __name__ == "__main__":
    main()
