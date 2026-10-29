# ระบบจองและเช่าพื้นที่ตลาดนัด (Market Stall Rental & Reservation)

โครงงานวิชา Database Systems ภาคการศึกษา 2569 หัวข้อที่ 27

ระบบสำหรับเจ้าหน้าที่ตลาดใช้จัดการแผงค้า จองแผงตามรอบวันตลาด บันทึกการรับชำระค่าเช่าและเงินมัดจำ ยกเลิกสัญญาพร้อมคืนมัดจำ บันทึกค่าน้ำไฟและค่าปรับ และดูรายงานรายได้กับอัตราการเช่าแยกตามโซน

## สมาชิก

| รหัสนิสิต | ชื่อ | บทบาท |
|---|---|---|
| 67366925 | นายอัษณัช แก้วเผือก | Data Architect & DBA |
| 67366062 | นายสิทธิพล แซ่ว้า | Backend & DB Logic Engineer |
| 67365010 | นายรวิดนัย ด้วงโสน | Full-stack & Frontend Developer |

## เทคโนโลยี

- **ฐานข้อมูล:** Microsoft SQL Server 2019 Express (T-SQL) ชื่อฐานข้อมูล `market_db`
- **เว็บ:** ASP.NET (.NET Framework 4.7.2), C#, HTML + JavaScript และ Bootstrap 5
- **การเชื่อมต่อ:** หน้าเว็บเรียก handler (`.ashx`) ด้วย `fetch` แล้ว handler ติดต่อฐานข้อมูลผ่าน ADO.NET โดยตรง (ใช้ SQL แบบ parameter และเรียก Stored Procedure) ไม่ผ่าน ORM

## สิ่งที่ต้องติดตั้ง

- **Visual Studio 2026** (ทดสอบกับ Community 18.10.3) หรือรุ่นที่เปิดไฟล์ `.slnx` ได้ พร้อม workload "ASP.NET and web development" และ .NET Framework 4.7.2 targeting pack (Visual Studio 2019 เปิดไฟล์ `.slnx` ไม่ได้)
- **SQL Server 2019 Express** โดยใช้ชื่อ instance `SQLEXPRESS`
- **SQL Server Management Studio (SSMS)** ใช้รันไฟล์ SQL และตรวจข้อมูล (ทดสอบกับรุ่น 22.7.2)
- **อินเทอร์เน็ตตอนใช้งานเว็บ** เพราะหน้าเว็บโหลด Bootstrap จาก CDN ถ้าไม่มีเน็ต หน้าจะไม่มีสไตล์และหน้าต่างป๊อปอัปจะไม่ทำงาน

## โครงสร้างโฟลเดอร์

```
.
├── README.md
├── Market_reserve.slnx        ไฟล์ Solution (เปิดด้วย Visual Studio)
├── Market_reserve/            โค้ดเว็บ: หน้า .html, handler .ashx, Web.config
└── database/
    ├── schema.sql             สร้างฐานข้อมูล ตาราง constraint index
    ├── data.sql               ข้อมูลจำลอง
    ├── logic.sql              Stored Procedure, Trigger, View
    ├── queries.sql            Complex Query 10 ข้อ
    └── generate_mock_data.py  สคริปต์สร้างข้อมูลจำลอง (ไม่จำเป็นต้องรัน)
```

## ขั้นที่ 1: สร้างฐานข้อมูล (ใช้ SSMS)

### 1.1 เชื่อมต่อ SQL Server

1. เปิด SQL Server Management Studio (SSMS) จะมีหน้าต่าง **Connect to Server** ตั้งค่าดังนี้
   - **Server type:** Database Engine
   - **Server name:** `.\SQLEXPRESS` (เครื่องหมายจุดหมายถึงเครื่องนี้ ใช้ได้ทุกเครื่อง) หรือใช้ชื่อเครื่อง เช่น `LAPTOP-12345QS8E\SQLEXPRESS`
   - **Authentication:** Windows Authentication
   - ถ้ามีข้อความ error เรื่อง certificate (`The certificate chain was issued by an authority that is not trusted`) ให้ตั้ง **Encryption** เป็น **Optional** หรือติ๊ก **Trust server certificate** แล้วกด **Connect** อีกครั้ง
2. กด **Connect**

### 1.2 เปิดและรันไฟล์ SQL ตามลำดับ

