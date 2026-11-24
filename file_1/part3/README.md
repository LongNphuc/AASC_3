# Phần 3: Bài tập thực tế

Mỗi bài là một thư mục có `run.sh`. Script chạy toàn bộ các bước của bài và tự ghi log (lệnh, giờ chạy, output) vào `logs/` của bài đó. Mật khẩu sinh ngẫu nhiên, lưu ở `~/.aasc3/` trên máy ảo (không nằm trong thư mục nộp), và được che thành `<REDACTED>` trong log. Mô tả cách làm và giải thích nằm ở [Phần 2](../part2-practice.md).

## Môi trường

| Máy | Vai trò | Loại | IP nội bộ |
|---|---|---|---|
| `rocky-ctl` | Bài 1-9; ở bài 10 là Redis, backend Python và control node của Ansible | AWS EC2 `t3.small` (2 vCPU, 2 GB RAM, 20 GB gp3) | 172.31.0.164 |
| `rocky-node1`, `rocky-node2` | Bài 10: Node.js 20 + push-server | AWS EC2 `t3.micro`, tạo từ image `rocky9-base` | xem `10-bitrix-cluster/inventory.ini` |

- Hệ điều hành: Rocky Linux 9.8 (AMI chính thức `Rocky-9-EC2-LVM-9.8`), SELinux Enforcing. Region `ap-southeast-2` (Sydney).
- Ba máy cùng một VPC và cùng Security Group `aasc3-sg`. Từ Internet chỉ mở SSH, và chỉ cho IP của người làm bài.
- Phiên bản: Redis 7.2.16, Python 3.11.17 → 3.11.18 (build từ mã nguồn), Node.js 20.20.2, ansible-core 2.21 (Python 3.12).

## Danh sách bài

| Bài | Thư mục | Nội dung | File nộp chính | Phần 2 |
|---|---|---|---|---|
| 1 | [01-redis-persistence](01-redis-persistence/) | Cài Redis 7.2, bảo mật, RDB + AOF, restart và `kill -9` | `redis.settings`, `logs/redis.conf`, log | Câu 1, 10 |
| 2 | [02-redis-performance](02-redis-performance/) | `maxmemory` 80% RAM, THP, overcommit, pipelining 100 SET, DEL so với UNLINK | `bench_pipeline.py`, `bigkey_unlink.py`, log | Câu 2 |
| 3 | [03-redis-acl](03-redis-acl/) | ACL: user `admin`, `app`, `reader` (chỉ đọc), thử lệnh bị chặn | `logs/users.acl`, log | Câu 3, 10 |
| 4 | [04-python-source](04-python-source/) | Build Python 3.11.17 từ mã nguồn, pip, venv, `requests` | log, `logs/pip-list.txt`, `logs/make.log` | Câu 4, 5 |
| 5 | [05-python-taskgroup](05-python-taskgroup/) | `TaskGroup` chạy 5 tác vụ tải URL, timeout 5 giây, so với `gather` | `script.py`, log | Câu 6 |
| 6 | [06-python-traceback](06-python-traceback/) | `ZeroDivisionError` trong biểu thức lồng, traceback 3.11 so với 3.9 | `script.py`, `logs/traceback-*.txt` | Phần 1 câu 6 |
| 7 | [07-nodejs-chat](07-nodejs-chat/) | Node.js 20, chat server WebSocket, 1000 kết nối đồng thời | `server.js`, `load-test.js`, `chat-server.service`, log | Câu 7 |
| 8 | [08-ansible-redis](08-ansible-redis/) | ansible-core 2.21, playbook triển khai Redis lên localhost | `playbook.yaml`, `../roles/redis/`, `logs/run*.txt` | Câu 8 |
| 9 | [09-ansible-python](09-ansible-python/) | Ansible cập nhật Python 3.11.17 lên 3.11.18, chạy 3 lần | `playbook.yaml`, `../roles/python311/`, `logs/run*.txt` | Câu 5, 9 |
| 10 | [10-bitrix-cluster](10-bitrix-cluster/) | Cụm Bitrix24 mô phỏng: Redis + push-server Node.js trên 2 node + backend Python, dựng bằng Ansible | `site.yml`, `app/`, `backend/`, `test/`, `logs/` | Câu 7, 9 |

