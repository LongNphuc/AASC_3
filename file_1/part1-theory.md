# Phần 1: Câu hỏi lý thuyết

## Câu 1. Vai trò của Redis 7.2 trong kiến trúc ứng dụng

### 1.1 Vai trò

Redis là một kho dữ liệu dạng **key-value lưu trong bộ nhớ (in-memory)**. Trong kiến trúc ứng dụng, Redis thường nằm giữa tầng backend và cơ sở dữ liệu chính (SQL) và đảm nhiệm các vai trò sau:

- **Bộ nhớ đệm (cache):** lưu kết quả các truy vấn tốn kém hoặc được đọc lặp lại nhiều lần (danh sách, thống kê, response API), giúp backend không phải truy vấn DB liên tục.
- **Kho dữ liệu tạm thời:** lưu session, token, bộ đếm, rate limiting, khóa phân tán.
- **Hàng đợi công việc (job queue):** làm nơi lưu job cho các worker chạy nền (các thư viện như BullMQ, Sidekiq, Celery đều hỗ trợ Redis).
- **Pub/Sub và Stream:** truyền thông điệp thời gian thực giữa các thành phần (ví dụ push-server trong Bitrix24).

Giá trị (value) trong Redis hỗ trợ nhiều cấu trúc dữ liệu: String, Hash, List, Set, Sorted Set, Stream, Bitmap, HyperLogLog... Đây là điểm khiến Redis đa năng hơn một cache key-value thông thường.

### 1.2 Vì sao Redis phù hợp làm bộ nhớ đệm và kho dữ liệu tạm thời

- Dữ liệu nằm trong RAM nên đọc/ghi nhanh hơn nhiều so với truy vấn xuống đĩa của DB quan hệ.
- Giảm số lần truy vấn lặp lại xuống DB, qua đó giảm tải CPU, I/O và chi phí mở rộng DB.
- Các loại dữ liệu như session, cache, job tạm thời có thể mất hoặc tái tạo được, không cần lưu bền vào DB chính.
- Có cơ chế TTL (tự hết hạn) và chính sách loại bỏ khi đầy bộ nhớ (`maxmemory-policy`), rất phù hợp với cache.
- Nếu cần backup, Redis có thể bật RDB/AOF (xem câu 2).

Lưu ý: dữ liệu quan trọng lâu dài (đơn hàng, tài khoản...) vẫn phải được lưu ở DB chính.

### 1.3 Sub-millisecond latency và lợi ích

Độ trễ dưới một mili-giây là **đặc tính hiệu năng do thiết kế của Redis**, đến từ:

1. **Dữ liệu nằm trong RAM:** truy cập RAM ở mức nano-giây, trong khi đĩa ở mức micro đến mili-giây. Đĩa chỉ dùng để lưu RDB/AOF phục vụ phục hồi, không tham gia vào việc phục vụ lệnh.
2. **Cấu trúc dữ liệu tối ưu trong bộ nhớ:** key được lưu trong bảng băm (hash table) nên tra cứu key trung bình O(1); mỗi kiểu dữ liệu có cấu trúc riêng hiệu quả (ví dụ Sorted Set dùng skip list).
3. **Thực thi lệnh đơn luồng:** không cần khóa (lock), không tốn chi phí chuyển ngữ cảnh giữa các luồng, và mỗi lệnh có tính nguyên tử (atomic). Từ Redis 6 có thể bật I/O threads cho phần đọc/ghi mạng, nhưng việc thực thi lệnh vẫn đơn luồng.
4. **I/O multiplexing (epoll) và giao thức RESP đơn giản:** một luồng duy nhất nhờ hệ điều hành theo dõi toàn bộ kết nối, chỉ xử lý những kết nối đã có dữ liệu sẵn sàng và ngủ khi không có việc, nên phục vụ được hàng nghìn client mà không tốn một luồng cho mỗi kết nối. Giao thức RESP có định dạng đơn giản nên phân tích nhanh, tốn ít CPU.

**Lợi ích:**

- Phản hồi nhanh cho người dùng: truy vấn SQL có thể mất từ vài đến hàng trăm mili-giây, đọc từ cache chỉ dưới 1 ms.
- Thông lượng cao: một instance có thể xử lý hàng trăm nghìn lệnh mỗi giây, chịu được lưu lượng đột biến mà không đè lên DB.
- Giảm tải và chi phí cho DB chính.
- Đáp ứng các bài toán thời gian thực: session, leaderboard, rate limiting, hàng đợi job, thông báo đẩy.

Lưu ý: sub-millisecond là thời gian xử lý một lệnh trên server. Độ trễ client nhìn thấy còn cộng thêm thời gian truyền mạng (network round-trip); có thể giảm bằng pipelining.

**Nhược điểm cần lưu ý:** một lệnh chạy chậm (ví dụ `KEYS *`, `SMEMBERS` trên set rất lớn, Lua script dài) sẽ chặn các lệnh khác do thực thi đơn luồng. Nên dùng `SCAN` thay `KEYS`, và `UNLINK` thay `DEL` với key lớn.

---

## Câu 2. Nguyên lý hoạt động của RDB và AOF; khi nào dùng kết hợp cả hai

### 2.1 RDB (Redis Database snapshot)

**Nguyên lý:** theo chu kỳ cấu hình (ví dụ `save 300 10`: sau 300 giây nếu có ít nhất 10 thay đổi), Redis tạo một **bản chụp toàn bộ dataset** tại một thời điểm và ghi ra một file nhị phân nén (`dump.rdb`).

Cách thực hiện:

1. Redis gọi `fork()` để tạo tiến trình con. `fork()` được gọi bởi luồng chính nên chỉ xảy ra giữa hai lệnh, bộ nhớ luôn ở trạng thái nhất quán.
2. Nhờ cơ chế **copy-on-write** của hệ điều hành, tiến trình con nhìn thấy bộ nhớ đúng như lúc fork. Tiến trình cha tiếp tục phục vụ lệnh; vùng nhớ nào cha sửa sẽ được sao chép riêng, bản của con không bị ảnh hưởng.
3. Tiến trình con ghi dữ liệu ra file tạm, xong thì đổi tên thay thế file RDB cũ, rồi tự kết thúc. Nếu sập giữa chừng, file RDB cũ vẫn còn nguyên vẹn.

**Ưu điểm:** file gọn, một file duy nhất, dễ backup và sao chép đi nơi khác; khởi động lại và khôi phục nhanh hơn AOF; ít ảnh hưởng hiệu năng lúc chạy bình thường.

**Nhược điểm:** có thể **mất toàn bộ dữ liệu ghi từ lần snapshot cuối đến lúc sập** (có thể vài phút); với dataset lớn, `fork()` có thể gây khựng ngắn và tốn thêm RAM do copy-on-write.

### 2.2 AOF (Append Only File)

**Nguyên lý:** Redis **ghi nối tiếp mọi lệnh ghi** (SET, INCR, LPUSH...) vào file log. Khi khởi động lại, Redis **phát lại (replay)** các lệnh này để dựng lại dữ liệu.

Mức độ bền phụ thuộc vào chính sách `appendfsync`:

| Giá trị | Hành vi | Mức mất dữ liệu | Hiệu năng |
|---|---|---|---|
| `always` | fsync sau mỗi lệnh ghi | Gần như không mất | Chậm nhất |
| `everysec` (mặc định, khuyến nghị) | fsync mỗi giây | Tối đa khoảng 1 giây | Cân bằng |
| `no` | để hệ điều hành quyết định | Có thể mất nhiều | Nhanh nhất |

**AOF rewrite:** vì log lưu cả lịch sử (ghi đè một key 1000 lần thì có 1000 dòng), Redis có cơ chế rewrite tự động để nén log về trạng thái cuối cùng mà không mất dữ liệu (ví dụ nhiều lệnh `INCR` được thay bằng một lệnh `SET`). Từ Redis 7.0, AOF dùng **Multi Part AOF**: gồm file base (bản nền), các file incremental (lệnh ghi sau đó) và file manifest quản lý, giúp rewrite hiệu quả hơn.

**Ưu điểm:** độ bền cao hơn RDB, mất tối đa khoảng 1 giây với `everysec`; log dễ đọc và có công cụ sửa file hỏng (`redis-check-aof`).

**Nhược điểm:** file lớn hơn RDB; khởi động chậm hơn vì phải replay lệnh; có chi phí fsync lên đĩa.

### 2.3 So sánh

| Tiêu chí | RDB | AOF |
|---|---|---|
| Cách lưu | Snapshot toàn bộ theo chu kỳ | Ghi log mọi lệnh ghi |
| Mức mất dữ liệu | Có thể mất nhiều phút | Tối đa khoảng 1 giây (`everysec`) |
| Tốc độ khởi động lại | Nhanh | Chậm hơn |
| Kích thước file | Nhỏ, gọn | Lớn hơn |
| Phù hợp backup | Rất tốt | Kém hơn |

