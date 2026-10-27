<%@ WebHandler Language="C#" Class="Utilities" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Web;
using System.Web.Script.Serialization;

// GET  /Utilities.ashx -> { utilities: [...], leases: [...] }
//        utilities = รายการค่าน้ำไฟทั้งหมด (ใหม่สุดก่อน)
//        leases    = สัญญาที่ยังใช้งาน ไว้ให้เลือกในฟอร์มบันทึก
// POST /Utilities.ashx { lease_id, utility_type, units_used }
//        -> เรียก sp_record_utility (ฐานข้อมูลใส่ราคาต่อหน่วยและเวลาให้เอง หน้าเว็บส่งแค่ 3 ค่านี้)
public class Utilities : IHttpHandler
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
                RecordUtility(ctx, js);
            }
            else
            {
                Fail(ctx, js, 405, "ยังไม่รองรับวิธีนี้", 0, null);
            }
        }
        catch (SqlException ex)
        {
            // 50000-50099 คือ error ที่ procedure ตั้งใจ THROW (ข้อความเป็นภาษาไทยอยู่แล้ว)
            bool business = ex.Number >= 50000 && ex.Number <= 50099;
            if (business)
                Fail(ctx, js, 400, ex.Message, ex.Number, null);
            else
                Fail(ctx, js, 500, "ระบบฐานข้อมูลขัดข้อง", ex.Number, ex.Message);
        }
        catch (Exception ex)
        {
            Fail(ctx, js, 500, "เกิดข้อผิดพลาดในระบบ", 0, ex.Message);
        }
    }

    // ---------- อ่านข้อมูล ----------
    private void LoadAll(HttpContext ctx, JavaScriptSerializer js)
    {
        // charge_amount เป็นคอลัมน์คำนวณในตาราง (หน่วย × ราคาต่อหน่วย) อ่านได้อย่างเดียว
        // วันที่แปลงเป็นข้อความใน SQL เลย กันปัญหาปี พ.ศ.
        string sql = @"
            SELECT u.charge_id, u.lease_id, s.stall_code, m.merchant_name, u.utility_type,
                   u.units_used, u.unit_rate, u.charge_amount,
                   CONVERT(varchar(16), u.recorded_at, 120) AS recorded_at
            FROM utility_charges u
            JOIN leases l    ON l.lease_id = u.lease_id
            JOIN stalls s    ON s.stall_id = l.stall_id
            JOIN merchants m ON m.merchant_id = l.merchant_id
            ORDER BY u.recorded_at DESC, u.charge_id DESC;

            SELECT l.lease_id, s.stall_code, m.merchant_name,
                   CONVERT(varchar(10), d.market_date, 23) AS market_date
            FROM leases l
            JOIN stalls s       ON s.stall_id = l.stall_id
            JOIN merchants m    ON m.merchant_id = l.merchant_id
            JOIN market_days d  ON d.market_day_id = l.market_day_id
            WHERE l.status = 'rented'
            ORDER BY d.market_date DESC, l.lease_id DESC;";

        var utilities = new List<object>();
        var leases = new List<object>();

        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            conn.Open();
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())   // ชุดที่ 1: ค่าน้ำไฟ
                {
                    utilities.Add(new
                    {
                        charge_id = r.GetInt32(0),
                        lease_id = r.GetInt32(1),
                        stall_code = r.GetString(2),
                        merchant_name = r.GetString(3),
                        utility_type = r.GetString(4),
                        units_used = r.GetDecimal(5),
                        unit_rate = r.GetDecimal(6),
                        charge_amount = r.GetDecimal(7),
                        recorded_at = r.GetString(8)
                    });
                }

                r.NextResult();    // ชุดที่ 2: สัญญาที่ยังใช้งาน
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
            }
        }

        ctx.Response.Write(js.Serialize(new { utilities = utilities, leases = leases }));
    }

    // ---------- บันทึกค่าน้ำไฟ ----------
    private void RecordUtility(HttpContext ctx, JavaScriptSerializer js)
    {
        string body = new StreamReader(ctx.Request.InputStream).ReadToEnd();
        UtilityRequest req = js.Deserialize<UtilityRequest>(body);

        // กันค่าที่ใหญ่เกินชนิดข้อมูล DECIMAL(8,2) ก่อนส่งให้ procedure (ส่วนกฎอื่น procedure ตรวจเอง)
        decimal units = Math.Round(req.units_used, 2);
        if (units > 999999.99m)
        {
            Fail(ctx, js, 400, "จำนวนหน่วยที่ใช้ต้องไม่เกิน 999,999.99", 0, null);
            return;
        }

        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand("dbo.sp_record_utility", conn))
        {
            cmd.CommandType = CommandType.StoredProcedure;
            cmd.Parameters.Add("@lease_id", SqlDbType.Int).Value = req.lease_id;
            cmd.Parameters.Add("@utility_type", SqlDbType.VarChar, 12).Value = (object)req.utility_type ?? DBNull.Value;

            var u = cmd.Parameters.Add("@units_used", SqlDbType.Decimal);
            u.Precision = 8;
            u.Scale = 2;
            u.Value = units;

            var chargeOut = cmd.Parameters.Add("@charge_id", SqlDbType.Int);
            chargeOut.Direction = ParameterDirection.Output;

            conn.Open();
            cmd.ExecuteNonQuery();   // procedure มี SELECT แถวที่บันทึกกลับมาด้วย แต่เราใช้ค่า OUTPUT แล้วโหลดรายการใหม่เอง

            ctx.Response.Write(js.Serialize(new { ok = true, charge_id = Convert.ToInt32(chargeOut.Value) }));
        }
    }

    // ---------- ตัวช่วย ----------
    private static string ConnStr()
    {
        return ConfigurationManager.ConnectionStrings["market_db"].ConnectionString;
    }

    private static void Fail(HttpContext ctx, JavaScriptSerializer js, int status, string message, int code, string detail)
    {
        ctx.Response.StatusCode = status;
        // detail ไว้ช่วยหาสาเหตุตอนพัฒนา (ก่อนส่งงานจริงจะลบออกก็ได้)
        ctx.Response.Write(js.Serialize(new { ok = false, code = code, message = message, detail = detail }));
    }
}

public class UtilityRequest
{
    public int lease_id;
    public string utility_type;
    public decimal units_used;
}
