# Phần 2: Các câu hỏi thực hành

Mọi lệnh dưới đây đã được chạy thật trên Rocky Linux 9.8 (máy ảo AWS EC2 `t3.small`, 2 vCPU, 2 GB RAM). Script và log tương ứng nằm trong thư mục [`part3/`](part3/); mỗi câu ghi rõ bài thực hành liên quan. Chỗ nào bài thực hành làm khác mô tả, hoặc có cách tốt hơn, đều có mục **Ghi chú**.

Phiên bản dùng trong bài (kiểm tra ngày 08/11/2026):

| Thành phần | Phiên bản | Nguồn cài |
|---|---|---|
| Redis | 7.2.16 | AppStream, module `redis:7` |
| Python | 3.11.17 → 3.11.18 | Mã nguồn python.org |
| Node.js | 20.20.2 | AppStream, module `nodejs:20` |
| ansible-core | 2.21.x | pip trong virtualenv Python 3.12 |

---

## Câu 1. Cài Redis 7.2 từ kho chính thức trên Rocky Linux 9 và cấu hình bảo mật

### 1.1 Cài đặt

Kho AppStream của Rocky Linux 9 có hai dòng Redis: gói mặc định là **6.2**, còn **7.2** nằm trong module stream `redis:7`. Vì vậy phải bật module trước khi cài:

```bash
sudo dnf module list redis            # thấy stream 7
sudo dnf -y module reset redis
sudo dnf -y module enable redis:7
sudo dnf -y install redis
redis-server --version                # Redis server v=7.2.16
```

Gói tạo sẵn user `redis`, file cấu hình `/etc/redis/redis.conf` (quyền `640`, chủ sở hữu `redis`), thư mục dữ liệu `/var/lib/redis`, log `/var/log/redis/redis.log` và unit systemd `redis.service`.

### 1.2 Cấu hình bảo mật trong `/etc/redis/redis.conf`

Sao lưu bản gốc rồi sửa các tham số:

```bash
sudo cp -p /etc/redis/redis.conf /etc/redis/redis.conf.orig
openssl rand -hex 24                  # sinh mật khẩu mạnh
```

```conf
# Chỉ nghe trên loopback và IP nội bộ của máy, không bao giờ nghe trên IP public
bind 127.0.0.1 -::1 172.31.0.164
# Từ chối kết nối từ bên ngoài nếu chưa đặt mật khẩu (lớp bảo vệ phụ)
protected-mode yes
port 6379
# Mật khẩu cho user default
requirepass <mật-khẩu-sinh-ngẫu-nhiên>
```

- **`bind`**: dấu `-` trước `::1` nghĩa là bỏ qua nếu máy không có IPv6. Tuyệt đối không dùng `bind 0.0.0.0` trên máy có IP public.
- **`requirepass`**: chỉ là mật khẩu của user `default`. Muốn phân quyền chi tiết theo từng user thì dùng ACL (câu 3).
- Giữ nguyên quyền `640` của `redis.conf` vì file chứa mật khẩu.

Khởi động và kiểm tra:

```bash
sudo systemctl enable --now redis
sudo ss -tlnp | grep 6379             # chỉ thấy 127.0.0.1, ::1 và IP nội bộ
redis-cli ping                        # NOAUTH Authentication required.
export REDISCLI_AUTH='<mật-khẩu>'
redis-cli ping                        # PONG
```

Nên truyền mật khẩu qua biến môi trường `REDISCLI_AUTH` thay cho `redis-cli -a <mật-khẩu>`, vì `-a` để lộ mật khẩu trong lịch sử shell và trong danh sách tiến trình (`ps`).

### 1.3 Lớp mạng

- **Máy chủ thật (on-premise):** dùng firewalld, chỉ mở 6379 cho dải IP của máy ứng dụng:
  ```bash
  sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=172.31.0.0/16 port port=6379 protocol=tcp accept'
  sudo firewall-cmd --reload
  ```
- **Trên cloud:** dùng Security Group. Không mở 6379 ra Internet, chỉ cho các máy trong cùng Security Group truy cập.
- **SELinux** đang ở chế độ Enforcing: giữ nguyên các đường dẫn mặc định (`/etc/redis`, `/var/lib/redis`) để nhãn SELinux đúng sẵn. Nếu đổi cổng thì phải khai báo với SELinux: `semanage port -a -t redis_port_t -p tcp <cổng>`.

### 1.4 Bền vững dữ liệu (dùng cho Phần 3 bài 1)

```conf
save 300 10 60 1000          # RDB: sau 300s nếu >= 10 thay đổi, hoặc 60s nếu >= 1000 thay đổi
appendonly yes               # AOF
appendfsync everysec
aof-use-rdb-preamble yes
```

**Thực hành:** [Phần 3 bài 1](part3/01-redis-persistence/). Kết quả: dữ liệu còn nguyên sau `systemctl restart redis` và cả sau khi tiến trình bị `kill -9`. Log khởi động cho thấy Redis nạp từ AOF (file base RDB + file incr AOF), không nạp `dump.rdb`, đúng như câu 2 Phần 1 đã nêu.

---

## Câu 2. Tinh chỉnh hiệu suất Redis

### 2.1 Bộ nhớ: `maxmemory` bằng 75-85% RAM