### 2.4 Khi nào nên kết hợp cả hai

Nên bật **cả RDB và AOF** khi dữ liệu trong Redis quan trọng, không muốn mất (hàng đợi job không được mất, session cần giữ), đồng thời muốn có bản backup gọn và khả năng khôi phục nhanh:

- **AOF** đảm bảo độ bền, mất ít dữ liệu nhất khi sập.
- **RDB** dùng để backup định kỳ (dễ sao chép lên nơi lưu trữ khác), dựng nhanh instance mới (replica, môi trường test), và làm phương án dự phòng khi file AOF bị hỏng.

Lưu ý khi khởi động: nếu AOF được bật (`appendonly yes`), Redis **chỉ nạp AOF** vì nó đầy đủ và mới hơn, và bỏ qua file RDB; nếu AOF tắt thì mới nạp RDB. Do đó file RDB khi bật cả hai chủ yếu phục vụ backup và dự phòng, không phải nạp song song với AOF.

Tùy nhu cầu, các cấu hình thường gặp:

- Dữ liệu quan trọng: bật cả hai.
- Cache thuần (mất thì nạp lại từ DB): có thể tắt cả hai để nhanh nhất.
- Chấp nhận mất vài phút dữ liệu, ưu tiên đơn giản: chỉ dùng RDB.

Cấu hình tối thiểu trong `redis.conf` khi kết hợp cả hai:

```conf
save 300 10
appendonly yes
appendfsync everysec
```

---

## Câu 3. Các tính năng mới và cải tiến trong Redis 7.2

Redis 7.2 (bản GA 7.2.0 phát hành tháng 8/2023) tập trung vào hiệu năng, tiết kiệm bộ nhớ, độ bền dữ liệu và khả năng vận hành. Cần phân biệt hai khái niệm:

- **Redis core (Redis Open Source 7.2):** máy chủ Redis thuần, cài từ kho của hệ điều hành hoặc từ mã nguồn.
- **Redis Stack 7.2:** Redis core cộng thêm các module như JSON, Search, TimeSeries, Bloom. Tính năng xử lý JSON thuộc Redis Stack, **không có sẵn trong Redis core 7.2**.

### 3.1 ZRANK / ZREVRANK hỗ trợ tùy chọn `WITHSCORE` (Sorted Set)

Trước 7.2, muốn biết thứ hạng và điểm của một phần tử phải gọi 2 lệnh (`ZRANK` + `ZSCORE`), tức 2 lần round-trip, hoặc phải gói trong `MULTI`/Lua để đảm bảo nhất quán. Từ 7.2, một lệnh trả về cả hai:

```text
127.0.0.1:6379> ZADD leaderboard 1500 alice 2300 bob 1800 carol
(integer) 3
127.0.0.1:6379> ZREVRANK leaderboard carol WITHSCORE
1) (integer) 1
2) "1800"
```

**Lợi ích:** giảm một nửa số round-trip cho các bài toán bảng xếp hạng (leaderboard, xếp hạng người dùng); thứ hạng và điểm được lấy trong cùng một lệnh nên luôn khớp nhau, không bị lệnh khác chen vào giữa.

### 3.2 Tối ưu hiệu năng cho Sorted Set

Redis 7.2 có nhiều tối ưu nội bộ cho Sorted Set, nổi bật là **chuyển đổi score kiểu số thực (double) sang chuỗi nhanh hơn** khi trả kết quả (dùng thuật toán chuyển đổi mới thay cho hàm chuẩn của C). Các lệnh trả về score như `ZRANGE ... WITHSCORES`, `ZRANGEBYSCORE ... WITHSCORES`, `ZSCORE` được hưởng lợi, nhất là khi trả về tập kết quả lớn.

Mức cải thiện phụ thuộc vào workload, nên đo bằng `redis-benchmark` trước và sau khi nâng cấp thay vì dựa vào con số chung.

### 3.3 Set nhỏ dùng mã hóa listpack (tiết kiệm bộ nhớ)

Trước 7.2, Set chỉ có 2 kiểu mã hóa nội bộ: `intset` (khi toàn bộ phần tử là số nguyên) và `hashtable`. Một Set nhỏ chứa chuỗi (ví dụ 3 tag) vẫn phải dùng `hashtable`, tốn nhiều bộ nhớ cho con trỏ và bảng băm.

Redis 7.2 thêm mã hóa **listpack** (mảng liên tục, gọn) cho Set nhỏ chứa chuỗi, điều khiển bằng 2 tham số mới:

```conf
set-max-listpack-entries 128   # tối đa 128 phần tử
set-max-listpack-value 64      # mỗi phần tử tối đa 64 byte
```

```text
127.0.0.1:6379> SADD tags redis python nodejs
(integer) 3
127.0.0.1:6379> OBJECT ENCODING tags
"listpack"
```

Trên Redis 7.0, lệnh `OBJECT ENCODING` ở trên sẽ trả về `"hashtable"`. Khi Set vượt ngưỡng, Redis tự chuyển sang `hashtable`.

**Lợi ích:** hệ thống có rất nhiều Set nhỏ (tag, quyền của user, thành viên nhóm chat) giảm đáng kể lượng RAM sử dụng.

### 3.4 Lệnh `WAITAOF`: đảm bảo độ bền theo yêu cầu

Cú pháp: `WAITAOF numlocal numreplicas timeout`. Lệnh chặn client cho đến khi **các lệnh ghi trước đó của chính client này đã được fsync vào file AOF** trên máy local và/hoặc trên số replica chỉ định (timeout tính bằng mili-giây).

```text
127.0.0.1:6379> SET order:1001 paid
OK
127.0.0.1:6379> WAITAOF 1 0 1000
1) (integer) 1    # số máy local đã fsync (0 hoặc 1)
2) (integer) 0    # số replica đã fsync
```

Liên hệ với câu 2: hệ thống có thể chạy `appendfsync everysec` để giữ hiệu năng, nhưng với thao tác quan trọng (ví dụ ghi nhận thanh toán) thì gọi thêm `WAITAOF` để chắc chắn dữ liệu đã xuống đĩa. Như vậy độ bền được chọn theo từng thao tác, không phải chọn một mức cho toàn bộ hệ thống. Lưu ý: `numlocal > 0` yêu cầu đã bật `appendonly yes`.

### 3.5 `CLIENT NO-TOUCH` và `CLIENT SETINFO`: hỗ trợ vận hành và giám sát

- **`CLIENT NO-TOUCH ON`:** các lệnh từ client này không cập nhật thời gian truy cập (LRU/LFU) của key. Nhờ vậy, các công cụ giám sát hoặc quét dữ liệu không làm sai lệch chính sách loại bỏ key (`allkeys-lru`, `allkeys-lfu`). Ví dụ: một script đọc toàn bộ key để thống kê sẽ không khiến các key ít dùng bị coi là "mới được dùng" và giữ lại trong cache.
- **`CLIENT SETINFO LIB-NAME / LIB-VER`:** thư viện client tự khai báo tên và phiên bản, hiển thị trong `CLIENT LIST`. Khi sự cố xảy ra, quản trị viên biết ngay kết nối đến từ thư viện nào, phiên bản nào (ví dụ phát hiện một service còn dùng thư viện cũ có lỗi). Nhiều thư viện client mới tự động gửi lệnh này khi kết nối.

### 3.6 Xử lý JSON (Redis Stack 7.2, module RedisJSON 2.6)

- Redis Stack cung cấp **kiểu dữ liệu JSON native**: tài liệu JSON được lưu dạng cây, có thể đọc/sửa từng phần qua JSONPath. Nếu lưu JSON trong kiểu String, mỗi lần sửa một field phải đọc cả chuỗi, parse, sửa rồi ghi lại toàn bộ (vừa chậm vừa dễ ghi đè lẫn nhau khi có nhiều client).
- Bản 7.2 bổ sung **`JSON.MERGE`** (gộp theo chuẩn RFC 7396: thêm, sửa, xóa nhiều field trong một lệnh) và **`JSON.MSET`** (ghi nhiều key/path cùng lúc một cách nguyên tử).

```text
127.0.0.1:6379> JSON.SET user:1 $ '{"name":"An","age":30,"skills":["redis"]}'
OK
127.0.0.1:6379> JSON.MERGE user:1 $ '{"age":31,"city":"HCM"}'
OK
127.0.0.1:6379> JSON.GET user:1 $.age
"[31]"
127.0.0.1:6379> JSON.ARRAPPEND user:1 $.skills '"python"'
1) (integer) 2
```

- Kết hợp với module Search để đánh index và truy vấn theo field JSON (lọc, sắp xếp, tìm kiếm full-text, vector search).

Lưu ý: gói `redis` trong kho của Rocky Linux không có JSON. Muốn dùng phải cài Redis Stack (`redis-stack-server`) hoặc nạp module `rejson.so`. Từ **Redis 8.0**, JSON, Search, TimeSeries và Probabilistic đã được tích hợp sẵn vào Redis Open Source.

