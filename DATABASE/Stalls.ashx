<%@ WebHandler Language="C#" Class="Stalls" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data.SqlClient;
using System.Web;
using System.Web.Script.Serialization;

// GET /Stalls.ashx -> { zones, stalls, days, booked, merchants, staff }
//   days   = วันตลาดที่เปิดรับจองและยังไม่ผ่านมา (ใช้วันที่ของเซิร์ฟเวอร์)
//   booked = แผงที่ถูกจองแล้ว (status = 'rented') ในวันตลาดเหล่านั้น
// การจองจริงทำผ่าน Reserve.ashx (เรียก usp_reserve_stall)
public class Stalls : IHttpHandler
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
            string sql = @"
                SELECT zone_id, zone_name, base_rent, deposit_percent FROM stall_zones ORDER BY zone_id;

                SELECT stall_id, zone_id, stall_code, size_sqm, status FROM stalls ORDER BY stall_id;

                SELECT market_day_id, CONVERT(varchar(10), market_date, 23) AS market_date
                FROM market_days
                WHERE is_open = 1 AND market_date >= CAST(SYSDATETIME() AS date)
                ORDER BY market_date;

                SELECT l.stall_id, l.market_day_id
                FROM leases l
                JOIN market_days d ON d.market_day_id = l.market_day_id
                WHERE l.status = 'rented' AND d.is_open = 1 AND d.market_date >= CAST(SYSDATETIME() AS date);

                SELECT merchant_id, merchant_name FROM merchants ORDER BY merchant_name;

                SELECT staff_id, staff_name FROM staff ORDER BY staff_id;";

            var zones = new List<object>();
            var stalls = new List<object>();
            var days = new List<object>();
            var booked = new List<object>();
            var merchants = new List<object>();
            var staff = new List<object>();

            using (var conn = new SqlConnection(ConfigurationManager.ConnectionStrings["market_db"].ConnectionString))
            using (var cmd = new SqlCommand(sql, conn))
            {
                conn.Open();
                using (var r = cmd.ExecuteReader())
                {
                    while (r.Read())
                        zones.Add(new { zone_id = r.GetInt32(0), zone_name = r.GetString(1), base_rent = r.GetDecimal(2), deposit_percent = r.GetDecimal(3) });

                    r.NextResult();
                    while (r.Read())
                        stalls.Add(new
                        {
                            stall_id = r.GetInt32(0),
                            zone_id = r.GetInt32(1),
                            stall_code = r.GetString(2),
                            size_sqm = r.IsDBNull(3) ? (decimal?)null : r.GetDecimal(3),
                            status = r.GetString(4)
                        });

                    r.NextResult();
                    while (r.Read())
                        days.Add(new { market_day_id = r.GetInt32(0), market_date = r.GetString(1) });

                    r.NextResult();
                    while (r.Read())
                        booked.Add(new { stall_id = r.GetInt32(0), market_day_id = r.GetInt32(1) });

                    r.NextResult();
                    while (r.Read())
                        merchants.Add(new { merchant_id = r.GetInt32(0), merchant_name = r.GetString(1) });

                    r.NextResult();
                    while (r.Read())
                        staff.Add(new { staff_id = r.GetInt32(0), staff_name = r.GetString(1) });
                }
            }

            ctx.Response.Write(js.Serialize(new { zones = zones, stalls = stalls, days = days, booked = booked, merchants = merchants, staff = staff }));
        }
        catch (Exception ex)
        {
            ctx.Response.StatusCode = 500;
            ctx.Response.Write(js.Serialize(new { ok = false, message = "อ่านข้อมูลแผงค้าไม่สำเร็จ", detail = ex.Message }));
        }
    }
}