Phải chừa 15-25% RAM vì Redis cần thêm bộ nhớ ngoài dữ liệu: khi ghi RDB hoặc viết lại AOF, Redis gọi `fork()`, và các trang nhớ bị sửa trong lúc đó phải sao chép thêm (copy-on-write). Ngoài ra còn bộ đệm của client và replica, phân mảnh bộ nhớ, và hệ điều hành.

```bash
MEM=$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)     # byte
MAXMEM=$(( MEM * 80 / 100 ))
redis-cli CONFIG SET maxmemory $MAXMEM
redis-cli CONFIG SET maxmemory-policy allkeys-lru
redis-cli CONFIG REWRITE                                        # ghi lại vào redis.conf
redis-cli INFO memory | grep -E "maxmemory_human|maxmemory_policy"
```

Chọn `maxmemory-policy` theo vai trò của Redis:
- **Cache thuần:** `allkeys-lru` hoặc `allkeys-lfu` (đầy thì loại bỏ key ít dùng).
- **Có dữ liệu không được mất** (hàng đợi job, session): `noeviction`, để Redis báo lỗi khi đầy thay vì âm thầm xóa dữ liệu.

**Ghi chú:**
- `CONFIG REWRITE` ghi lại cả user `default` thành một dòng `user default ...` trong `redis.conf`. Nếu sau đó chuyển sang dùng `aclfile` thì phải xóa dòng này (xem câu 3).
- Nếu cấu hình được quản lý bằng Ansible (câu 8) thì nên sửa template thay vì `CONFIG REWRITE`.

### 2.2 Tắt Transparent Huge Pages (THP) và bật overcommit

- **Vì sao tắt THP:** với THP, mỗi lần copy-on-write sau `fork()` phải sao chép cả trang 2 MB thay vì trang 4 KB, làm tăng độ trễ và lượng RAM dùng thêm khi ghi RDB/AOF. Redis 7 có tham số `disable-thp yes` (mặc định) để tự tắt THP cho riêng tiến trình Redis; tắt ở cấp hệ điều hành vẫn được khuyến nghị.
- **Vì sao bật overcommit:** với `vm.overcommit_memory = 0`, `fork()` khi ghi RDB có thể bị kernel từ chối dù thực tế đủ RAM. Redis cũng in cảnh báo "Memory overcommit must be enabled".

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled        # [always] madvise never

# Tắt THP bền vững qua reboot bằng một unit systemd chạy trước redis.service
sudo tee /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Tắt Transparent Huge Pages cho Redis
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=redis.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=basic.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp.service

# Overcommit
echo "vm.overcommit_memory = 1" | sudo tee /etc/sysctl.d/99-redis.conf
sudo sysctl -p /etc/sysctl.d/99-redis.conf
sudo systemctl restart redis           # log không còn WARNING về overcommit/THP
```

Cách khác là thêm tham số kernel `transparent_hugepage=never` bằng `grubby --update-kernel=ALL --args="transparent_hugepage=never"` rồi reboot. Unit systemd không cần reboot và dễ đưa vào Ansible hơn.

### 2.3 `UNLINK` thay cho `DEL` khi xóa key lớn

- **`DEL`** giải phóng bộ nhớ ngay trên luồng chính. Xóa một Set hoặc Hash hàng triệu phần tử có thể mất hàng trăm mili-giây, và trong lúc đó mọi client khác phải chờ.
- **`UNLINK`** chỉ gỡ key khỏi keyspace rồi trả lời ngay; việc giải phóng bộ nhớ chạy ở luồng nền (lazyfree).

```bash
redis-cli UNLINK big:set
# Hoặc cho DEL tự hoạt động như UNLINK
redis-cli CONFIG SET lazyfree-lazy-user-del yes
```

Các thói quen cùng loại: dùng `SCAN` thay cho `KEYS *`, dùng `FLUSHALL ASYNC` thay cho `FLUSHALL`.

### 2.4 Pipelining

Gom nhiều lệnh gửi một lần để giảm số vòng gửi-nhận (round-trip). Đây là cách tăng thông lượng rẻ nhất khi client gửi nhiều lệnh liên tiếp:

```python
pipe = r.pipeline(transaction=False)
for i in range(100):
    pipe.set(f"key:{i}", i)
pipe.execute()
```

**Thực hành:** [Phần 3 bài 2](part3/02-redis-performance/). Kết quả lần chạy chính thức (10/11/2026):

| Phép đo | Kết quả |
|---|---|
| 100 lệnh SET gửi từng lệnh | 11,26 ms |
| 100 lệnh SET gửi bằng pipelining | 1,54 ms (nhanh hơn khoảng 7,3 lần) |
| `redis-benchmark`, `-P 1` | 66.756 lệnh/giây |
| `redis-benchmark`, `-P 100` | 694.445 lệnh/giây |
| Xóa Set 1 triệu phần tử (46 MB) bằng `DEL` | 145,7 ms |
| Xóa cùng loại key bằng `UNLINK` | 0,19 ms |

Kết quả đo khi Redis và client cùng nằm trên một máy. Trong thực tế client ở máy khác, thời gian mỗi round-trip lớn hơn nhiều, nên lợi ích của pipelining còn rõ hơn.

---

## Câu 3. Dùng ACL trong Redis 7.2 để hạn chế lệnh nguy hiểm như FLUSHALL

### 3.1 Khái niệm

ACL (từ Redis 6) cho phép tạo nhiều user, mỗi user có mật khẩu và quyền riêng trên:
- **Lệnh:** theo từng lệnh (`+get`, `-flushall`) hoặc theo nhóm (`+@read`, `-@dangerous`, `-@scripting`). Xem các nhóm bằng `ACL CAT`; nhóm `@dangerous` gồm `FLUSHALL`, `FLUSHDB`, `KEYS`, `CONFIG`, `DEBUG`, `SHUTDOWN`...
- **Key:** `~app:*` (chỉ key có tiền tố `app:`), `~*` (mọi key).
- **Kênh Pub/Sub:** `&push:*`, `resetchannels`.

### 3.2 Chuyển từ `requirepass` sang file ACL

Redis **không cho khai báo user ở cả `redis.conf` lẫn `aclfile`**: nếu vẫn còn `requirepass` hoặc dòng `user ...` (do `CONFIG REWRITE` ghi vào) mà thêm `aclfile`, Redis sẽ không khởi động. Các bước:

```bash
# 1. File ACL ban đầu giữ user default với mã băm SHA-256 của mật khẩu hiện tại
HASH=$(printf '%s' "$REDISCLI_AUTH" | sha256sum | cut -d' ' -f1)
echo "user default on #$HASH ~* &* +@all" | sudo install -o redis -g root -m 640 /dev/stdin /etc/redis/users.acl
sudo restorecon -v /etc/redis/users.acl