### 3.7 Lưu ý về giấy phép

Redis 7.2.x là dòng cuối cùng phát hành thuần theo giấy phép BSD-3-Clause. Từ Redis 7.4, Redis chuyển sang giấy phép kép RSALv2/SSPLv1; dự án **Valkey** (thuộc Linux Foundation) được fork từ Redis 7.2.4 để tiếp tục giữ giấy phép BSD. Từ Redis 8.0 có thêm lựa chọn giấy phép AGPLv3. Điều này ảnh hưởng đến chiến lược chọn phiên bản: ví dụ RHEL 10 / Rocky Linux 10 cung cấp Valkey thay cho Redis trong kho chính thức.

### 3.8 Tóm tắt

| Tính năng | Nhóm | Lợi ích chính |
|---|---|---|
| `ZRANK`/`ZREVRANK ... WITHSCORE` | Sorted Set | Lấy thứ hạng và điểm trong 1 lệnh, 1 round-trip |
| Tối ưu chuyển đổi score | Sorted Set | Các lệnh trả về score nhanh hơn |
| Listpack cho Set nhỏ | Bộ nhớ | Giảm RAM với nhiều Set nhỏ |
| `WAITAOF` | Độ bền | Đảm bảo dữ liệu đã fsync cho từng thao tác quan trọng |
| `CLIENT NO-TOUCH`, `CLIENT SETINFO` | Vận hành | Giám sát không làm sai LRU/LFU; biết rõ client nào đang kết nối |
| `JSON.MERGE`, `JSON.MSET` (Redis Stack) | JSON | Cập nhật tài liệu JSON từng phần, nguyên tử |

---

## Câu 4. Tại sao Python là ngôn ngữ nền tảng cho Ansible và scripting API

### 4.1 Python là nền tảng của Ansible

1. **Ansible được viết bằng Python.** Toàn bộ engine của ansible-core (các lệnh CLI, bộ đọc playbook YAML, inventory, bộ thực thi task, các connection plugin) đều là mã Python. Control node bắt buộc phải có Python.
2. **Module chạy bằng Python trên máy đích.** Với máy Linux, mỗi task được Ansible đóng gói thành một file Python (cơ chế **AnsiballZ**: file zip chứa module và các thư viện `module_utils` cần thiết), gửi qua SSH sang máy đích, chạy bằng trình thông dịch Python của máy đích rồi trả kết quả dạng JSON. Vì vậy máy đích chỉ cần SSH và Python, không cần cài agent (xem câu 8). Ngoại lệ: module `raw` và `script` không cần Python (thường dùng `raw` để cài Python cho máy chưa có).
3. **Dựa trên hệ sinh thái thư viện Python:** Jinja2 (template), PyYAML (đọc YAML), cryptography (`ansible-vault`), resolvelib (`ansible-galaxy` giải quyết phụ thuộc collection), paramiko (một kiểu kết nối SSH tùy chọn).
4. **Mở rộng Ansible bằng Python:** custom module và các plugin (filter, lookup, callback, inventory, connection) đều viết bằng Python. Ví dụ một filter plugin đổi byte sang MB:

```python
# filter_plugins/size.py
def to_mb(value):
    return round(int(value) / 1024 / 1024, 2)


class FilterModule:
    def filters(self):
        return {"to_mb": to_mb}
```

Dùng trong playbook: `{{ 268435456 | to_mb }}` cho kết quả `256.0`.

5. **Python có sẵn trên Linux.** Rocky Linux 9 cài sẵn Python 3.9 (dùng bởi `dnf`), và Python 3.11 có trong kho AppStream (`dnf install python3.11`) từ bản 9.2. Gói `ansible-core` 2.14 trong AppStream của Rocky/RHEL 9.2 cũng được build trên Python 3.11. Đây là lý do bộ công nghệ trong đề ghép Python 3.11 với ansible-core 2.14.2.

Lưu ý: không được thay thế `python3` hệ thống (3.9) bằng bản khác vì `dnf` và nhiều công cụ hệ thống phụ thuộc vào nó; Python 3.11 phải được cài song song.

### 4.2 Python cho scripting API

- **Cú pháp rõ ràng, dễ đọc:** script vận hành dễ review và bảo trì; sysadmin và DevOps học nhanh.
- **Thư viện chuẩn phong phú ("batteries included"):** `json`, `subprocess`, `pathlib`, `logging`, `argparse`, `urllib`, `asyncio`, `csv`... Nhiều script không cần cài thêm gói nào.
- **Hệ sinh thái PyPI lớn:** `requests`/`httpx` (HTTP), `redis` (redis-py), `paramiko` (SSH), SDK của các cloud (`boto3`, Azure, GCP), `pydantic` (kiểm tra dữ liệu), `fastapi` (viết API).
- **Xử lý JSON tự nhiên:** JSON chuyển thẳng thành `dict`/`list`, rất hợp với REST API (REST API của Bitrix24 cũng trả về JSON).
- **Đa nền tảng, không cần biên dịch:** viết xong chạy ngay trên Linux, Windows, macOS.
- **Hỗ trợ bất đồng bộ:** `asyncio` (và `TaskGroup` từ 3.11) cho phép gọi hàng trăm API song song.
- **So với Bash:** có xử lý lỗi (`try/except`), cấu trúc dữ liệu, kiểm thử (`pytest`), phù hợp hơn khi script phức tạp. **So với Go/Java:** phát triển nhanh hơn, không cần bước build.

Ví dụ script gọi REST API của Bitrix24 qua inbound webhook để tạo lead:

```python
import requests

WEBHOOK = "https://bitrix.example.local/rest/1/abc123xyz"  # inbound webhook

resp = requests.post(
    f"{WEBHOOK}/crm.lead.add.json",
    json={"fields": {"TITLE": "Lead từ script", "NAME": "An"}},
    timeout=10,
)
resp.raise_for_status()
print("ID lead mới:", resp.json()["result"])
```

### 4.3 Tóm tắt

| Lý do | Với Ansible | Với scripting API |
|---|---|---|
| Ngôn ngữ của chính công cụ | Engine, module, plugin đều là Python | |
| Có sẵn trên Linux | Máy đích chỉ cần SSH + Python | Script chạy ngay, không cần cài runtime |
| Thư viện | Jinja2, PyYAML, cryptography | requests, json, asyncio, SDK cloud |
| Dễ đọc, dễ mở rộng | Viết custom module/plugin nhanh | Viết và bảo trì script nhanh |

---

## Câu 5. Dự án Faster CPython trong Python 3.11

### 5.1 Giới thiệu

**Faster CPython** là dự án tăng tốc trình thông dịch chuẩn CPython, khởi xướng bởi Mark Shannon (với kế hoạch tăng tốc khoảng 5 lần qua nhiều phiên bản), được Microsoft tài trợ từ năm 2021 với sự tham gia của Guido van Rossum. Mục tiêu là tăng tốc mà **không thay đổi ngôn ngữ và giữ tương thích**: người dùng chỉ cần nâng cấp trình thông dịch, không phải sửa code.

Python 3.11 (phát hành 10/2022) là bản đầu tiên mang kết quả của dự án: **trung bình nhanh hơn Python 3.10 khoảng 25%** trên bộ benchmark pyperformance, tùy workload từ 10% đến 60%.

### 5.2 Khởi động nhanh hơn: frozen modules

Khi import một module, Python 3.10 thực hiện:

```text
Đọc file .pyc trong __pycache__ → Unmarshal (giải tuần tự) → Cấp phát code object trên heap → Thực thi
```

Ở Python 3.11, các module lõi cần cho quá trình khởi động (như `abc`, `codecs`, `io`, `os`, `posixpath`, `site`, `stat`) được **"đóng băng" (frozen)**: code object và bytecode của chúng được cấp phát tĩnh ngay trong file thực thi của trình thông dịch. Quy trình rút gọn còn:

```text
Code object cấp phát tĩnh → Thực thi
```

Kết quả: **khởi động trình thông dịch nhanh hơn 10–15%**. Điều này có ý nghĩa với các chương trình chạy ngắn và chạy nhiều lần: script cron, công cụ CLI, và Ansible (mỗi task chạy một module Python trên máy đích, tức khởi động Python một lần cho mỗi task).

Kiểm tra và điều khiển:

```bash
python3.11 -c "import _imp; print(_imp.is_frozen('os'))"   # True: os là module frozen
python3.11 -X frozen_modules=off script.py                  # tắt frozen modules (khi cần debug thư viện chuẩn)
python3.11 -X importtime -c "import os"                      # đo thời gian import từng module
```

### 5.3 Thực thi nhanh hơn: Specializing Adaptive Interpreter (PEP 659)

