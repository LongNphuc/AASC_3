"""Bài 6 (Phần 3): ZeroDivisionError nằm trong biểu thức lồng nhau, để so sánh traceback giữa Python 3.9 và 3.11.

Doanh thu trung bình mỗi ngày của một tháng = (tổng doanh thu / số đơn vị) / số ngày bán hàng * hệ số thuế.
Dữ liệu tháng 3 có số ngày bán hàng bằng 0, nên một trong ba phép chia trên cùng một dòng sẽ lỗi.
Python 3.9 chỉ báo số dòng; Python 3.11 đánh dấu đúng phép chia gây lỗi (PEP 657).
"""

BAO_CAO = {
    "thang": "T3",
    "doanh_thu": [120_000_000, 95_000_000, 143_000_000],
    "don_vi": 3,
    "so_ngay_ban": {"T1": 26, "T2": 24, "T3": 0},
    "thue": 10,
}


def doanh_thu_trung_binh_ngay(bc):
    return round((sum(bc["doanh_thu"]) / bc["don_vi"]) / bc["so_ngay_ban"][bc["thang"]] * (1 + bc["thue"] / 100), 2)


def lap_bao_cao(bc):
    return {"thang": bc["thang"], "trung_binh_ngay": doanh_thu_trung_binh_ngay(bc)}


def main():
    try:
        print(lap_bao_cao(BAO_CAO))
    except ZeroDivisionError as e:
        if hasattr(e, "add_note"):  # PEP 678, có từ Python 3.11
            e.add_note(f"Gợi ý: kiểm tra so_ngay_ban của tháng {BAO_CAO['thang']} trong dữ liệu đầu vào")
        raise


if __name__ == "__main__":
    main()