# 2. Bỏ requirepass và các dòng user trong redis.conf, khai báo aclfile
sudo sed -i -E 's/^requirepass .*/# requirepass: chuyển sang aclfile/; /^user /d' /etc/redis/redis.conf
echo 'aclfile /etc/redis/users.acl' | sudo tee -a /etc/redis/redis.conf
sudo systemctl restart redis
```

### 3.3 Tạo user và hạn chế lệnh nguy hiểm

```bash
# admin: toàn quyền (chỉ dùng cho quản trị)
redis-cli ACL SETUSER admin on '>mật-khẩu-admin' '~*' '&*' +@all
# app: ứng dụng đọc/ghi bình thường, nhưng cấm FLUSHALL, KEYS, CONFIG... và Lua
redis-cli ACL SETUSER app on '>mật-khẩu-app' '~*' '&*' +@all -@dangerous -@scripting
# reader: chỉ đọc
redis-cli ACL SETUSER reader on '>mật-khẩu-reader' '~*' resetchannels -@all +@read +@connection -@dangerous '+acl|whoami'
# Tắt user default để mọi kết nối phải đăng nhập bằng user có tên
redis-cli --user admin ACL SETUSER default off
# Lưu ra file: mật khẩu được lưu dưới dạng mã băm SHA-256
redis-cli --user admin ACL SAVE
```

Nếu chỉ cần chặn đúng một lệnh thì dùng `-flushall -flushdb`. Chặn cả nhóm `-@dangerous` an toàn hơn, vì nhóm này còn các lệnh nguy hiểm khác như `KEYS`, `CONFIG`, `DEBUG`, `SHUTDOWN`.

### 3.4 Kiểm tra và giám sát

```bash
REDISCLI_AUTH='<mk-reader>' redis-cli --user reader FLUSHALL
# NOPERM User reader has no permissions to run the 'flushall' command
redis-cli --user admin ACL LIST          # danh sách user và quyền
redis-cli --user admin ACL LOG 10        # các lần bị từ chối: user nào, lệnh nào, từ địa chỉ nào
```

**Ghi chú:** cách cũ là `rename-command FLUSHALL ""` trong `redis.conf`. Cách này áp cho mọi user và làm hỏng các công cụ cần lệnh đó, nên với Redis 6 trở lên nên dùng ACL.

**Thực hành:** [Phần 3 bài 3](part3/03-redis-acl/). User `reader` bị `NOPERM` với `SET`, `DEL`, `FLUSHALL`, `KEYS`, `CONFIG`; user `app` bị `NOPERM` với `FLUSHALL`, `CONFIG SET`, `KEYS`, `EVAL`; ACL vẫn còn sau khi restart.

---

## Câu 4. Cài Python 3.11 từ mã nguồn trên Rocky Linux 9 để đảm bảo tương thích với Ansible

### 4.1 Nguyên tắc

- **Không thay `python3` của hệ thống (3.9).** `dnf`, các công cụ của hệ điều hành, và module `dnf` của Ansible trên máy đích đều dùng nó. Vì vậy cài bằng **`make altinstall`** vào `/usr/local`: lệnh này chỉ tạo `python3.11`, không ghi đè `python3`. Lệnh `make install` thì tạo thêm lệnh `python3`, có thể chen lên trước `/usr/bin/python3` trong `PATH`.
- Build bằng user thường; chỉ bước cài mới dùng `sudo`.
- Kiểm tra mã băm SHA-256 của file mã nguồn với giá trị công bố trên trang python.org.

### 4.2 Các bước

```bash
# 1. Công cụ build và thư viện -devel (gdbm-devel nằm ở kho CRB nên bật kho này cho lệnh cài)
sudo dnf -y --enablerepo=crb install gcc make tar openssl-devel bzip2-devel libffi-devel zlib-devel \
  xz-devel sqlite-devel readline-devel ncurses-devel gdbm-devel libuuid-devel tk-devel

# 2. Tải mã nguồn và kiểm tra SHA-256
mkdir -p ~/build && cd ~/build
curl -fsSLO https://www.python.org/ftp/python/3.11.17/Python-3.11.17.tgz
echo "53cdee63ac4bf12387b7b33a53d3b1f8f4941cad73807a7b4fe91bb001ef004a  Python-3.11.17.tgz" | sha256sum -c -
tar xzf Python-3.11.17.tgz && cd Python-3.11.17