**Vấn đề:** Python là ngôn ngữ động. Một lệnh bytecode như `BINARY_OP` (phép `+`) phải kiểm tra kiểu dữ liệu ở mỗi lần chạy: int, float, str hay object có `__add__`? Tuy nhiên trong thực tế, tại một vị trí cụ thể trong code, kiểu dữ liệu thường ổn định (ví dụ biến đếm vòng lặp luôn là int).

**Cơ chế:**

1. Khi một hàm được chạy đủ nhiều lần (trở thành code "nóng"), trình thông dịch thay các lệnh tổng quát bằng phiên bản **thích ứng (adaptive)**.
2. Lệnh adaptive quan sát kiểu dữ liệu thực tế và **chuyên biệt hóa (specialize)** thành lệnh nhanh dành riêng cho kiểu đó, kèm bộ đệm (inline cache) lưu ngay trong bytecode.
3. Nếu kiểu dữ liệu thay đổi (giả định sai), lệnh **khử chuyên biệt (de-optimize)** về dạng adaptive và có thể chuyên biệt hóa lại sau.

Một số ví dụ:

| Lệnh tổng quát | Lệnh chuyên biệt | Áp dụng khi |
|---|---|---|
| `BINARY_OP` | `BINARY_OP_ADD_INT`, `BINARY_OP_ADD_FLOAT`, `BINARY_OP_ADD_UNICODE` | Cộng hai int / float / str |
| `LOAD_ATTR` | `LOAD_ATTR_INSTANCE_VALUE`, `LOAD_ATTR_MODULE`, `LOAD_ATTR_SLOT` | Đọc thuộc tính của object, module, `__slots__` |
| `LOAD_GLOBAL` | `LOAD_GLOBAL_MODULE`, `LOAD_GLOBAL_BUILTIN` | Đọc biến global, hàm builtin (`len`, `print`) |
| `BINARY_SUBSCR` | `BINARY_SUBSCR_LIST_INT`, `BINARY_SUBSCR_DICT` | Truy cập `list[i]`, `dict[key]` |
| `CALL` | `CALL_PY_EXACT_ARGS` | Gọi hàm Python với đúng số tham số |

Có thể quan sát bằng module `dis` (tham số `adaptive` mới trong 3.11):

```python
import dis

def cong(a, b):
    return a + b

for _ in range(1000):   # chạy nhiều lần để code trở thành "nóng"
    cong(1, 2)

dis.dis(cong, adaptive=True)
```

Output trên Python 3.11.18: phép `+` đã được chuyên biệt thành `BINARY_OP_ADD_INT`, các lệnh khác cũng được thay bằng bản nhanh (`RESUME_QUICK`, `LOAD_FAST__LOAD_FAST`):

```text
  3           0 RESUME_QUICK             0

  4           2 LOAD_FAST__LOAD_FAST     0 (a)
              4 LOAD_FAST                1 (b)
              6 BINARY_OP_ADD_INT        0 (+)
             10 RETURN_VALUE
```

Đây là bước nền tảng hướng tới JIT: Python 3.11 **chưa có JIT**; JIT thử nghiệm (kiểu copy-and-patch) mới xuất hiện từ Python 3.13.

### 5.4 Các tối ưu khác trong 3.11

- **Frame rẻ hơn và tạo lười (lazy):** dữ liệu frame của hàm được lưu trong vùng nhớ liên tục cấp sẵn cho mỗi luồng và được tinh gọn; đối tượng frame đầy đủ chỉ được tạo khi thật sự cần (debugger, traceback, `sys._getframe()`). Hầu hết lời gọi hàm không còn phải cấp phát bộ nhớ cho frame.
- **Inline lời gọi hàm Python → Python:** khi một hàm Python gọi hàm Python khác, trình thông dịch không gọi đệ quy hàm C nữa mà "nhảy" thẳng vào hàm mới. Lời gọi nhanh hơn, không tốn C stack, đệ quy sâu ít bị tràn stack hơn.
- **Zero-cost exceptions:** khối `try` không còn tốn chi phí khi không có exception (dùng bảng exception table được tính lúc biên dịch thay cho lệnh `SETUP_FINALLY` lúc chạy).
- **Đối tượng gọn hơn:** `__dict__` của object được tạo lười và các dict chia sẻ key với nhau hiệu quả hơn, giảm bộ nhớ.
- **Module `re` nhanh hơn khoảng 10%** nhờ kỹ thuật computed goto.

### 5.5 Ý nghĩa thực tế

- Các ứng dụng thuần Python như Ansible (xử lý template Jinja2, parse YAML, điều phối task) và các script tự động hóa chạy nhanh hơn, tốn ít CPU hơn mà không phải sửa code; mức cải thiện cụ thể tùy workload.
- Hạn chế: ứng dụng chủ yếu chờ I/O (mạng, đĩa) cải thiện ít; phần mã viết bằng C (numpy, thư viện mã hóa) không thay đổi.

---

## Câu 6. Traceback lỗi được cải thiện trong Python 3.11

### 6.1 Vấn đề trước 3.11

Trước 3.11, traceback chỉ cho biết **dòng** gây lỗi. Khi một dòng chứa nhiều phép toán lồng nhau, truy cập thuộc tính liên tiếp hoặc truy cập dict nhiều cấp, ta không biết phần nào gây lỗi.

File `calc.py`:

```python
x, y, z = 10, 2, 0
a, b, c = 1, 2, 3
result = (x / y / z) * (a / b / c)
```

Python 3.10:

```text
Traceback (most recent call last):
  File "/root/calc.py", line 3, in <module>
    result = (x / y / z) * (a / b / c)
ZeroDivisionError: float division by zero
```

Dòng này có 4 phép chia: biến nào bằng 0, `y`, `z`, `b` hay `c`? Phải thêm `print` hoặc chạy debugger để tìm.

### 6.2 Python 3.11: vị trí lỗi chi tiết (PEP 657)

Python 3.11:

```text
Traceback (most recent call last):
  File "/root/calc.py", line 3, in <module>
    result = (x / y / z) * (a / b / c)
              ~~~~~~^~~
ZeroDivisionError: float division by zero
```

Ký hiệu `~` đánh dấu các toán hạng, `^` đánh dấu toán tử gây lỗi: phép chia `(x / y) / z` bị lỗi, tức `z = 0`. Thông báo là `float division by zero` vì `x / y` cho kết quả số thực `5.0`; nếu chia số nguyên cho 0 (ví dụ `10 / 0`) thì thông báo là `division by zero`.

Ví dụ với dict lồng nhau (thường gặp khi xử lý JSON từ API), file `api.py`:

```python
def lay_ten(response):
    return response["data"]["user"]["name"]

data = {"data": {"user": None}}
print(lay_ten(data))
```

Python 3.11:

```text
Traceback (most recent call last):
  File "/root/api.py", line 5, in <module>
    print(lay_ten(data))
          ^^^^^^^^^^^^^
  File "/root/api.py", line 2, in lay_ten
    return response["data"]["user"]["name"]
           ~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^
TypeError: 'NoneType' object is not subscriptable
```

Traceback chỉ rõ thao tác `["name"]` bị lỗi, tức `response["data"]["user"]` là `None`. Cùng file đó, Python 3.10 chỉ cho biết lỗi ở dòng 2, không biết cấp nào là `None`:

```text
Traceback (most recent call last):
  File "/root/api.py", line 5, in <module>
    print(lay_ten(data))
  File "/root/api.py", line 2, in lay_ten
    return response["data"]["user"]["name"]
TypeError: 'NoneType' object is not subscriptable
```

Các output trong câu này được chạy thật trên Python 3.10.22 và 3.11.18 (Docker image `python:3.10-slim`, `python:3.11-slim`).

**Cơ chế:** từ 3.11, mỗi lệnh bytecode lưu thêm vị trí bắt đầu và kết thúc (dòng, cột) của biểu thức tương ứng trong mã nguồn (xem bằng `code.co_positions()`). Khi có lỗi, traceback dùng thông tin này để vẽ các dấu đánh dấu. Có thể tắt để tiết kiệm bộ nhớ và dung lượng file `.pyc` bằng `-X no_debug_ranges` hoặc biến môi trường `PYTHONNODEBUGRANGES=1`.

### 6.3 Các cải tiến liên quan trong 3.11

- **PEP 678: exception notes (`add_note()`).** Thêm thông tin ngữ cảnh vào exception, hiển thị ngay trong traceback:

```python
host = "10.0.0.5"
try:
    raise ConnectionError("Connection refused")
except ConnectionError as e:
    e.add_note(f"Không kết nối được tới Redis {host}:6379")
    raise
```

```text
Traceback (most recent call last):
  File "/root/note.py", line 3, in <module>
    raise ConnectionError("Connection refused")
ConnectionError: Connection refused
Không kết nối được tới Redis 10.0.0.5:6379
```

- **PEP 654: `ExceptionGroup` và `except*`.** Khi nhiều tác vụ cùng lỗi (ví dụ trong `asyncio.TaskGroup`), traceback hiển thị dạng cây gồm tất cả các lỗi, không bị mất lỗi nào.

