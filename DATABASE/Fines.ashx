<%@ WebHandler Language="C#" Class="Fines" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Web;
using System.Web.Script.Serialization;

// GET  /Fines.ashx  -> { fines: [...], leases: [...], staff: [...] }
//        fines  = รายการค่าปรับทั้งหมด (ใหม่สุดก่อน)
//        leases = สัญญาที่ยังใช้งาน ไว้ให้เลือกในฟอร์ม
//        staff  = พนักงาน ไว้ให้เลือกในฟอร์ม
// POST /Fines.ashx  { lease_id, staff_id, reason, amount }  -> บันทึกค่าปรับใหม่
public class Fines : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext ctx)
    {
        ctx.Response.ContentType = "application/json; charset=utf-8";
        var js = new JavaScriptSerializer();

        try
        {
            if (ctx.Request.HttpMethod == "GET")
            {
                LoadAll(ctx, js);
            }
            else if (ctx.Request.HttpMethod == "POST")
            {
                AddFine(ctx, js);
            }
            else
            {
                Fail(ctx, js, 405, "ยังไม่รองรับวิธีนี้");
            }
        }
        catch (SqlException ex)
        {
            if (ex.Number == 547)   // ชน FOREIGN KEY หรือ CHECK
                Fail(ctx, js, 400, "บันทึกไม่ได้ กรุณาตรวจสอบสัญญาและพนักงานที่เลือก", ex.Message);
            else
                Fail(ctx, js, 500, "ระบบฐานข้อมูลขัดข้อง", ex.Message);
        }
        catch (Exception ex)
        {
            Fail(ctx, js, 500, "เกิดข้อผิดพลาดในระบบ", ex.Message);
        }
    }

    // ---------- อ่านข้อมูลทั้งหมดที่หน้าค่าปรับต้องใช้ ----------
    private void LoadAll(HttpContext ctx, JavaScriptSerializer js)
    {
        // ส่ง SQL 3 คำสั่งในครั้งเดียว ได้ผลลัพธ์ 3 ชุดต่อกัน
        // (วันที่แปลงเป็นข้อความใน SQL เลย กันปัญหาปี พ.ศ. จากการตั้งค่าภาษาของเครื่อง)
        string sql = @"
            SELECT f.fine_id, f.lease_id, s.stall_code, m.merchant_name, f.reason, f.amount,
                   st.staff_name, CONVERT(varchar(16), f.fined_at, 120) AS fined_at
            FROM fine_logs f
            JOIN leases l    ON l.lease_id = f.lease_id
            JOIN stalls s    ON s.stall_id = l.stall_id
            JOIN merchants m ON m.merchant_id = l.merchant_id
            JOIN staff st    ON st.staff_id = f.staff_id
            ORDER BY f.fined_at DESC, f.fine_id DESC;

            SELECT l.lease_id, s.stall_code, m.merchant_name,
                   CONVERT(varchar(10), d.market_date, 23) AS market_date
            FROM leases l
            JOIN stalls s       ON s.stall_id = l.stall_id
            JOIN merchants m    ON m.merchant_id = l.merchant_id
            JOIN market_days d  ON d.market_day_id = l.market_day_id
            WHERE l.status = 'rented'
            ORDER BY d.market_date DESC, l.lease_id DESC;

            SELECT staff_id, staff_name FROM staff ORDER BY staff_id;";

        var fines = new List<object>();
        var leases = new List<object>();
        var staff = new List<object>();

        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            conn.Open();
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())   // ชุดที่ 1: ค่าปรับ
                {
                    fines.Add(new
                    {
                        fine_id = r.GetInt32(0),
                        lease_id = r.GetInt32(1),
                        stall_code = r.GetString(2),
                        merchant_name = r.GetString(3),
                        reason = r.GetString(4),
                        amount = r.GetDecimal(5),
                        staff_name = r.GetString(6),
                        fined_at = r.GetString(7)
                    });
                }

                r.NextResult();    // ไปชุดที่ 2: สัญญา
                while (r.Read())
                {
                    leases.Add(new
                    {
                        lease_id = r.GetInt32(0),
                        stall_code = r.GetString(1),
                        merchant_name = r.GetString(2),
                        market_date = r.GetString(3)
                    });
                }

                r.NextResult();    // ไปชุดที่ 3: พนักงาน
                while (r.Read())
                {
                    staff.Add(new
                    {
                        staff_id = r.GetInt32(0),
                        staff_name = r.GetString(1)
                    });
                }
            }
        }

        ctx.Response.Write(js.Serialize(new { fines = fines, leases = leases, staff = staff }));
    }

    // ---------- บันทึกค่าปรับใหม่ ----------
    private void AddFine(HttpContext ctx, JavaScriptSerializer js)
    {
        string body = new StreamReader(ctx.Request.InputStream).ReadToEnd();
        FineRequest req = js.Deserialize<FineRequest>(body);

        // ตรวจซ้ำที่ฝั่งเซิร์ฟเวอร์
        string reason = (req.reason ?? "").Trim();
        if (reason == "" || reason.Length > 200)
        {
            Fail(ctx, js, 400, "กรุณากรอกเหตุผล (ไม่เกิน 200 ตัวอักษร)");
            return;
        }
        decimal amount = Math.Round(req.amount, 2);
        if (amount <= 0 || amount > 99999999.99m)
        {
            Fail(ctx, js, 400, "จำนวนเงินต้องมากกว่า 0 และไม่เกิน 99,999,999.99");
            return;
        }

        // fined_at ไม่ต้องส่ง ฐานข้อมูลใส่เวลาปัจจุบันให้เอง (DEFAULT SYSDATETIME())
        string sql = @"INSERT INTO fine_logs (lease_id, staff_id, reason, amount)
                       OUTPUT INSERTED.fine_id
                       VALUES (@lease_id, @staff_id, @reason, @amount)";

        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.Add("@lease_id", SqlDbType.Int).Value = req.lease_id;
            cmd.Parameters.Add("@staff_id", SqlDbType.Int).Value = req.staff_id;
            cmd.Parameters.Add("@reason", SqlDbType.NVarChar, 200).Value = reason;
            var p = cmd.Parameters.Add("@amount", SqlDbType.Decimal);
            p.Precision = 10;
            p.Scale = 2;
            p.Value = amount;

            conn.Open();
            int newId = (int)cmd.ExecuteScalar();
            ctx.Response.Write(js.Serialize(new { ok = true, fine_id = newId }));
        }
    }

    // ---------- ตัวช่วย ----------
    private static string ConnStr()
    {
        return ConfigurationManager.ConnectionStrings["market_db"].ConnectionString;
    }

    private static void Fail(HttpContext ctx, JavaScriptSerializer js, int status, string message, string detail = null)
    {
        ctx.Response.StatusCode = status;
        // detail ไว้ช่วยหาสาเหตุตอนพัฒนา (ก่อนส่งงานจริงจะลบออกก็ได้)
        ctx.Response.Write(js.Serialize(new { ok = false, message = message, detail = detail }));
    }
}

public class FineRequest
{
    public int lease_id;
    public int staff_id;
    public string reason;
    public decimal amount;
}