# 3. configure, make
./configure --prefix=/usr/local          # production: thêm --enable-optimizations --with-lto
make -j"$(nproc)"

# 4. Cài song song với python3 của hệ thống
sudo make altinstall

# 5. Kiểm tra
python3.11 -VV                           # Python 3.11.17
python3 --version                        # vẫn là Python 3.9.25
python3.11 -c "import ssl, sqlite3, ctypes, lzma, bz2, readline, zlib, uuid, dbm.gnu, curses"
```

Thiếu thư viện `-devel` nào thì module tương ứng sẽ không được build (ví dụ thiếu `openssl-devel` thì không có `ssl`, và pip sẽ không tải được gói). Vì vậy phải đọc dòng "necessary bits to build these optional modules were not found" ở cuối output `make`. Trong bài thực hành chỉ thiếu module `nis`; đây là dịch vụ cũ đã bị bỏ từ Python 3.13, không ảnh hưởng gì.

### 4.3 Tương thích với Ansible

| Vai trò | Yêu cầu | Dùng gì trên Rocky Linux 9 |
|---|---|---|
| Control node chạy ansible-core 2.21 | Python 3.12-3.14 | `python3.12` của AppStream, trong virtualenv (câu 8) |
| Control node nếu chỉ có Python 3.11 | Tối đa ansible-core 2.19, bản này hết hỗ trợ ngày 30/11/2026 | Không khuyến nghị |
| Máy đích (managed node) với ansible-core 2.21 | Python 3.9-3.14 | `/usr/bin/python3` (3.9) |
| Script tự động hóa, gọi API | — | `python3.11` vừa build, trong venv |

Lưu ý quan trọng: Python 3.11 tự build **không có** thư viện liên kết `python3-dnf` và `python3-libselinux` của hệ thống. Nếu đặt `ansible_python_interpreter=/usr/local/bin/python3.11` cho máy đích, module `dnf` sẽ lỗi và các module chép file sẽ không gán đúng nhãn SELinux. Vì vậy inventory trong bài đặt `ansible_python_interpreter=/usr/bin/python3`.

**Ghi chú:**
- **Không bật tối ưu khi build trong bài thực hành:** `--enable-optimizations` (PGO, chạy bộ test để lấy profile) và `--with-lto` làm Python nhanh hơn khoảng 10-20%, nhưng build lâu hơn nhiều. Cùng mã nguồn, build có PGO + LTO mất 8,5 phút trên máy 16 luồng; build thường trên máy ảo 2 vCPU mất 2 phút 35 giây. Production nên bật hai tùy chọn này.
- **Production nên ưu tiên gói của AppStream:** Rocky Linux 9 có sẵn gói `python3.11` (`dnf install python3.11`, bản 3.11.13 được Red Hat vá bảo mật). Gói này nhận bản vá tự động qua `dnf`. Cài từ mã nguồn chỉ cần khi cần đúng một bản vá cụ thể hoặc tùy chọn build riêng, như đề yêu cầu.

**Thực hành:** [Phần 3 bài 4](part3/04-python-source/).

---

## Câu 5. Quản lý gói bằng pip và cập nhật lên bản bảo trì mới nhất

### 5.1 Quản lý gói

```bash
python3.11 -m pip --version                 # luôn gọi pip qua đúng trình thông dịch
python3.11 -m venv ~/py311-venv             # mỗi dự án một virtualenv
source ~/py311-venv/bin/activate
python -m pip install --upgrade pip
pip install requests                        # cài
pip install "requests>=2.32,<3"             # cài theo khoảng phiên bản
pip install --upgrade requests              # nâng cấp
pip uninstall -y requests                   # gỡ
pip list                                    # danh sách gói
pip list --outdated                         # gói có bản mới
pip show requests                           # thông tin, gói phụ thuộc
pip freeze > requirements.txt               # ghim phiên bản để dựng lại môi trường giống hệt
pip install -r requirements.txt
pip check                                   # kiểm tra xung đột phụ thuộc
```

Nguyên tắc:
- **Không dùng `sudo pip install`.** Cài thẳng vào Python của hệ thống dễ làm hỏng các gói do `dnf` quản lý.
- **Gọi `python3.11 -m pip`** thay cho `pip`, để chắc chắn đang cài vào đúng Python.
- **Production nên ghim phiên bản** (`requirements.txt`, có thể dùng `--require-hashes`), và quét lỗ hổng định kỳ (ví dụ bằng `pip-audit`).

### 5.2 Cập nhật Python lên bản bảo trì mới nhất của nhánh 3.11

- Python 3.11 đã sang giai đoạn **chỉ vá bảo mật** từ 04/2024 và hết hỗ trợ vào 10/2027.
- Bản mới nhất hiện là **3.11.18** (25/10/2026); bản "3.11.8" nêu trong đề đã cũ.
- Các bản vá bảo mật của nhánh này **chỉ phát hành dạng mã nguồn** (không còn bộ cài sẵn), nên cập nhật nghĩa là build lại.

```bash
python3.11 --version                        # 3.11.17
# Lặp lại các bước ở câu 4 với Python-3.11.18.tgz (SHA-256 5f62711b...814e), rồi:
sudo make altinstall                        # ghi đè /usr/local/bin/python3.11
python3.11 --version                        # 3.11.18
~/py311-venv/bin/python --version           # 3.11.18: venv cũ vẫn chạy, không phải tạo lại
```

- **Cùng nhánh 3.11.x thì giữ được venv:** các bản vá giữ nguyên tương thích nhị phân (ABI), nên venv và các gói đã cài vẫn dùng được.
- **Lên nhánh mới (3.11 → 3.12) thì phải làm lại venv:** tạo venv mới và cài lại gói từ `requirements.txt`.
- **Tự động hóa:** việc cập nhật được viết thành role Ansible `python311` (câu 9, Phần 3 bài 9). Role đọc phiên bản đang cài và **chỉ build khi khác phiên bản mục tiêu**, nên chạy lại bao nhiêu lần cũng an toàn.

**Thực hành:** [bài 4](part3/04-python-source/) (pip, venv, requests, `pip list`) và [bài 9](part3/09-ansible-python/) (cập nhật 3.11.17 lên 3.11.18; lần chạy 1 `changed=6`, lần 2 và 3 `changed=0`).

---

## Câu 6. TaskGroup trong Python 3.11 cho lập trình không đồng bộ, so sánh với gather()

### 6.1 Cách dùng

`asyncio.TaskGroup` (mới từ 3.11) là một context manager: các tác vụ tạo trong khối `async with` được đảm bảo **đều đã kết thúc khi ra khỏi khối**. Đây là mô hình "structured concurrency". Kết hợp với `asyncio.timeout()` (cũng mới từ 3.11) để giới hạn thời gian cho cả nhóm:

```python
import asyncio
import aiohttp