### 6.4 Lợi ích trong gỡ lỗi

- **Xác định chính xác biểu thức gây lỗi ngay lần đọc đầu tiên**, không cần thêm `print` hay chạy lại với debugger.
- **Rất hữu ích với lỗi trong production:** nhiều lỗi không tái hiện được; traceback ghi trong log (journald, file log, output của Ansible) đã đủ thông tin để sửa.
- **Phù hợp với code xử lý dữ liệu lồng nhau** như JSON từ API (`resp["data"]["items"][0]["id"]`) hoặc chuỗi thuộc tính (`a.b.c.d`), nơi trước đây rất khó biết phần nào là `None`.
- **Rút ngắn thời gian khắc phục sự cố (MTTR).**
- **Tự động áp dụng** cho module `traceback` và `logging.exception()`, không phải sửa code.

---

## Câu 7. Nguyên lý cốt lõi của NodeJS 20, non-blocking I/O, event loop và vai trò push-server trong Bitrix24

### 7.1 Nguyên lý cốt lõi

Node.js là môi trường chạy JavaScript phía server, gồm 3 thành phần chính:

- **V8:** engine JavaScript của Chrome, biên dịch JIT mã JS thành mã máy.
- **libuv:** thư viện C cung cấp event loop, I/O bất đồng bộ và thread pool.
- **Các module lõi:** `http`, `net`, `fs`, `crypto`, `stream`, `worker_threads`...

Mô hình hoạt động: **đơn luồng, hướng sự kiện (event-driven), I/O không chặn (non-blocking)**. Mã JavaScript của ứng dụng chạy trên một luồng chính; mọi thao tác I/O được giao cho hệ điều hành hoặc libuv, kết quả trả về qua callback hoặc Promise.

NodeJS 20 (phát hành 4/2023, LTS tên "Iron" từ 10/2023) có một số điểm mới: V8 11.3, Permission Model thử nghiệm (`--experimental-permission`, giới hạn quyền truy cập file, tiến trình con), test runner `node:test` ổn định, hỗ trợ `--env-file` (từ 20.6), Single Executable Applications (thử nghiệm).

Lưu ý vòng đời: **Node.js 20 đã hết hỗ trợ (EOL) ngày 30/4/2026.** Với hệ thống mới nên dùng Node.js 22 (Maintenance LTS, hỗ trợ đến 4/2027) hoặc Node.js 24 (Active LTS).

### 7.2 Non-blocking I/O

**Mô hình chặn (blocking), ví dụ Apache prefork hoặc PHP-FPM:** mỗi request chiếm một tiến trình/luồng. Khi chờ DB hoặc mạng, luồng đứng yên nhưng vẫn giữ bộ nhớ. 10.000 kết nối đồng thời cần 10.000 luồng/tiến trình, dẫn đến cạn RAM và tốn chi phí chuyển ngữ cảnh.

**Mô hình không chặn (Node.js):** khi gọi I/O, Node đăng ký callback rồi chạy tiếp ngay. Khi I/O hoàn tất, callback được đưa vào hàng đợi và event loop lấy ra thực thi.

```js
const fs = require('node:fs');

// Chặn: luồng chính đứng chờ đọc xong file, không làm được việc khác
const data = fs.readFileSync('/etc/hosts', 'utf8');

// Không chặn: đăng ký callback rồi chạy tiếp ngay
fs.readFile('/etc/hosts', 'utf8', (err, content) => {
  if (err) throw err;
  console.log('Đọc xong:', content.length, 'ký tự');
});
console.log('Dòng này in ra TRƯỚC khi đọc file xong');
```

Ai thực hiện I/O?

- **Socket mạng** (TCP, HTTP, WebSocket): libuv dùng cơ chế bất đồng bộ của hệ điều hành (**epoll** trên Linux), không cần luồng phụ. Một luồng theo dõi được hàng chục nghìn socket.
- **File system, `dns.lookup`, một số hàm `crypto` (pbkdf2, scrypt), `zlib`:** chạy trên **thread pool của libuv** (mặc định 4 luồng, chỉnh bằng biến môi trường `UV_THREADPOOL_SIZE`).

### 7.3 Event loop

Event loop là vòng lặp vô hạn của libuv, mỗi vòng đi qua các pha sau:

```text
   +---------------------------+
+->|          timers           |  setTimeout / setInterval
|  +-------------+-------------+
|  +-------------v-------------+
|  |     pending callbacks     |  callback I/O bị hoãn từ vòng trước
|  +-------------+-------------+
|  +-------------v-------------+
|  |       idle, prepare       |  dùng nội bộ
|  +-------------+-------------+
|  +-------------v-------------+
|  |           poll            |  lấy sự kiện I/O mới (kết nối, dữ liệu đến), chạy callback I/O
|  +-------------+-------------+
|  +-------------v-------------+
|  |           check           |  setImmediate
|  +-------------+-------------+
|  +-------------v-------------+
+--|      close callbacks      |  socket.on('close', ...)
   +---------------------------+
```

Sau mỗi callback, Node chạy hết hàng đợi **microtask**: `process.nextTick` trước, sau đó đến Promise (`.then`, `await`). Khi không còn việc, event loop chờ ở pha poll (luồng ngủ, không tốn CPU).

```js
setTimeout(() => console.log('1. timeout'), 0);
setImmediate(() => console.log('2. immediate'));
Promise.resolve().then(() => console.log('3. promise'));
process.nextTick(() => console.log('4. nextTick'));
console.log('5. sync');

// Kết quả: 5. sync → 4. nextTick → 3. promise → 1. timeout / 2. immediate
// (thứ tự giữa timeout và immediate ở module chính phụ thuộc thời điểm)
```

**Nguyên tắc quan trọng: không được chặn event loop.** Một tác vụ nặng CPU (mã hóa dữ liệu lớn, xử lý ảnh, vòng lặp lớn, `JSON.parse` chuỗi khổng lồ) sẽ làm mọi kết nối khác bị treo. Giải pháp: dùng `worker_threads`, tách sang service khác, hoặc chia nhỏ tác vụ.

Do đó Node.js phù hợp với ứng dụng **nhiều kết nối, nhiều I/O, ít tính toán**: API gateway, chat, WebSocket, push notification, streaming; không phù hợp với tác vụ tính toán nặng.

### 7.4 Vai trò push-server trong Bitrix24

Bitrix24 cần cập nhật thời gian thực cho: tin nhắn chat, thông báo, trạng thái online, "đang gõ...", cập nhật Live Feed, Kanban CRM, tín hiệu cuộc gọi video. Module **Push and Pull** (`pull`) của Bitrix đảm nhận việc này, và phía server cần một push server giữ kết nối lâu dài với client.

Các phiên bản BitrixVM cũ dùng nginx với module nginx-push-stream. Các phiên bản BitrixVM mới chuyển sang **Bitrix Push Server viết bằng Node.js**, dùng Redis để lưu trữ và trao đổi message giữa các tiến trình. Cấu hình mặc định trên BitrixVM gồm:

- **Tiến trình sub** (subscriber, cổng 8010–8015): giữ kết nối WebSocket/long-polling với trình duyệt, ứng dụng mobile và desktop.
- **Tiến trình pub** (publisher, cổng 9010–9011): nhận message từ backend PHP.
- **Redis:** lưu message tạm thời và làm kênh giao tiếp giữa các tiến trình pub/sub.
- **nginx:** reverse proxy, chuyển `/bitrix/subws/` (WebSocket) và `/bitrix/sub/` tới các tiến trình sub, `/bitrix/pub/` tới tiến trình pub. PHP và push server xác thực với nhau bằng khóa bí mật (security key).

Luồng gửi một tin nhắn chat:

```text
 Người dùng A gửi tin nhắn
            |
            v
 +---------------------+                      +----------+
 |  Bitrix24 (PHP)     | --(1) lưu dữ liệu--> |  MySQL   |
 +---------------------+                      +----------+
            |
            | (2) publish qua HTTP tới /bitrix/pub/ (kèm chữ ký bảo mật)
            v
 +---------------------+                      +----------+
 | NodeJS pub (9010-11)| --(3) lưu & phát---> |  Redis   |
 +---------------------+                      +----------+
                                                   |
                                                   | (4) sub nhận message
                                                   v
                                        +----------------------+
                                        | NodeJS sub (8010-15) |
                                        +----------------------+
                                                   |
                                                   | (5) đẩy qua WebSocket
                                                   v
                                        Trình duyệt người dùng B
```

**Vì sao dùng Node.js cho push server:**

- Mỗi người dùng online giữ một kết nối WebSocket, phần lớn thời gian không có dữ liệu. Node.js giữ hàng chục nghìn kết nối như vậy trong một tiến trình với chi phí bộ nhớ nhỏ nhờ event loop.
- PHP-FPM/Apache theo mô hình mỗi request một worker, không phù hợp để giữ kết nối lâu dài. Nếu thay bằng polling (client hỏi server liên tục), tải lên PHP và DB tăng rất mạnh.
- Độ trễ thấp: tin nhắn đến ngay khi được gửi, không phải chờ chu kỳ polling.
- Dễ mở rộng: nhiều tiến trình sub chạy song song, Redis làm cầu nối giữa chúng (xem câu 10).

