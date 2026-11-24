"""Bài 5 (Phần 3): chạy 5 tác vụ tải URL đồng thời bằng asyncio.TaskGroup, giới hạn tổng thời gian 5 giây.

Cần Python 3.11+: asyncio.TaskGroup, asyncio.timeout() và except* đều mới từ 3.11.
Các kịch bản:
  1. 5 URL thật trên Internet
  2. 5 URL thử nghiệm trả lời sau 1-3 giây: chạy song song nên tổng thời gian ~ tác vụ chậm nhất
  3. Có URL chậm hơn 5 giây: asyncio.timeout(5) hủy cả nhóm, báo tác vụ nào xong, tác vụ nào bị hủy
  4. Có URL lỗi: TaskGroup hủy các tác vụ còn lại và gom lỗi vào ExceptionGroup (bắt bằng except*)
  5. Cùng dữ liệu như 4 nhưng dùng asyncio.gather(return_exceptions=True) để so sánh
URL thử nghiệm do một HTTP server nhỏ chạy ngay trong script cung cấp (127.0.0.1:8765), nên kết quả
kịch bản 2-5 không phụ thuộc mạng.
"""
import asyncio
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import aiohttp

TIMEOUT = 5  # giây, áp cho cả nhóm tác vụ
LOCAL = "http://127.0.0.1:8765"
PUBLIC_URLS = [
    "https://www.python.org/",
    "https://redis.io/",
    "https://nodejs.org/en",
    "https://rockylinux.org/",
    "https://docs.ansible.com/",
]


class TestHandler(BaseHTTPRequestHandler):
    """/delay/<giây>: trả lời 200 sau đúng số giây đó; /error: trả lời 500 ngay."""

    def do_GET(self):
        if self.path.startswith("/delay/"):
            time.sleep(float(self.path.rsplit("/", 1)[1]))
            status, body = 200, b"ok"
        else:
            status, body = 500, b"loi gia lap"
        try:
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client đã hủy yêu cầu (tác vụ bị TaskGroup/timeout hủy), không cần trả lời

    def log_message(self, *args):
        pass


def start_test_server():
    server = ThreadingHTTPServer(("127.0.0.1", 8765), TestHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


async def fetch(session, url, t0):
    start = time.perf_counter()
    async with session.get(url) as resp:
        body = await resp.read()
        resp.raise_for_status()
    took = time.perf_counter() - start
    print(f"  [{time.perf_counter() - t0:5.2f}s] xong  {url:<32} HTTP {resp.status}, {len(body):>7,} byte, mất {took:.2f}s")
    return took


def summary(tasks, t0):
    done = [t for t in tasks if t.done() and not t.cancelled() and t.exception() is None]
    cancelled = [t.get_name() for t in tasks if t.cancelled()]
    print(f"  => sau {time.perf_counter() - t0:.2f}s: xong {len(done)}/{len(tasks)}, bị hủy {len(cancelled)} {cancelled}")


async def run_taskgroup(title, urls):
    """Kịch bản 1-3: TaskGroup + asyncio.timeout(5)."""
    print(f"\n=== {title} ===")
    t0 = time.perf_counter()
    tasks = []
    try:
        async with aiohttp.ClientSession() as session:
            async with asyncio.timeout(TIMEOUT):
                async with asyncio.TaskGroup() as tg:
                    tasks = [tg.create_task(fetch(session, u, t0), name=u) for u in urls]
        total = sum(t.result() for t in tasks)
        print(f"  => cả {len(tasks)} tác vụ xong sau {time.perf_counter() - t0:.2f}s "
              f"(nếu chạy tuần tự sẽ mất khoảng {total:.2f}s)")
    except TimeoutError:
        print(f"  !! TimeoutError: quá {TIMEOUT}s, TaskGroup đã hủy các tác vụ chưa xong")
        summary(tasks, t0)


async def run_taskgroup_error(title, urls):
    """Kịch bản 4: một tác vụ lỗi làm TaskGroup hủy các tác vụ khác, lỗi được gom vào ExceptionGroup."""
    print(f"\n=== {title} ===")
    t0 = time.perf_counter()
    tasks = []
    try:
        async with aiohttp.ClientSession() as session:
            async with asyncio.timeout(TIMEOUT):
                async with asyncio.TaskGroup() as tg:
                    tasks = [tg.create_task(fetch(session, u, t0), name=u) for u in urls]
    except* aiohttp.ClientResponseError as eg:
        print(f"  !! {type(eg).__name__} gồm {len(eg.exceptions)} lỗi:")
        for e in eg.exceptions:
            print(f"     - HTTP {e.status} tại {e.request_info.url}")
        summary(tasks, t0)


async def run_gather(title, urls):
    """Kịch bản 5: gather(return_exceptions=True) không hủy tác vụ khác, trả lỗi lẫn trong kết quả."""
    print(f"\n=== {title} ===")
    t0 = time.perf_counter()
    async with aiohttp.ClientSession() as session:
        async with asyncio.timeout(TIMEOUT):
            results = await asyncio.gather(*(fetch(session, u, t0) for u in urls), return_exceptions=True)
    for url, res in zip(urls, results):
        kind = f"LỖI {type(res).__name__}" if isinstance(res, BaseException) else f"ok {res:.2f}s"
        print(f"     {url:<32} -> {kind}")
    print(f"  => sau {time.perf_counter() - t0:.2f}s: gather chờ đủ {len(urls)} tác vụ, lỗi nằm lẫn trong danh sách kết quả")


async def main():
    print(f"Python {sys.version.split()[0]} | aiohttp {aiohttp.__version__} | timeout cả nhóm: {TIMEOUT}s")
    start_test_server()
    await run_taskgroup("1. Năm URL thật trên Internet", PUBLIC_URLS)
    await run_taskgroup("2. Năm URL thử nghiệm trả lời sau 1-3 giây",
                        [f"{LOCAL}/delay/{d}" for d in (1, 1.5, 2, 2.5, 3)])
    await run_taskgroup("3. Có URL chậm 7 và 9 giây (vượt timeout 5 giây)",
                        [f"{LOCAL}/delay/{d}" for d in (1, 2, 3, 7, 9)])
    await run_taskgroup_error("4. Có một URL trả lỗi 500 (TaskGroup)",
                              [f"{LOCAL}/delay/1", f"{LOCAL}/delay/2", f"{LOCAL}/error",
                               f"{LOCAL}/delay/3", f"{LOCAL}/delay/4"])
    await run_gather("5. Cùng dữ liệu như 4 nhưng dùng gather(return_exceptions=True)",
                     [f"{LOCAL}/delay/1", f"{LOCAL}/delay/2", f"{LOCAL}/error",
                      f"{LOCAL}/delay/3", f"{LOCAL}/delay/4"])


if __name__ == "__main__":
    asyncio.run(main())