async def fetch(session, url):
    async with session.get(url) as resp:
        resp.raise_for_status()
        return url, resp.status, len(await resp.read())

async def main(urls):
    async with aiohttp.ClientSession() as session:
        try:
            async with asyncio.timeout(5):                    # cả nhóm tối đa 5 giây
                async with asyncio.TaskGroup() as tg:
                    tasks = [tg.create_task(fetch(session, u)) for u in urls]
            return [t.result() for t in tasks]
        except TimeoutError:
            print("Quá 5 giây: các tác vụ chưa xong đã bị hủy")
        except* aiohttp.ClientResponseError as eg:            # except* bắt ExceptionGroup
            for e in eg.exceptions:
                print("Lỗi:", e.status, e.request_info.url)
```

### 6.2 So sánh với `asyncio.gather()`

| Tiêu chí | `TaskGroup` | `gather()` | `gather(..., return_exceptions=True)` |
|---|---|---|---|
| Một tác vụ lỗi | **Hủy các tác vụ còn lại**, gom lỗi thành `ExceptionGroup` | Ném lỗi đầu tiên ra ngay, nhưng **các tác vụ khác vẫn chạy ngầm** | Chạy hết, lỗi nằm lẫn trong danh sách kết quả |
| Nhiều tác vụ cùng lỗi | Giữ đủ mọi lỗi (`except*`) | Chỉ thấy lỗi đầu tiên | Thấy đủ, nhưng phải tự kiểm tra từng phần tử |
| Khi ra khỏi khối/lệnh | Chắc chắn không còn tác vụ nào chạy | Có thể còn tác vụ "mồ côi" | Mọi tác vụ đã xong |
| Tạo tác vụ động | `tg.create_task()` bất cứ lúc nào trong khối | Phải có đủ danh sách ngay từ đầu | Như cột bên trái |
| Phiên bản | Python 3.11+ | Mọi phiên bản | Mọi phiên bản |

**Nên dùng:**
- **TaskGroup** khi các tác vụ là một khối thống nhất: một phần lỗi thì cả nhóm vô nghĩa, ví dụ gom dữ liệu từ nhiều API để dựng một báo cáo.
- **`gather(return_exceptions=True)`** khi muốn lấy được càng nhiều kết quả càng tốt, phần lỗi bỏ qua, ví dụ kiểm tra tình trạng nhiều máy chủ.

**Thực hành:** [Phần 3 bài 5](part3/05-python-taskgroup/), 5 kịch bản:

| Kịch bản | Kết quả |
|---|---|
| 5 URL thật | Xong trong 0,26 giây (chạy tuần tự sẽ mất 0,62 giây) |
| 5 URL chậm 1-3 giây | Xong sau 3,0 giây, thay vì 10 giây nếu chạy tuần tự |
| Có URL chậm 7 và 9 giây | Sau 5 giây báo `TimeoutError`, xong 3/5, hủy 2 |
| Có URL lỗi 500 (TaskGroup) | `ExceptionGroup` chứa 1 lỗi, 4 tác vụ còn lại bị hủy ngay |
| Cùng dữ liệu, dùng `gather(return_exceptions=True)` | Chạy hết cả 4 tác vụ còn lại, lỗi nằm lẫn trong kết quả |

---

## Câu 7. Cài NodeJS 20 trên Rocky Linux 9 và cấu hình push-server cơ bản

### 7.1 Cài Node.js 20

```bash
sudo dnf module list nodejs                 # có các stream 18, 20, 22, 24
sudo dnf -y module reset nodejs
sudo dnf -y module enable nodejs:20
sudo dnf -y install nodejs npm
node --version                              # v20.20.2
```

**Ghi chú:**
- Node.js 20 đã **hết hỗ trợ từ 30/04/2026**. Bài làm dùng 20 theo đúng đề; hệ thống thật nên dùng stream `nodejs:22` hoặc `nodejs:24` (cùng lệnh, chỉ đổi số).
- Các cách cài khác như kho NodeSource hay `nvm` cũng được, nhưng module AppStream được ký, cập nhật qua `dnf`, và không cần thêm kho ngoài.

### 7.2 Push-server cơ bản

Một push-server là một tiến trình Node.js giữ nhiều kết nối WebSocket lâu dài và đẩy tin tới client ngay khi có sự kiện (xem câu 7 Phần 1). Phần lõi dùng thư viện `ws`:

```js
const http = require('node:http');
const { WebSocketServer, WebSocket } = require('ws');