---

## Câu 8. Vai trò của Ansible-Core 2.14.2 trong triển khai ứng dụng; khái niệm agentless và idempotent

### 8.1 Ansible-Core là gì

- **`ansible-core`** là phần lõi của Ansible, gồm engine, các lệnh CLI (`ansible`, `ansible-playbook`, `ansible-galaxy`, `ansible-vault`, `ansible-doc`, `ansible-inventory`, `ansible-config`, `ansible-pull`, `ansible-console`) và collection `ansible.builtin` (các module cơ bản: `dnf`, `copy`, `template`, `service`, `user`...).
- **Gói `ansible`** (community package) = ansible-core + bộ collection cộng đồng (`community.general`, `ansible.posix`, `community.mysql`...). ansible-core 2.14 tương ứng với gói Ansible 7.
- Các khái niệm chính: **control node** (máy chạy Ansible), **managed node** (máy được quản lý), **inventory** (danh sách máy và nhóm máy), **playbook** (file YAML mô tả trạng thái mong muốn), **module**, **role** (đóng gói tái sử dụng), **handler**, **vault** (mã hóa dữ liệu nhạy cảm).

### 8.2 Vai trò trong triển khai ứng dụng

1. **Quản lý cấu hình:** cài gói, sinh file cấu hình từ template Jinja2 (`redis.conf`, `nginx.conf`), quản lý user, firewall, SELinux, sysctl. Mọi server được cấu hình đồng nhất, tránh tình trạng cấu hình bị lệch dần theo thời gian (configuration drift).
2. **Triển khai ứng dụng:** lấy code (git), cài dependency (`npm`, `pip`), build, cập nhật cấu hình, restart service theo đúng thứ tự.
3. **Điều phối (orchestration):** rolling update (`serial`), rút node khỏi load balancer (`delegate_to`), kiểm tra health check rồi mới đi tiếp, dừng lại khi tỷ lệ lỗi vượt ngưỡng (`max_fail_percentage`).
4. **Cung cấp hạ tầng (provisioning):** tạo máy ảo, cloud instance qua các collection (`amazon.aws`, `community.vmware`...).
5. **Infrastructure as Code:** playbook lưu trong git, có thể review, quản lý phiên bản, dựng lại môi trường dev/staging/production giống nhau, tích hợp vào CI/CD.

Ví dụ playbook triển khai một ứng dụng:

```yaml
- name: Triển khai ứng dụng
  hosts: app_servers
  become: true
  serial: 1                     # cập nhật lần lượt từng máy (rolling update)
  tasks:
    - name: Cài NodeJS
      ansible.builtin.dnf:
        name: nodejs
        state: present

    - name: Sinh file cấu hình từ template
      ansible.builtin.template:
        src: config.json.j2
        dest: /etc/myapp/config.json
        mode: "0640"
      notify: Restart myapp

  handlers:
    - name: Restart myapp
      ansible.builtin.systemd:
        name: myapp
        state: restarted
```

### 8.3 Agentless

**Agentless** nghĩa là Ansible **không cần cài agent hay daemon nào trên máy được quản lý**. Ansible kết nối qua kênh có sẵn: SSH (Linux), WinRM/PSRP (Windows), API hoặc `network_cli` (thiết bị mạng). Yêu cầu với máy đích chỉ là: SSH server, Python (cho đa số module) và một user có quyền (dùng `become` để sudo).

Cơ chế chạy một task trên máy Linux:

1. Control node đóng gói module thành file Python (AnsiballZ).
2. Gửi qua SSH vào thư mục tạm trên máy đích (`~/.ansible/tmp`). Nếu bật `pipelining = True`, module được gửi thẳng qua stdin, không cần ghi file tạm.
3. Chạy module bằng Python của máy đích.
4. Module trả kết quả JSON (`changed`, `failed`, `msg`...) về control node.
5. Xóa file tạm; trên máy đích không còn tiến trình nào của Ansible.

Đây là mô hình **push** (control node chủ động đẩy cấu hình khi cần), khác với mô hình **pull** của Puppet/Chef (agent trên từng máy định kỳ kéo cấu hình từ server trung tâm).

| Tiêu chí | Ansible (agentless) | Puppet/Chef (có agent) |
|---|---|---|
| Chuẩn bị máy đích | Chỉ cần SSH + Python | Cài và cập nhật agent trên mọi máy |
| Cổng mạng | Dùng cổng SSH 22 có sẵn | Mở thêm cổng (ví dụ Puppet 8140) |
| Tài nguyên khi rảnh | Không tốn | Agent chạy nền liên tục |
| Bảo mật | Dùng lại SSH key, sudo hiện có | Thêm hệ thống chứng chỉ riêng cho agent |
| Mô hình | Push, chạy khi cần | Pull, chạy định kỳ |
| Hạn chế | Overhead SSH khi quản lý hàng nghìn máy | Phức tạp lúc khởi tạo |

Có thể giảm overhead SSH bằng `pipelining = True`, SSH ControlPersist (tái sử dụng kết nối, mặc định bật) và tăng `forks` (mặc định 5 máy chạy song song).

### 8.4 Idempotent

**Idempotent** nghĩa là chạy một playbook một lần hay nhiều lần thì trạng thái cuối cùng của hệ thống đều như nhau; các lần chạy sau chỉ thay đổi những gì đang lệch khỏi trạng thái mong muốn.

Tính chất này có được nhờ các module **mô tả trạng thái mong muốn (declarative)** như `state: present`, `state: started`, `enabled: true`. Module tự kiểm tra trạng thái hiện tại và chỉ hành động khi có khác biệt.

```yaml
# Idempotent: module dnf kiểm tra gói đã cài chưa, đã cài thì không làm gì
- name: Cài Redis
  ansible.builtin.dnf:
    name: redis
    state: present

# KHÔNG idempotent: lệnh luôn chạy lại và luôn báo changed
- name: Cài Redis bằng shell
  ansible.builtin.shell: dnf install -y redis
```

Lần chạy đầu task báo `changed`, lần chạy thứ hai báo `ok`:

```text
PLAY RECAP *********************************************************************
web01  : ok=3    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Khi bắt buộc phải dùng `command`/`shell`, cần tự đảm bảo idempotent bằng `creates`, `removes`, `changed_when`:

```yaml
- name: Giải nén mã nguồn Python (bỏ qua nếu thư mục đã tồn tại)
  ansible.builtin.command:
    cmd: tar xzf /tmp/Python-3.11.9.tgz -C /usr/src
    creates: /usr/src/Python-3.11.9

- name: Kiểm tra phiên bản Redis (chỉ đọc, không bao giờ báo changed)
  ansible.builtin.command: redis-server --version
  register: redis_version
  changed_when: false