1. เมนู **File > Open > File...** เปิดโฟลเดอร์ `database` แล้วเลือกไฟล์ทั้ง 4 ไฟล์ (กด Ctrl ค้างแล้วคลิกทีละไฟล์) กด **Open** จะได้ 4 แท็บ
2. รัน **ตามลำดับนี้ (ห้ามสลับ)** โดยคลิกที่แท็บของไฟล์นั้น แล้วกด **Execute** (ปุ่มสามเหลี่ยมสีเขียว หรือ F5)

| ลำดับ | ไฟล์ | ผลที่ควรเห็น |
|---|---|---|
| 1 | `schema.sql` | ตารางสรุปรายชื่อ 9 ตาราง และข้อความ `schema.sql finished: 9 tables created.` ในแท็บ Messages |
| 2 | `data.sql` | ใช้เวลาครู่หนึ่ง จบโดยไม่มีข้อความ error สีแดง |
| 3 | `logic.sql` | `Commands completed successfully` |
| 4 | `queries.sql` | ผลลัพธ์ Query 10 ข้อ (ไม่จำเป็นต่อการรันเว็บ ใช้ดูรายงาน) |

ข้อควรระวัง

- **อย่าไฮไลต์ (เลือก) ข้อความในแท็บก่อนกด Execute** เพราะ SSMS จะรันเฉพาะส่วนที่เลือก ให้คลิกวางเคอร์เซอร์เฉยๆ แล้วกด Execute
- `schema.sql` สร้างฐานข้อมูล `market_db` ให้เอง และ **รันซ้ำได้** (ลบตารางทั้ง 9 แล้วสร้างใหม่ ข้อมูลเดิมจะหาย จึงต้องรัน `data.sql` กับ `logic.sql` ตามหลังทุกครั้ง)
- `data.sql`, `logic.sql`, `queries.sql` มี `USE market_db;` บนสุดแล้ว

### 1.3 ตรวจว่าข้อมูลพร้อมใช้งาน

เปิดแท็บใหม่ (**New Query**) แล้วรัน

```sql
USE market_db;
SELECT COUNT(*) AS lease_count FROM leases;       -- ควรได้ 575
SELECT TOP 3 zone_name FROM stall_zones;          -- ภาษาไทยต้องอ่านออก ไม่เป็น ???
SELECT * FROM vw_market_zone_revenue;             -- ควรเห็น 5 โซน
```

ข้อมูลตัวอย่าง: 5 โซน, 50 แผง, 40 ผู้ค้า, 20 พนักงาน, 51 วันตลาด, 575 สัญญา

### ออบเจ็กต์ใน `logic.sql`

| ประเภท | ชื่อ | หน้าที่ |
|---|---|---|
| Trigger | `trg_prevent_double_stall_booking` | กันจองแผงเดียวกันซ้ำในวันตลาดเดียวกัน |
| Stored Procedure | `sp_reserve_stall` | จองแผง บันทึกสัญญาและรับชำระค่าเช่า+เงินมัดจำใน Transaction เดียว (ACID) |
| Stored Procedure | `sp_record_utility` | บันทึกค่าน้ำ/ค่าไฟ โดยระบบกำหนดราคาต่อหน่วยให้เอง (น้ำ 18, ไฟฟ้า 8 บาท) |
| Stored Procedure | `sp_cancel_lease` | ยกเลิกสัญญาและบันทึกคืนเงินมัดจำใน Transaction เดียว |
| View | `vw_market_zone_revenue` | สรุปอัตราการเช่าและรายได้ค่าเช่า/ค่าน้ำไฟแยกตามโซน |

## ขั้นที่ 2: รันเว็บ

### 2.1 ตรวจการตั้งค่าการเชื่อมต่อ

ตั้งไว้แล้วใน `Market_reserve/Web.config` (ชื่อ `market_db`)

```
Data Source=.\SQLEXPRESS;Initial Catalog=market_db;Integrated Security=SSPI;
```

ใช้ Windows Authentication จึงไม่มีรหัสผ่านในโค้ด บัญชี Windows ที่เปิด Visual Studio ต้องมีสิทธิ์เข้า SQL Server ถ้า instance ไม่ได้ชื่อ `SQLEXPRESS` ให้แก้ `Data Source` ให้ตรงกับเครื่อง

### 2.2 เปิดและรัน

