<%@ WebHandler Language="C#" Class="Reserve" %>

using System;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Web;
using System.Web.Script.Serialization;

// POST /Reserve.ashx   body: { stall_id, merchant_id, market_day_id, staff_id, paid_amount }
// เรียก dbo.sp_reserve_stall (Transaction ACID อยู่ใน DB ไม่ต้องทำซ้ำที่เว็บ)
public class Reserve : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext ctx)
    {
        ctx.Response.ContentType = "application/json; charset=utf-8";
        var js = new JavaScriptSerializer();

        if (ctx.Request.HttpMethod != "POST")
        {
            ctx.Response.StatusCode = 405;
            ctx.Response.Write(js.Serialize(new { ok = false, message = "ต้องใช้วิธี POST" }));
            return;
        }

        try
        {
            string body = new StreamReader(ctx.Request.InputStream).ReadToEnd();
            ReserveRequest req = js.Deserialize<ReserveRequest>(body);
            string cs = ConfigurationManager.ConnectionStrings["market_db"].ConnectionString;

            using (var conn = new SqlConnection(cs))
            using (var cmd = new SqlCommand("dbo.sp_reserve_stall", conn))
            {
                cmd.CommandType = CommandType.StoredProcedure;
                cmd.Parameters.Add("@stall_id", SqlDbType.Int).Value = req.stall_id;
                cmd.Parameters.Add("@merchant_id", SqlDbType.Int).Value = req.merchant_id;
                cmd.Parameters.Add("@market_day_id", SqlDbType.Int).Value = req.market_day_id;
                cmd.Parameters.Add("@staff_id", SqlDbType.Int).Value = req.staff_id;

                var paid = cmd.Parameters.Add("@paid_amount", SqlDbType.Decimal);
                paid.Precision = 10;
                paid.Scale = 2;
                paid.Value = req.paid_amount;

                var leaseOut = cmd.Parameters.Add("@lease_id", SqlDbType.Int);
                leaseOut.Direction = ParameterDirection.Output;

                conn.Open();
                cmd.ExecuteNonQuery();

                ctx.Response.Write(js.Serialize(new { ok = true, lease_id = (int)leaseOut.Value }));
            }
        }
        catch (SqlException ex)
        {
            // 50000-50099 คือ error ที่ procedure/trigger ตั้งใจ THROW (ข้อความเป็นภาษาไทยอยู่แล้ว)
            bool business = ex.Number >= 50000 && ex.Number <= 50099;
            ctx.Response.StatusCode = business ? 400 : 500;
            ctx.Response.Write(js.Serialize(new
            {
                ok = false,
                code = ex.Number,
                message = business ? ex.Message : "ระบบฐานข้อมูลขัดข้อง กรุณาลองใหม่อีกครั้ง"
            }));
        }
        catch (Exception)
        {
            ctx.Response.StatusCode = 400;
            ctx.Response.Write(js.Serialize(new { ok = false, message = "ข้อมูลที่ส่งมาไม่ถูกต้อง" }));
        }
    }
}

public class ReserveRequest
{
    public int stall_id;
    public int merchant_id;
    public int market_day_id;
    public int staff_id;
    public decimal paid_amount;
}