const server = http.createServer();
const wss = new WebSocketServer({ server, path: '/chat' });
wss.on('connection', (ws) => {
  ws.on('message', (data) => {
    for (const client of wss.clients) {                 // phát tin cho mọi client
      if (client.readyState === WebSocket.OPEN) client.send(data.toString());
    }
  });
});
server.listen(8080, '127.0.0.1');
```

Triển khai cho chạy như một dịch vụ thật:

```bash
sudo useradd --system --no-create-home --shell /sbin/nologin chatsrv   # user riêng, không đăng nhập được
sudo mkdir -p /opt/chat-server && sudo cp server.js package.json package-lock.json /opt/chat-server/
cd /opt/chat-server && sudo npm ci --omit=dev                          # cài đúng phiên bản trong package-lock
```

```ini
# /etc/systemd/system/chat-server.service
[Service]
User=chatsrv
WorkingDirectory=/opt/chat-server
ExecStart=/usr/bin/node /opt/chat-server/server.js
Restart=on-failure
LimitNOFILE=65535          # mỗi kết nối là một file descriptor; mặc định chỉ 1024
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now chat-server
```

Trước push-server thường đặt nginx làm reverse proxy cho WebSocket (TLS, một cổng 443 chung):

```nginx
location /bitrix/subws/ {
    proxy_pass http://127.0.0.1:8010;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 1h;                  # kết nối WebSocket sống lâu
}
```

**Ghi chú:** phần nginx không có trong bài thực hành. Client kiểm thử nối thẳng vào cổng của push-server trong mạng nội bộ, cho bớt thành phần cần dựng.

**Thực hành:**
- [Bài 7](part3/07-nodejs-chat/): 1000 kết nối WebSocket mở đồng thời trong 0,68 giây, trên một tiến trình Node (khoảng 72 MB RAM, 7 luồng). 1000 ping cùng lúc có độ trễ trung vị 68 ms; 10 tin chat được phát đủ 10.000 lượt sau 0,32 giây.
- [Bài 10](part3/10-bitrix-cluster/): push-server theo kiến trúc Bitrix (tiến trình `sub` và `pub`, Redis làm cầu nối giữa các node).

---

## Câu 8. Cài ansible-core (mới hơn 2.14.2) và viết playbook triển khai Redis

### 8.1 Cài đặt

Theo câu 9 Phần 1, chọn **ansible-core 2.21**: bản này còn được hỗ trợ đến 30/11/2027, chạy trên Python 3.12, và quản lý được máy đích dùng Python 3.9.

```bash
dnf list python3.12
sudo dnf -y install python3.12 python3.12-pip
sudo python3.12 -m venv /opt/ansible-core-2.21
sudo /opt/ansible-core-2.21/bin/pip install 'ansible-core>=2.21,<2.22'
echo 'export PATH=/opt/ansible-core-2.21/bin:$PATH' | sudo tee /etc/profile.d/ansible-core.sh
ansible --version                           # ansible [core 2.21.x] ... python version = 3.12.x
ansible-galaxy collection install -r requirements.yml     # ansible.posix (cho module sysctl)
```

**Ghi chú:** không dùng gói `ansible-core` trong AppStream của Rocky 9, vì gói này là nhánh 2.14 và Red Hat chỉ hỗ trợ trong phạm vi hẹp (xem câu 9 Phần 1).

### 8.2 Playbook

Inventory (`inventory.ini`):

```ini
[redis_servers]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
```

Playbook (`playbook.yaml`, rút gọn; bản đầy đủ ở Phần 3 bài 8):

```yaml
- name: Triển khai Redis 7.2 trên localhost
  hosts: redis_servers
  become: true
  vars:
    secrets_dir: "{{ lookup('ansible.builtin.env', 'HOME') }}/.aasc3"
    redis_acl_users:
      - name: admin
        password: "{{ lookup('ansible.builtin.password', secrets_dir ~ '/redis-admin.pass', length=40, chars=['ascii_lowercase', 'digits']) }}"
        rules: "~* &* +@all"
      - name: reader
        password: "{{ lookup('ansible.builtin.password', secrets_dir ~ '/redis-reader.pass', length=40, chars=['ascii_lowercase', 'digits']) }}"
        rules: "~* resetchannels -@all +@read +@connection -@dangerous"
  roles:
    - redis
