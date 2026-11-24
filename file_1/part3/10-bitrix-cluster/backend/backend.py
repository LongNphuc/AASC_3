"""Bài 10 (Phần 3): backend giả lập lõi PHP của Bitrix24 (module "pull") gửi sự kiện tới push-server.

Mỗi tin là một JSON, ký bằng HMAC-SHA256 với khóa bí mật dùng chung (giống "signature key" mà Bitrix
cấu hình giữa PHP và push-server), gửi tới POST /bitrix/pub/?CHANNEL_ID=<kênh> của các node theo kiểu
xoay vòng. Chạy bằng Python 3.11 (Bài 4, 9) và thư viện requests.

Cách dùng: python backend.py --pub http://node1:9010,http://node2:9010 --count 10 [--bad-signature]
"""
import argparse
import hashlib
import hmac
import itertools
import json
import os
import sys
import time

import requests


def publish(base, channel, payload, key, bad=False):
    body = json.dumps(payload, ensure_ascii=False).encode()
    signature = hmac.new(key.encode(), body, hashlib.sha256).hexdigest()
    if bad:
        signature = "0" * len(signature)  # chữ ký sai để kiểm tra push-server từ chối
    resp = requests.post(
        f"{base}/bitrix/pub/",
        params={"CHANNEL_ID": channel},
        data=body,
        headers={"Content-Type": "application/json", "X-Signature": signature},
        timeout=5,
    )
    return resp.status_code, resp.json()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pub", required=True, help="danh sách URL pub, cách nhau bởi dấu phẩy")
    parser.add_argument("--channel", default="chat.general")
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--bad-signature", action="store_true")
    args = parser.parse_args()

    key = os.environ.get("PUSH_SECURITY_KEY")
    if not key:
        sys.exit("Thiếu biến môi trường PUSH_SECURITY_KEY")

    print(f"Python {sys.version.split()[0]} | requests {requests.__version__} | kênh {args.channel}")
    if args.bad_signature:
        status, body = publish(args.pub.split(",")[0], args.channel, {"text": "giả mạo"}, key, bad=True)
        print(f"Gửi tin với chữ ký sai -> HTTP {status} {body}")
        sys.exit(0 if status == 403 else 1)

    nodes = itertools.cycle(args.pub.split(","))
    for i in range(1, args.count + 1):
        base = next(nodes)
        payload = {"module": "im", "command": "message", "params": {"from": "user-1", "text": f"Tin số {i}"}}
        status, body = publish(base, args.channel, payload, key)
        print(f"  tin {i:>2} -> {base:<28} HTTP {status} {json.dumps(body, ensure_ascii=False)}")
        if status != 202:
            sys.exit(1)
        time.sleep(0.1)


if __name__ == "__main__":
    main()