Các bài phải chạy theo thứ tự, vì bài sau dùng kết quả của bài trước: bài 2-3 cần Redis của bài 1; bài 5, 6, 9 cần Python của bài 4; bài 9-10 cần Ansible của bài 8; bài 10 cần Node.js của bài 7.

## Cách chạy

Trên `rocky-ctl` có sẵn lệnh `aasc` (file [`tools/aasc`](tools/aasc)):

```bash
aasc            # danh sách bài và trạng thái
aasc 01         # chạy bài 1
aasc print-log 01   # xóa màn hình, in trang kết quả của bài 1 để chụp
```

Mỗi bài ghi 2 loại log vào `logs/` của bài đó:
- `logs/<tên-bài>-<thời-gian>.log`: toàn bộ lệnh và output, theo thứ tự chạy.
- `logs/ket-qua.txt`: trang kết quả, chỉ gồm các lệnh chứng minh yêu cầu của đề (các dòng gọi bằng `key` trong `run.sh`). Đây là trang được chụp màn hình.

Các script được đưa lên máy ảo bằng `tools/sync.sh push`; log được lấy về bằng `tools/sync.sh pull` (chạy trên WSL). Muốn chạy lại từ đầu: `tools/reset-all.sh` trên `rocky-ctl` và `tools/reset-nodes.sh` cho 2 node, rồi `sudo reboot`.

## Ảnh chụp

Toàn bộ ảnh chụp kết quả được lưu trên Google Drive: <https://drive.google.com/drive/folders/168h1rZYJA0oMNIHKUfp8s4hPayC7wsgw>

Mỗi bài một ảnh: chạy `aasc print-log NN` rồi chụp màn hình (tên `bai01.png` ... `bai10.png`). Thêm 2 ảnh chung: trang EC2 Instances (thấy 3 máy, region Sydney) và `cat /etc/rocky-release` trên `rocky-ctl`.

## Chuẩn bị cho bài 10

1. **Tạo 2 máy node từ image:** trên AWS, vào **EC2 → AMIs**, chọn `rocky9-base`, bấm **Launch instance from AMI**, đặt **Number of instances = 2**. Chọn `t3.micro`, key pair `aasc3`, subnet `ap-southeast-2a`, security group **có sẵn** `aasc3-sg`. Sau đó đổi tên 2 máy thành `rocky-node1` và `rocky-node2`.
2. **Mở cổng giữa các máy:** vào **Security Groups → `aasc3-sg` → Edit inbound rules → Add rule**: Type **All TCP**, Source **Custom** = chính `aasc3-sg` (gõ `sg-` rồi chọn). Nhờ rule này các máy trong nhóm gọi được nhau (Redis 6379, push-server 8010/9010), còn từ Internet vẫn chỉ vào được SSH.
3. **Điền IP nội bộ của 2 node** vào `10-bitrix-cluster/inventory.ini`.
4. **Cho `rocky-ctl` SSH được vào 2 node.** Trên `rocky-ctl`, chạy `ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519`. Sau đó trên WSL, với từng IP node:
   ```bash
   ssh rocky-ctl cat .ssh/id_ed25519.pub | ssh -J rocky-ctl rocky@<IP-node> 'cat >> ~/.ssh/authorized_keys'
   ```

## Khác biệt so với mô tả ở Phần 2, và lý do

- **Bài 4 build Python không bật tối ưu** (`--enable-optimizations --with-lto`): với máy 2 vCPU, PGO làm thời gian build tăng nhiều lần. Production nên bật (Phần 2 câu 4).
- **Bài 4 cố ý cài 3.11.17**, bản ngay trước bản mới nhất, để bài 9 có việc cập nhật thật lên 3.11.18 bằng Ansible.
- **Bài 7 và 10 dùng Node.js 20 theo đề, dù bản này đã hết hỗ trợ từ 30/04/2026.** Role `nodejs` chỉ cần đổi `nodejs_stream` thành `22` hoặc `24`.
- **Bài 8 gỡ bản Redis cài tay ở bài 1-3 trước khi chạy playbook**, để chứng minh playbook dựng được Redis từ đầu trên máy sạch.
- **Bài 10 là bản mô phỏng:** push-server tự viết theo kiến trúc push-server của Bitrix (tiến trình sub/pub, Redis Pub/Sub, chữ ký HMAC), không phải mã nguồn thật của Bitrix. Không có nginx đứng trước; client nối thẳng vào cổng 8010 trong mạng nội bộ.