1. เปิดไฟล์ `Market_reserve.slnx` ด้วย Visual Studio
2. กด **F5** (รันด้วย IIS Express) ครั้งแรกอาจมีหน้าต่างถามให้เชื่อถือใบรับรอง SSL ของ IIS Express ให้ตอบ **Yes**
3. เบราว์เซอร์จะเปิดที่ `https://localhost:<พอร์ต>/` (เลขพอร์ตต่างกันได้ในแต่ละเครื่อง) เปิดหน้าแรกที่ `/main_menu.html`
   - ถ้าเบราว์เซอร์ขึ้นหน้า error หรือรายชื่อไฟล์แทนหน้าแรก ให้พิมพ์ `/main_menu.html` ต่อท้ายที่อยู่ หรือคลิกขวาที่ `main_menu.html` ใน Solution Explorer แล้วเลือก **Set As Start Page** จากนั้นกด F5 ใหม่

## หน้าเว็บและฟีเจอร์

| หน้า | ไฟล์ | ใช้ทำอะไร |
|---|---|---|
| หน้าแรก | `main_menu.html` | รายได้และอัตราการเช่าแยกตามโซน (อ่านจาก `vw_market_zone_revenue`) |
| แผงค้า / จอง | `stalls2.html` | ดูสถานะแผงตามวันตลาด และจองแผง (เรียก `sp_reserve_stall`) |
| จัดการแผงค้า / วันตลาด | `manage2.html` (เปิดจากปุ่มในหน้าแผงค้า) | เพิ่ม แก้ไข ลบแผง สลับปิดซ่อมบำรุง และเพิ่ม เปิด/ปิดรับจอง ลบวันตลาด |
| สัญญา | `leases2.html` | ดูและค้นหาสัญญา ยกเลิกสัญญาและคืนมัดจำ (เรียก `sp_cancel_lease`) |
| ผู้ค้า | `merchants2.html` | ค้นหา เพิ่ม แก้ไข ลบผู้ค้า |
| ค่าปรับ | `fines2.html` | ดูรายการและบันทึกค่าปรับ |
| ค่าน้ำไฟ | `utilities2.html` | ดูรายการและบันทึกค่าน้ำไฟ (เรียก `sp_record_utility`) |

ค่าปรับและค่าน้ำไฟเป็นบันทึกประวัติ บันทึกแล้วยกเลิกหรือแก้ไขไม่ได้ ส่วนข้อมูลโซนและพนักงานเป็นข้อมูลตั้งต้น ไม่มีหน้าจัดการ

### กฎที่ระบบบังคับ

- จองได้เฉพาะวันตลาดที่เปิดรับจองและยังไม่ผ่านมา (จองวันนี้ได้) และเฉพาะแผงที่ไม่ปิดซ่อม
- ยอดชำระต้องเท่ากับค่าเช่า + เงินมัดจำ **พอดี** ไม่เช่นนั้นการจองถูกยกเลิกทั้งหมด
- ค่าเช่าและมัดจำถูกเก็บเป็นราคา Snapshot ณ วันทำสัญญา
- แผงหรือวันตลาดที่มีสัญญาแล้วลบไม่ได้ แผงที่มีสัญญาแล้วเปลี่ยนโซนไม่ได้ วันตลาดที่ผ่านมาแล้วแก้ไขหรือลบไม่ได้
- ผู้ค้าที่มีสัญญาแล้วลบไม่ได้ เบอร์โทรห้ามซ้ำ

## ทดลองจองแผง

1. เปิดหน้า **แผงค้า** เลือกวันตลาด `2026-11-06`
2. กด **จอง** ที่แผง `F09` (โซนอาหารปรุงสุก ค่าเช่า 350 + มัดจำ 20% = 70)
3. เลือกผู้ค้าและพนักงานคนใดก็ได้ กรอกยอดชำระ `420` แล้วยืนยัน ควรขึ้นว่าจองสำเร็จ และแผงเปลี่ยนเป็น "ติดจอง"

ทดลองกรณีไม่ผ่าน

- แผง `F10`, `S10`, `G10` เป็นแผงปิดซ่อมบำรุง จองไม่ได้
- เปิดหน้าแผงค้า 2 แท็บ จองแผงเดียวกันในแท็บแรก แล้วจองซ้ำในแท็บที่สอง ระบบจะแจ้งว่าแผงถูกจองไปแล้ว (Trigger)

