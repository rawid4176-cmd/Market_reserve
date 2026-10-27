<%@ WebHandler Language="C#" Class="Revenue" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data.SqlClient;
using System.Web;
using System.Web.Script.Serialization;

// GET /Revenue.ashx -> สรุปอัตราการเช่าและรายได้แยกตามโซน (อ่านจาก View: vw_market_zone_revenue)
// อ่านอย่างเดียว ไม่มีการเขียนข้อมูล
public class Revenue : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext ctx)
    {
        ctx.Response.ContentType = "application/json; charset=utf-8";
        var js = new JavaScriptSerializer();

        if (ctx.Request.HttpMethod != "GET")
        {
            ctx.Response.StatusCode = 405;
            ctx.Response.Write(js.Serialize(new { ok = false, message = "ยังไม่รองรับวิธีนี้" }));
            return;
        }

        try
        {
            // เลือกคอลัมน์ตามชื่อจาก View (ถ้าเพื่อนเพิ่มคอลัมน์ใหม่ใน View จะไม่กระทบตรงนี้)
            string sql = @"SELECT zone_id, zone_name,
                                  total_stalls_in_zone, available_stalls_in_zone,
                                  total_open_days, total_available_stall_days,
                                  rented_lease_count, occupancy_rate_pct,
                                  total_rent_revenue, total_utility_revenue, total_zone_revenue
                           FROM vw_market_zone_revenue
                           ORDER BY zone_id";

            var rows = new List<object>();
            using (var conn = new SqlConnection(ConfigurationManager.ConnectionStrings["market_db"].ConnectionString))
            using (var cmd = new SqlCommand(sql, conn))
            {
                conn.Open();
                using (var r = cmd.ExecuteReader())
                {
                    while (r.Read())
                    {
                        // ใช้ Convert เพื่อไม่ผูกกับชนิดข้อมูลเป๊ะๆ ของ View (INT/BIGINT/DECIMAL ใช้ได้หมด)
                        rows.Add(new
                        {
                            zone_id = Convert.ToInt32(r["zone_id"]),
                            zone_name = Convert.ToString(r["zone_name"]),
                            total_stalls_in_zone = Convert.ToInt32(r["total_stalls_in_zone"]),
                            available_stalls_in_zone = Convert.ToInt32(r["available_stalls_in_zone"]),
                            total_open_days = Convert.ToInt32(r["total_open_days"]),
                            total_available_stall_days = Convert.ToInt32(r["total_available_stall_days"]),
                            rented_lease_count = Convert.ToInt32(r["rented_lease_count"]),
                            // โซนที่ไม่มีแผงใช้งานได้ View จะให้ NULL -> ส่งเป็น null ให้หน้าเว็บแสดง "-"
                            occupancy_rate_pct = r["occupancy_rate_pct"] == DBNull.Value
                                ? (decimal?)null
                                : Convert.ToDecimal(r["occupancy_rate_pct"]),
                            total_rent_revenue = Convert.ToDecimal(r["total_rent_revenue"]),
                            total_utility_revenue = Convert.ToDecimal(r["total_utility_revenue"]),
                            total_zone_revenue = Convert.ToDecimal(r["total_zone_revenue"])
                        });
                    }
                }
            }

            ctx.Response.Write(js.Serialize(rows));
        }
        catch (Exception ex)
        {
            ctx.Response.StatusCode = 500;
            // detail ไว้ช่วยหาสาเหตุตอนพัฒนา (เช่น ยังไม่ได้รัน logic.sql จึงไม่มี View) ก่อนส่งงานจริงจะลบออกก็ได้
            ctx.Response.Write(js.Serialize(new { ok = false, message = "อ่านข้อมูลรายงานไม่สำเร็จ", detail = ex.Message }));
        }
    }
}