```

Role `redis` (`part3/roles/redis/tasks/main.yml`) gồm các bước:

| Task | Module |
|---|---|
| Bật module stream và cài Redis 7.2 | `ansible.builtin.dnf: name: "@redis:7/common"` |
| Tắt THP bằng unit systemd | `ansible.builtin.copy` + `ansible.builtin.systemd_service` |
| `vm.overcommit_memory = 1` | `ansible.posix.sysctl` |
| Sinh `redis.conf` (bind IP nội bộ, RDB + AOF, `maxmemory` bằng 80% của `ansible_facts['memtotal_mb']`) | `ansible.builtin.template` |
| Sinh `users.acl` (mật khẩu ở dạng `password \| hash('sha256')`) | `ansible.builtin.template` |
| Bật và chạy Redis; restart qua handler chỉ khi cấu hình đổi | `ansible.builtin.systemd_service` |

```bash
ansible-playbook playbook.yaml --syntax-check
ansible-playbook playbook.yaml              # lần 1: dựng từ đầu
ansible-playbook playbook.yaml              # lần 2: changed=0
ansible-playbook playbook.yaml --check --diff
```

**Ghi chú:**
- **Phải dùng `/usr/bin/python3` trên máy đích:** module `dnf` cần thư viện `python3-dnf` của Python hệ thống. Bản thân Ansible vẫn chạy bằng Python 3.12 trong venv.
- **Sinh mật khẩu bằng `lookup('password')`:** lookup tạo mật khẩu ngẫu nhiên một lần, lưu ở file trên control node, các lần sau đọc lại đúng file đó. Nhờ vậy playbook vẫn idempotent và mật khẩu không nằm trong repo. Môi trường nhiều người dùng chung nên dùng `ansible-vault`.
- **Gọi fact theo cách mới:** ansible-core 2.21 cảnh báo cách gọi fact dạng biến cấp cao (`ansible_memtotal_mb`) sẽ bị bỏ ở bản 2.24, nên role dùng `ansible_facts['memtotal_mb']`.

**Thực hành:** [Phần 3 bài 8](part3/08-ansible-redis/):

| Lần chạy | Kết quả | Ý nghĩa |
|---|---|---|
| 1 | `changed=8` | Dựng Redis từ đầu |
| 2 | `changed=0` | Idempotent |
| 3 (sau khi cố ý sửa tay `maxmemory-policy`) | `changed=2` | Ansible sửa template về đúng, rồi restart Redis |
| 4 (`--check`) | `changed=0` | Chạy thử, không thay đổi gì |

---

## Câu 9. Tự động hóa triển khai ứng dụng bằng Ansible, quản lý cụm máy chủ

### 9.1 Cấu trúc dự án

```text
10-bitrix-cluster/
  ansible.cfg            # inventory, roles_path, forks, pipelining
  inventory.ini          # nhóm máy: redis_servers, push_servers
  group_vars/all.yml     # biến chung: user ACL, URL Redis, khóa bí mật (sinh bằng lookup password)
  site.yml               # playbook dựng cả cụm
  app/                   # mã nguồn push-server (push-server.js, package.json, package-lock.json)
roles/
  redis/  nodejs/  push_server/  python311/   # mỗi thành phần một role, dùng lại được ở nhiều bài
```

```ini
[all:vars]
ansible_python_interpreter=/usr/bin/python3
push_redis_host=172.31.0.164

[redis_servers]
rocky-ctl ansible_connection=local