> วันตลาดที่จองได้ในข้อมูลตัวอย่างคือ 6-8 พ.ย. และ 4-6 ธ.ค. 2569 เมื่อเลยวันเหล่านี้ไปแล้วจะจองไม่ได้ ให้เพิ่มวันตลาดใหม่ที่หน้า **จัดการแผงค้า / วันตลาด** (แท็บวันตลาด)

## แก้ปัญหาที่พบบ่อย

| อาการ | วิธีแก้ |
|---|---|
| ภาษาไทยใน SSMS เป็น `???` หรือตัวอักษรแปลกๆ หลังรัน `data.sql` | SSMS อ่านไฟล์ผิดการเข้ารหัส ข้อมูลที่ใส่ไปจะเสีย ให้ปิดแท็บ แล้วเปิดไฟล์ใหม่ด้วยการเข้ารหัส UTF-8 (ใน File > Open > File... กดลูกศรข้างปุ่ม Open เลือก **Open With...** แล้วเลือกตัวแก้ไขที่ให้เลือก Encoding เป็น UTF-8 / Codepage 65001) จากนั้นรัน `schema.sql` → `data.sql` → `logic.sql` ใหม่ตามลำดับ |
| ภาษาไทยในหน้าเว็บเป็นตัวเพี้ยน | ตรวจว่า `Web.config` มี `<globalization fileEncoding="utf-8" requestEncoding="utf-8" responseEncoding="utf-8" />` ใน `<system.web>` |
| SSMS เชื่อมต่อไม่ได้ (`A network-related or instance-specific error`) | ตรวจชื่อ Server name ให้มี `\SQLEXPRESS` ต่อท้าย และตรวจว่า service ของ SQL Server ทำงานอยู่ (เปิดโปรแกรม **Services** ดูรายการ `SQL Server (SQLEXPRESS)` ว่าเป็น Running หรือเปิด Command Prompt แบบ Administrator แล้วสั่ง `net start "MSSQL$SQLEXPRESS"`) |
| SSMS ขึ้น error เรื่อง certificate ตอน Connect | ตั้ง **Encryption** เป็น Optional หรือติ๊ก **Trust server certificate** |
| `Login failed for user` | บัญชี Windows ยังไม่มีสิทธิ์ใน SQL Server เพิ่ม login ใน SSMS (Security > Logins) หรือใช้บัญชีที่ติดตั้ง SQL Server |
| `Cannot open database "market_db"` หรือ `Invalid object name` | ยังไม่ได้รัน `schema.sql` / `logic.sql` ให้รันตามลำดับในขั้นที่ 1 หรือ query ถูกรันในฐานข้อมูลผิด (ตรวจ dropdown ฐานข้อมูลที่แถบด้านบนว่าเป็น `market_db`) |
| รันแล้วขึ้นข้อความไม่ครบ หรือรันได้แค่บางส่วน | ใน SSMS มีการไฮไลต์ข้อความค้างอยู่ ให้คลิกในแท็บให้ไม่มีข้อความถูกเลือก แล้วกด Execute ใหม่ |
| ช่องเลือกวันตลาดว่าง | ไม่มีวันตลาดที่เปิดรับจองและยังไม่ผ่านมา ให้เพิ่มวันตลาดที่หน้าจัดการแผงค้า / วันตลาด |
| หน้าเว็บไม่มีสไตล์ ปุ่มกดแล้วไม่มีอะไรเกิดขึ้น | ไม่มีอินเทอร์เน็ต (โหลด Bootstrap ไม่ได้) |
| หน้าเว็บขึ้น "โหลดข้อมูล...ไม่สำเร็จ" | เปิด `https://localhost:<พอร์ต>/<ชื่อ>.ashx` (เช่น `Merchants.ashx`) ตรงๆ แล้วดูข้อความใน `detail` |
| `Msg 208 Invalid object name 'sp_...'` ตอนรัน `logic.sql` | มี procedure ชื่อเดียวกันตกค้างในฐานข้อมูล `master` ตรวจด้วย `SELECT name FROM master.sys.objects WHERE name LIKE 'sp[_]%'` แล้วลบตัวที่ตกค้างด้วย `USE master; GO DROP PROCEDURE dbo.sp_reserve_stall; GO` จากนั้นรัน `logic.sql` ใหม่ |
| อยากรีเซ็ตข้อมูลเป็นค่าตั้งต้น | รัน `schema.sql` → `data.sql` → `logic.sql` ใหม่ตามลำดับ |