```

**Handler** cũng hỗ trợ idempotent: handler chỉ chạy khi có task gọi `notify` và task đó thực sự `changed`, nên service chỉ restart khi cấu hình thực sự thay đổi.

**Lợi ích:** chạy lại an toàn (nếu lỗi giữa chừng, chỉ cần sửa và chạy lại playbook); phát hiện cấu hình bị lệch bằng `--check --diff`; có thể chạy định kỳ để giữ hệ thống luôn đúng trạng thái mong muốn.

---

## Câu 9. Vì sao Ansible-Core 2.14.2 là EOL; chiến lược nâng cấp và rủi ro nếu không nâng cấp

### 9.1 Chính sách vòng đời của ansible-core

ansible-core ra một bản lớn (2.x) mới khoảng **6 tháng một lần**. Mỗi bản được bảo trì khoảng **18 tháng**, chia làm 3 giai đoạn:

1. Sửa lỗi chung và lỗi bảo mật.
2. Chỉ sửa lỗi nghiêm trọng và lỗi bảo mật.
3. Chỉ vá lỗi bảo mật.

Sau đó bản này chuyển sang trạng thái **EOL (End-of-Life)**: không còn bất kỳ bản vá nào từ upstream.

### 9.2 Vì sao 2.14.2 là EOL

1. **Cả nhánh 2.14 đã hết hỗ trợ:** ansible-core 2.14 phát hành tháng 11/2022 và hết hỗ trợ upstream từ tháng 5/2024.
2. **Bản 2.14.2 là bản vá rất sớm của nhánh** (phát hành đầu năm 2023), thiếu tất cả các bản vá sau đó (từ 2.14.3 trở đi), trong đó có nhiều lỗ hổng bảo mật, ví dụ:
   - **CVE-2023-5115:** `ansible-galaxy` cài role từ file nén độc hại có thể ghi đè file nằm ngoài thư mục đích (path traversal qua symlink).
   - **CVE-2023-5764:** template injection, dữ liệu bị mất đánh dấu "unsafe" trong quá trình template, có thể dẫn tới thực thi mã khi xử lý dữ liệu không tin cậy.
   - **CVE-2024-0690:** cấu hình `ANSIBLE_NO_LOG` không được tôn trọng trong một số trường hợp (ví dụ biến lặp trong loop), làm lộ thông tin nhạy cảm vào log.
   - **CVE-2024-11079:** vượt qua cơ chế bảo vệ nội dung "unsafe" qua `hostvars`, có thể dẫn tới thực thi mã tùy ý. Lỗ hổng này công bố sau khi nhánh 2.14 đã EOL nên upstream không vá cho 2.14.
3. **Giới hạn tương thích Python:** control node của ansible-core 2.14 chỉ hỗ trợ Python 3.9–3.11, không chạy trên Python 3.12+ (Python mặc định của Rocky Linux 10).
4. **Collection mới yêu cầu ansible-core mới hơn:** các phiên bản mới của `community.general` và nhiều collection khác đã bỏ hỗ trợ ansible-core 2.14, nên hệ thống bị kẹt ở collection cũ.

Lưu ý về gói của hệ điều hành: Rocky Linux 9 (bản rebuild của RHEL 9) cung cấp `ansible-core` trong AppStream. Red Hat có backport một số bản vá cho gói này, nhưng tuyên bố **phạm vi hỗ trợ hạn chế** (chủ yếu để chạy RHEL System Roles), không dành cho việc dùng tùy ý các collection cộng đồng. Vì vậy không nên coi gói hệ thống là giải pháp lâu dài cho hệ thống tự động hóa chính.

### 9.3 Rủi ro nếu không nâng cấp

| Rủi ro | Mô tả |
|---|---|
| Bảo mật | Lỗ hổng đã biết không được vá (lộ secret, thực thi mã, path traversal). Control node giữ SSH key và mật khẩu vault của toàn bộ hạ tầng: bị chiếm control node đồng nghĩa với mất quyền kiểm soát toàn bộ hệ thống. |
| Tương thích | Không chạy được trên Python và hệ điều hành mới (Rocky Linux 10 dùng Python 3.12), không dùng được module/collection mới, kéo theo việc không nâng cấp được hệ điều hành. |
| Vận hành | Lỗi gặp phải không được sửa, không còn hỗ trợ từ cộng đồng; tài liệu và ví dụ mới không áp dụng được. |
| Tuân thủ | Các tiêu chuẩn như ISO 27001, PCI DSS yêu cầu phần mềm còn được hỗ trợ và vá lỗi; dùng phần mềm EOL dễ không đạt khi audit. |
| Nợ kỹ thuật | Để càng lâu, khoảng cách phiên bản càng lớn (từ 2.14 lên các bản mới có nhiều thay đổi phá vỡ tương thích), lần nâng cấp sau càng tốn công và rủi ro. |

### 9.4 Khuyến nghị chiến lược nâng cấp

**Bước 1. Đánh giá hiện trạng:**

```bash
ansible --version                  # phiên bản ansible-core và Python của control node
ansible-galaxy collection list     # các collection đang dùng
ansible all -m ansible.builtin.setup -a "filter=ansible_python_version"   # Python trên các managed node
```

Liệt kê toàn bộ playbook, role và các máy chạy hệ điều hành cũ (CentOS 7 dùng Python 2.7, RHEL 8 dùng platform-python 3.6).

**Bước 2. Kiểm tra Python của control node, rồi chọn phiên bản đích.** Bản đích phải **còn được hỗ trợ** và hợp với Python ở cả control node lẫn managed node. Các bản mới nhất (tháng 11/2026, theo endoflife.date và bảng hỗ trợ của Ansible):

| ansible-core | Hết hỗ trợ | Python control node | Python managed node |
|---|---|---|---|
| 2.18 | 31/05/2026 (đã EOL) | 3.11–3.13 | 3.8–3.13 |
| 2.19 | 30/11/2026 (sắp EOL) | 3.11–3.13 | 3.8–3.13 |
| 2.20 | 31/05/2027 | 3.12–3.14 | 3.9–3.14 |
| 2.21 | 30/11/2027 | 3.12–3.14 | 3.9–3.14 |
| 2.22 (ra ngày 02/11/2026) | 31/05/2028 | 3.13–3.15 | 3.10–3.15 |

Áp dụng cho Rocky Linux 9:

- Nếu control node chỉ có Python 3.11 (đúng bối cảnh của đề) thì bản mới nhất cài được là 2.19, mà bản này sắp EOL. Vì vậy phải **cài thêm Python 3.12 song song** cho control node.
- **Khuyến nghị: ansible-core 2.21 chạy trên Python 3.12.** Managed node Rocky Linux 9 vẫn dùng Python 3.9 mặc định của hệ thống, không phải cài thêm gì.
- Bản 2.22 vừa phát hành, cần Python ≥ 3.13 trên control node (Rocky Linux 9 có `python3.14` trong AppStream, không có `python3.13`) và **≥ 3.10 trên managed node**. Khi đó mọi máy Rocky Linux 9 đều phải cài thêm Python mới và khai báo `ansible_python_interpreter`. Nên chờ vài bản vá rồi mới cân nhắc.
- Từ **ansible-core 2.17**, managed node không còn hỗ trợ Python 2.7 và 3.6. Máy CentOS 7 / RHEL 8 phải cài Python mới hơn (ví dụ `python3.9`, `python3.11`) và khai báo `ansible_python_interpreter`.
- **ansible-core 2.19** thay đổi lớn engine template (Data Tagging): điều kiện `when` phải trả về giá trị boolean, chuyển đổi kiểu chặt chẽ hơn. Đi từ 2.14 lên 2.21 sẽ gặp thay đổi này, nên nhiều playbook cũ cần sửa.
- Luôn kiểm tra lại bảng hỗ trợ chính thức trước khi chọn, vì cứ khoảng 6 tháng lại có bản mới và một bản cũ hết hỗ trợ: <https://docs.ansible.com/ansible/latest/reference_appendices/release_and_maintenance.html>

**Bước 3. Cài Python 3.12 và ansible-core mới trong virtualenv, ghim phiên bản** (không động vào `python3` 3.9 và gói `ansible-core` của hệ thống, bản cũ vẫn còn để rollback):

```bash
dnf list python3.12                            # kiểm tra AppStream có Python 3.12
sudo dnf install -y python3.12 python3.12-pip  # cài song song với python3 (3.9) của hệ thống
python3.12 -m venv /opt/ansible-core-2.21
/opt/ansible-core-2.21/bin/pip install --upgrade pip
/opt/ansible-core-2.21/bin/pip install "ansible-core>=2.21,<2.22"
/opt/ansible-core-2.21/bin/ansible --version
/opt/ansible-core-2.21/bin/ansible-galaxy collection install -r collections/requirements.yml
```

Các lệnh trên đã chạy thử trên Rocky Linux 9.8 (container): AppStream có `python3.12` 3.12.15, cài được `ansible-core 2.21.6`, và module chạy bình thường trên managed node dùng Python 3.9 của hệ thống.

```yaml
# collections/requirements.yml: ghim phiên bản collection tương thích ansible-core 2.21
collections:
  - name: community.general
    version: ">=13.0.0,<14.0.0"
  - name: ansible.posix
    version: ">=2.2.0,<3.0.0"
