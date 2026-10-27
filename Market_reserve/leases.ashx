<%@ WebHandler Language="C#" Class="Leases" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Web;
using System.Web.Script.Serialization;

// GET  /Leases.ashx  -> { leases: [...], staff: [...] }   (สัญญาใหม่สุดก่อน)
// POST /Leases.ashx  { action: "cancel", lease_id, staff_id }
//        -> เรียก sp_cancel_lease (Transaction: เปลี่ยนสถานะสัญญา + บันทึกคืนเงินมัดจำ ในครั้งเดียว)
public class Leases : IHttpHandler
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
                CancelLease(ctx, js);
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
        // วันที่แปลงเป็นข้อความใน SQL เลย กันปัญหาปี พ.ศ.
        string sql = @"
            SELECT l.lease_id, s.stall_code, m.merchant_name,
                   CONVERT(varchar(10), d.market_date, 23) AS market_date,
                   l.rent_price, l.deposit_amount, st.staff_name, l.status
            FROM leases l
            JOIN stalls s       ON s.stall_id = l.stall_id
            JOIN merchants m    ON m.merchant_id = l.merchant_id
            JOIN market_days d  ON d.market_day_id = l.market_day_id
            JOIN staff st       ON st.staff_id = l.staff_id
            ORDER BY d.market_date DESC, l.lease_id DESC;

            SELECT staff_id, staff_name FROM staff ORDER BY staff_id;";

        var leases = new List<object>();
        var staff = new List<object>();

        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            conn.Open();
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())   // ชุดที่ 1: สัญญา
                {
                    leases.Add(new
                    {
                        lease_id = r.GetInt32(0),
                        stall_code = r.GetString(1),
                        merchant_name = r.GetString(2),
                        market_date = r.GetString(3),
                        rent_price = r.GetDecimal(4),
                        deposit_amount = r.GetDecimal(5),
                        staff_name = r.GetString(6),
                        status = r.GetString(7)
                    });
                }

                r.NextResult();    // ชุดที่ 2: พนักงาน
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

        ctx.Response.Write(js.Serialize(new { leases = leases, staff = staff }));
    }

    // ---------- ยกเลิกสัญญา ----------
    private void CancelLease(HttpContext ctx, JavaScriptSerializer js)
    {
        string body = new StreamReader(ctx.Request.InputStream).ReadToEnd();
        CancelRequest req = js.Deserialize<CancelRequest>(body);

        if (req.action != "cancel")
        {
            Fail(ctx, js, 400, "คำสั่งไม่ถูกต้อง", 0, null);
            return;
        }

        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand("dbo.sp_cancel_lease", conn))
        {
            cmd.CommandType = CommandType.StoredProcedure;
            cmd.Parameters.Add("@lease_id", SqlDbType.Int).Value = req.lease_id;
            cmd.Parameters.Add("@staff_id", SqlDbType.Int).Value = req.staff_id;

            var refund = cmd.Parameters.Add("@refund_amount", SqlDbType.Decimal);
            refund.Precision = 10;
            refund.Scale = 2;
            refund.Direction = ParameterDirection.Output;

            conn.Open();
            cmd.ExecuteNonQuery();

            decimal refunded = (refund.Value == null || refund.Value == DBNull.Value)
                ? 0m
                : Convert.ToDecimal(refund.Value);

            ctx.Response.Write(js.Serialize(new { ok = true, refund_amount = refunded }));
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

public class CancelRequest
{
    public string action;
    public int lease_id;
    public int staff_id;
}