[push_servers]
rocky-node1 ansible_host=172.31.x.x ansible_user=rocky
rocky-node2 ansible_host=172.31.y.y ansible_user=rocky
```

### 9.2 Quy trình triển khai một ứng dụng

1. **Chuẩn bị máy:** tạo máy (thủ công, hoặc bằng collection `amazon.aws`), đưa SSH key của control node vào máy đích.
2. **Cấu hình nền:** role `nodejs` cài runtime, role `redis` dựng hạ tầng.
3. **Triển khai ứng dụng** (role `push_server`):
   - tạo user hệ thống;
   - chép mã nguồn;
   - chạy `npm ci` **chỉ khi mã nguồn đổi**;
   - sinh file biến môi trường chứa bí mật (quyền `640`, `diff: false` để không in bí mật ra màn hình);
   - sinh unit systemd dạng template `push-server@.service` (một file cho cả `@sub` và `@pub`).
4. **Restart có điều kiện:** handler chỉ restart dịch vụ khi file thật sự thay đổi.
5. **Kiểm tra sau triển khai:** `wait_for` chờ cổng mở, `uri` gọi `/server-stat` của từng node.
6. **Chạy lại để xác nhận idempotent:** lần sau phải ra `changed=0`.

### 9.3 Quản lý cụm

| Nhu cầu | Cách làm |
|---|---|
| Cập nhật không gián đoạn (rolling update) | `serial: 1`: xử lý từng node, node kia vẫn phục vụ; thêm `max_fail_percentage` để dừng khi lỗi nhiều |
| Thêm máy | Thêm một dòng vào inventory rồi chạy lại `site.yml` |
| Chỉ chạy trên một phần cụm | `--limit rocky-node2`, hoặc `--tags` |
| Lệnh nhanh trên nhiều máy | `ansible push_servers -b -m ansible.builtin.shell -a "systemctl is-active push-server@sub"` |
| Chạy nhanh hơn | `forks = 10` (chạy song song nhiều máy), `pipelining = True` (bớt vòng SSH) |
| Thao tác cần chạy trên máy khác | `delegate_to` (ví dụ kiểm tra push-server từ control node, rút node khỏi load balancer) |
| Bí mật | `lookup('password')` hoặc `ansible-vault`, không ghi bí mật vào repo |
| Phát hiện cấu hình bị lệch | `ansible-playbook site.yml --check --diff` |

**Thực hành:** [Phần 3 bài 10](part3/10-bitrix-cluster/): một lệnh `ansible-playbook site.yml` dựng Redis trên `rocky-ctl`, Node.js 20 và push-server trên 2 node (lần 1: `rocky-ctl changed=2`, mỗi node `changed=9`). Lần chạy 2 cả 3 máy `changed=0`. Kiểm thử tích hợp: 200 client chia đều 2 node, 200/200 nhận đủ 10/10 tin, kể cả tin đi vào qua node khác. Sau khi cố ý tắt tiến trình `sub` của node2, chạy lại playbook giới hạn ở node2 thì dịch vụ được bật lại.

---

## Câu 10. Giảm thiểu lỗ hổng bảo mật trong Redis 7.2 bằng cập nhật và ACL

### 10.1 Các lỗ hổng tiêu biểu

Danh sách lấy từ changelog của gói `redis` trên Rocky Linux 9 (`rpm -q --changelog redis`):

| CVE | Thành phần | Mô tả ngắn | Vá ở |
|---|---|---|---|
| CVE-2025-49844 ("RediShell") | Lua | Lỗi use-after-free trong bộ phân tích cú pháp Lua; script độc hại có thể thực thi mã từ xa (CVSS 10.0) | 7.2.11 |
| CVE-2025-46817 / 46818 / 46819 | Lua | Tràn số nguyên trong `unpack`; script chạy trong ngữ cảnh của user khác; đọc ngoài vùng nhớ | 7.2.11 |
| CVE-2025-32023 | HyperLogLog | Chuỗi HyperLogLog bị sửa có chủ đích gây ghi ngoài vùng nhớ, có thể dẫn tới thực thi mã | 7.2.10 |
| CVE-2024-46981 | Lua | Thao túng bộ thu gom rác của Lua gây use-after-free, có thể thực thi mã | 7.2.7 |
| CVE-2025-21605 | Mạng | Client **chưa xác thực** làm bộ đệm output phình không giới hạn (từ chối dịch vụ) | 7.2.8 |
| CVE-2026-23479, 23631, 25243; CVE-2026-66373, 72568 | Theo changelog | Các bản vá năm 2026 | 7.2.14; 7.2.16 |

Điểm chung: phần lớn các lỗ hổng nghiêm trọng đòi hỏi kẻ tấn công **đã kết nối được và được phép chạy** lệnh Lua (`EVAL`, `FUNCTION`) hoặc lệnh HyperLogLog (`PFADD`, `PFMERGE`...). Vì vậy cần kết hợp cập nhật với hạn chế quyền.

### 10.2 Cập nhật

```bash
rpm -q redis                                    # redis-7.2.16-1.module+el9.8.0...
rpm -q --changelog redis | grep -oE "CVE-[0-9]{4}-[0-9]+" | sort -u
sudo dnf check-update redis
sudo dnf updateinfo list --security            # các bản vá bảo mật (RLSA) đang chờ
sudo dnf -y update redis && sudo systemctl restart redis
```

- **Đọc changelog, đừng so số phiên bản:** Red Hat và Rocky có thể vá thêm vào gói mà không đổi số phiên bản upstream, nên muốn biết gói đã vá lỗi nào thì đọc changelog.
- **Cụm nhiều máy:** cập nhật bằng Ansible (`dnf: name=redis state=latest` kèm `serial: 1`) trong khung giờ bảo trì. Nếu có replica thì cập nhật replica trước, chuyển vai trò master (failover), rồi mới cập nhật máy master cũ.
- **Theo dõi bản vá:** đăng ký nhận thông báo bảo mật của Rocky (RLSA) và GitHub Security Advisories của Redis. Dòng 7.2 còn được vá đến 12/2029.

### 10.3 ACL: thu hẹp bề mặt tấn công

```bash
# Ứng dụng không dùng Lua và HyperLogLog thì cấm luôn
ACL SETUSER app on '>mk-app' '~app:*' '&*' +@all -@dangerous -@scripting -@hyperloglog
# Ứng dụng cần Lua: chỉ cho gọi function đã nạp sẵn, không cho nạp hoặc chạy script tùy ý
ACL SETUSER worker on '>mk-worker' '~job:*' -@all +@read +@write +fcall +fcall_ro
# Tắt user default để không còn truy cập ẩn danh
ACL SETUSER default off
ACL SAVE
```

Kèm theo trong `redis.conf` (mặc định của Redis 7, nên ghi rõ):

```conf
enable-debug-command no        # chặn DEBUG (hay được dùng khi khai thác)
enable-module-command no       # chặn nạp module lạ lúc chạy
protected-mode yes
bind 127.0.0.1 -::1 <IP-nội-bộ>
```

### 10.4 Các lớp bảo vệ khác

- **Mạng:** không mở 6379 ra Internet, chỉ cho phép từ máy ứng dụng (firewalld hoặc Security Group). Dùng TLS khi Redis đi qua mạng không tin cậy.
- **Tiến trình:** Redis chạy bằng user `redis` (không phải root), bị SELinux giới hạn trong domain `redis_t`.
- **Giám sát:** theo dõi `ACL LOG` để biết ai đang thử lệnh bị cấm; theo dõi `INFO clients` để phát hiện số kết nối hay bộ đệm tăng bất thường.

**Thực hành:**
- Phần 3 bài 1 in danh sách CVE trong changelog của gói đang cài, và cấu hình `bind` + xác thực.
- Bài 3 cho thấy user `app` (`-@scripting`) bị `NOPERM` khi chạy `EVAL`.
- Role `redis` ở bài 8 ghi rõ `enable-debug-command no`, `enable-module-command no`, và tắt user `default`.