```

Với môi trường lớn có thể dùng **Execution Environment** (image container đóng gói sẵn ansible-core, collection và thư viện Python, build bằng `ansible-builder`, chạy bằng `ansible-navigator`) để mọi người và CI dùng cùng một môi trường.

**Bước 4. Sửa tương thích theo Porting Guide của từng bản** (2.15 → 2.16 → ... → bản đích). Ví dụ: `include` đã bị loại bỏ từ 2.16 (thay bằng `include_tasks`/`import_tasks`), nên dùng tên đầy đủ FQCN (`ansible.builtin.copy` thay cho `copy`). Kiểm tra bằng:

```bash
ansible-lint playbooks/
ansible-playbook site.yml --syntax-check
ansible-playbook -i inventories/staging site.yml --check --diff
```

Viết test cho role bằng Molecule nếu có thể.

**Bước 5. Triển khai dần:** staging → một nhóm nhỏ máy production (canary) → toàn bộ production. Giữ bản cũ (gói `ansible-core` 2.14 của hệ thống) để rollback nhanh: chỉ cần đổi `PATH`, không phải gỡ cài đặt gì.

**Bước 6. Duy trì:** lên lịch nâng cấp định kỳ 6–12 tháng, theo dõi security advisory, đưa `ansible-lint` và test vào CI, không để tụt quá 1–2 bản lớn so với bản mới nhất.

---

## Câu 10. So sánh khả năng mở rộng ngang và vai trò hỗ trợ của Redis, NodeJS, Python và Ansible

### 10.1 Khái niệm

- **Mở rộng dọc (vertical scaling, scale up):** tăng CPU/RAM cho một máy. Đơn giản nhưng bị giới hạn bởi phần cứng, chi phí tăng nhanh, máy đó vẫn là điểm lỗi đơn (SPOF) và thường phải dừng dịch vụ khi nâng cấp.
- **Mở rộng ngang (horizontal scaling, scale out):** thêm máy/instance chạy song song phía sau load balancer. Gần như không giới hạn và tăng khả năng chịu lỗi (một máy hỏng thì các máy khác vẫn phục vụ).

Điều kiện để mở rộng ngang được:

1. Tầng ứng dụng **stateless**: không lưu trạng thái (session, cache) trong bộ nhớ riêng của từng server.
2. Trạng thái dùng chung được đưa ra ngoài: database, Redis.
3. Có load balancer phân phối request.
4. Triển khai và cấu hình nhiều máy một cách tự động, đồng nhất.

### 10.2 Redis

**Vai trò hỗ trợ mở rộng ngang:**

- **Nơi lưu trạng thái dùng chung:** session, cache, khóa phân tán, rate limit, bộ đếm. Nhờ vậy các app server trở thành stateless, bất kỳ server nào cũng xử lý được bất kỳ request nào; thêm server chỉ cần trỏ về cùng Redis.
- **Hàng đợi công việc (List, Stream):** nhiều worker cùng lấy job từ một hàng đợi; thêm worker là tăng năng lực xử lý.
- **Pub/Sub làm kênh thông điệp** giữa các instance (ví dụ giữa các tiến trình push-server NodeJS).

**Bản thân Redis mở rộng:**

- **Replication (master–replica):** mở rộng khả năng đọc; kết hợp **Sentinel** để tự động chuyển đổi dự phòng (failover) khi master hỏng.
- **Redis Cluster:** chia keyspace thành **16384 hash slot** phân bố trên nhiều master, mở rộng cả khả năng ghi lẫn dung lượng bộ nhớ; có thể thêm node và di chuyển slot (resharding) khi đang chạy.
- **Giới hạn:** lệnh thao tác nhiều key phải có các key cùng slot (dùng hash tag, ví dụ `{user:1}:cart` và `{user:1}:profile`); mỗi instance thực thi lệnh đơn luồng nên phải mở rộng bằng cách thêm shard; Pub/Sub thông thường phát message tới mọi node trong cluster, nên dùng Sharded Pub/Sub (`SPUBLISH`/`SSUBSCRIBE`, từ Redis 7.0) để giảm tải.

### 10.3 NodeJS

- Một tiến trình Node chỉ dùng **một nhân CPU** để chạy mã JavaScript. Trên một máy, mở rộng bằng cách chạy nhiều tiến trình (module `cluster`, PM2 hoặc nhiều systemd unit), như push-server Bitrix chạy nhiều tiến trình sub/pub.
- Trên nhiều máy: thêm instance phía sau load balancer (nginx, HAProxy).
- **Thách thức với kết nối thời gian thực:** WebSocket là kết nối có trạng thái; người gửi và người nhận có thể đang kết nối tới hai instance khác nhau. Cần một kênh chung để chuyển message giữa các instance, thường là **Redis Pub/Sub** (ví dụ Socket.IO Redis adapter; push-server Bitrix dùng Redis). Kết nối long-polling cần thêm sticky session ở load balancer.
- **Ưu điểm:** mỗi instance giữ được rất nhiều kết nối đồng thời nhờ event loop, nên số máy cần thêm ít.

### 10.4 Python

- **GIL (Global Interpreter Lock)** trong CPython 3.11: tại một thời điểm chỉ một luồng được chạy bytecode Python, nên đa luồng không tận dụng được nhiều nhân CPU cho tác vụ tính toán.
- **Mở rộng bằng tiến trình:** `multiprocessing`, chạy nhiều worker (Gunicorn, Uvicorn), hoặc Celery/RQ worker lấy job từ Redis. Thêm worker hoặc thêm máy là tăng năng lực xử lý, đây là cách mở rộng ngang tự nhiên của Python.
- **Tác vụ I/O** (gọi API, truy vấn DB): `asyncio`/`TaskGroup` xử lý hàng nghìn tác vụ đồng thời trên một luồng.
- Python còn là nền tảng của Ansible, công cụ thực hiện việc mở rộng (mục 10.5).
- Ghi chú: từ Python 3.13 có bản build thử nghiệm không có GIL (free-threaded, PEP 703).

### 10.5 Ansible

Ansible không phục vụ lưu lượng người dùng, mà là **công cụ thực hiện việc mở rộng ngang**:

- **Dựng node mới giống hệt node cũ** từ cùng role/playbook, tránh lệch cấu hình. Thêm một node chỉ cần thêm một dòng vào inventory và chạy playbook.
- **Inventory động** (plugin cloud như `amazon.aws.aws_ec2`) tự phát hiện máy mới.
- **Rolling update không gián đoạn dịch vụ:** `serial`, `max_fail_percentage`, `delegate_to` để rút node khỏi load balancer trước khi cập nhật.
- **Cập nhật cấu hình load balancer** tự động: sinh danh sách upstream của nginx từ nhóm máy trong inventory.

```yaml
- name: Rolling update ứng dụng
  hosts: app_servers
  serial: "25%"                 # mỗi đợt cập nhật 25% số máy
  max_fail_percentage: 10       # dừng nếu quá 10% số máy lỗi
  pre_tasks:
    - name: Rút node khỏi load balancer (script ví dụ)
      ansible.builtin.command: /usr/local/bin/lb-disable {{ inventory_hostname }}
      delegate_to: lb01
  roles:
    - app
  post_tasks:
    - name: Đưa node trở lại load balancer
      ansible.builtin.command: /usr/local/bin/lb-enable {{ inventory_hostname }}
      delegate_to: lb01
```

Bản thân Ansible mở rộng bằng cách tăng `forks`, dùng `strategy: free`, `async`, `pipelining`; ở quy mô lớn dùng AWX hoặc Ansible Automation Platform với nhiều execution node.

### 10.6 Bảng so sánh

| Thành phần | Vai trò trong mở rộng ngang | Cách tự mở rộng | Giới hạn / lưu ý |
|---|---|---|---|
| Redis | Lưu trạng thái dùng chung (session, cache, lock), hàng đợi, kênh Pub/Sub; giúp tầng ứng dụng stateless | Replica (đọc), Sentinel (HA), Cluster 16384 slot (ghi + dung lượng) | Lệnh nhiều key phải cùng slot; mỗi instance đơn luồng; dữ liệu giới hạn bởi RAM |
| NodeJS | Tầng kết nối thời gian thực (WebSocket, push), API nhiều I/O | Nhiều tiến trình/máy (`cluster`, PM2) sau load balancer | Cần Redis để đồng bộ message giữa các instance; sticky session cho long-polling; tránh tác vụ nặng CPU |
| Python | Worker xử lý nền, script API, nền tảng của Ansible | Nhiều tiến trình/worker (Gunicorn, Celery) lấy job từ Redis; `asyncio` cho I/O | GIL giới hạn đa luồng với tác vụ tính toán |
| Ansible | Công cụ thực hiện mở rộng: dựng node, cập nhật load balancer, rolling update | `forks`, `strategy: free`, `async`; AWX/AAP | Overhead SSH ở quy mô rất lớn; không phục vụ request |

### 10.7 Kiến trúc tổng hợp

```text
                    +-----------------------+
   Người dùng ----> | Load Balancer (nginx) |
                    +-----------+-----------+
                                |
             +------------------+------------------+
             |                  |                  |
             v                  v                  v
      +-------------+    +-------------+    +-------------+
      | App node #1 |    | App node #2 |    | App node #N |
      +------+------+    +------+------+    +------+------+
             |                  |                  |
             +------------------+------------------+
                                |
                     +----------+----------+
                     |                     |
                     v                     v
          +--------------------+   +---------------+
          | Redis (Sentinel/   |   | Database      |
          | Cluster): session, |   | (dữ liệu lâu  |
          | cache, queue, P/S  |   | dài)          |
          +--------------------+   +---------------+

   App node = PHP/Python (stateless) + NodeJS push-server
   Ansible control node --SSH--> tất cả các node: dựng node mới, rolling update
```

**Kết luận:** bốn công nghệ bổ trợ cho nhau. **Redis** là nơi giữ trạng thái và kênh thông điệp dùng chung, điều kiện để các tầng khác mở rộng ngang. **NodeJS** mở rộng tầng kết nối thời gian thực bằng nhiều tiến trình/instance và dựa vào Redis để đồng bộ. **Python** mở rộng bằng nhiều tiến trình worker lấy việc từ hàng đợi Redis. **Ansible** tự động hóa việc thêm node, cấu hình và cập nhật, giúp mở rộng nhanh, đồng nhất và lặp lại được.
