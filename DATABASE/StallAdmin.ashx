<%@ WebHandler Language="C#" Class="StallAdmin" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Web;
using System.Web.Script.Serialization;

// จัดการแผงค้าและวันตลาด (CRUD)
//
// GET  /StallAdmin.ashx  -> { today, zones, stalls, days }
// POST /StallAdmin.ashx  { action: ... }
//   add_stall     { zone_id, stall_code, size_sqm, status }
//   edit_stall    { stall_id, zone_id, stall_code, size_sqm, status }
//   delete_stall  { stall_id }
//   add_day       { market_date: "yyyy-MM-dd", is_open }
//   set_day_open  { market_day_id, is_open }
//   delete_day    { market_day_id }
public class StallAdmin : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    // เก็บ action ของคำขอนี้ไว้ ใช้เลือกข้อความ error ให้ตรงกับสิ่งที่ผู้ใช้ทำ
    private string _action = "";

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
                Dispatch(ctx, js);
            }
            else
            {
                Fail(ctx, js, 405, "ยังไม่รองรับวิธีนี้");
            }
        }
        catch (SqlException ex)
        {
            // แปลงรหัส error ของ SQL Server เป็นข้อความที่ผู้ใช้เข้าใจ
            if (ex.Number == 2627 || ex.Number == 2601)         // ชน UNIQUE
            {
                if (_action == "add_day")
                    Fail(ctx, js, 409, "มีวันตลาดวันนี้อยู่ในระบบแล้ว");
                else
                    Fail(ctx, js, 409, "รหัสแผงนี้ถูกใช้แล้ว");
            }
            else if (ex.Number == 547)                          // ชน FOREIGN KEY / CHECK
            {
                if (_action == "delete_stall")
                    Fail(ctx, js, 409, "แผงนี้มีสัญญาอยู่ ลบไม่ได้ (ถ้าไม่ใช้งานแล้ว ให้เปลี่ยนสถานะเป็นปิดซ่อมบำรุงแทน)");
                else if (_action == "delete_day")
                    Fail(ctx, js, 409, "วันตลาดนี้มีสัญญาอยู่ ลบไม่ได้ (ถ้าไม่ต้องการให้จอง ให้ปิดรับจองแทน)");
                else
                    Fail(ctx, js, 400, "ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบโซนและสถานะที่เลือก");
            }
            else
            {
                Fail(ctx, js, 500, "ระบบฐานข้อมูลขัดข้อง", ex.Message);
            }
        }
        catch (Exception ex)
        {
            Fail(ctx, js, 500, "เกิดข้อผิดพลาดในระบบ", ex.Message);
        }
    }

    // ---------- อ่านข้อมูลทั้งหมดที่หน้าจัดการต้องใช้ ----------
    private void LoadAll(HttpContext ctx, JavaScriptSerializer js)
    {
        // lease_count = จำนวนสัญญาทุกสถานะที่อ้างถึงแผง/วันตลาดนั้น (ถ้ามากกว่า 0 จะลบไม่ได้)
        // วันที่แปลงเป็นข้อความใน SQL เลย กันปัญหาปี พ.ศ.
        string sql = @"
            SELECT CONVERT(varchar(10), CAST(SYSDATETIME() AS date), 23) AS today;

            SELECT zone_id, zone_name FROM stall_zones ORDER BY zone_id;

            SELECT s.stall_id, s.zone_id, s.stall_code, s.size_sqm, s.status,
                   (SELECT COUNT(*) FROM leases l WHERE l.stall_id = s.stall_id) AS lease_count
            FROM stalls s
            ORDER BY s.zone_id, s.stall_code;

            SELECT d.market_day_id, CONVERT(varchar(10), d.market_date, 23) AS market_date, d.is_open,
                   (SELECT COUNT(*) FROM leases l WHERE l.market_day_id = d.market_day_id) AS lease_count
            FROM market_days d
            ORDER BY d.market_date DESC;";

        string today = "";
        var zones = new List<object>();
        var stalls = new List<object>();
        var days = new List<object>();

        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            conn.Open();
            using (var r = cmd.ExecuteReader())
            {
                if (r.Read()) today = r.GetString(0);      // ชุดที่ 1: วันนี้ (ตามเวลาของ SQL Server)

                r.NextResult();                            // ชุดที่ 2: โซน
                while (r.Read())
                {
                    zones.Add(new { zone_id = r.GetInt32(0), zone_name = r.GetString(1) });
                }

                r.NextResult();                            // ชุดที่ 3: แผง
                while (r.Read())
                {
                    stalls.Add(new
                    {
                        stall_id = r.GetInt32(0),
                        zone_id = r.GetInt32(1),
                        stall_code = r.GetString(2),
                        size_sqm = r.IsDBNull(3) ? (decimal?)null : r.GetDecimal(3),
                        status = r.GetString(4),
                        lease_count = r.GetInt32(5)
                    });
                }

                r.NextResult();                            // ชุดที่ 4: วันตลาด
                while (r.Read())
                {
                    days.Add(new
                    {
                        market_day_id = r.GetInt32(0),
                        market_date = r.GetString(1),
                        is_open = r.GetBoolean(2) ? 1 : 0,
                        lease_count = r.GetInt32(3)
                    });
                }
            }
        }

        ctx.Response.Write(js.Serialize(new { today = today, zones = zones, stalls = stalls, days = days }));
    }

    // ---------- แยกคำสั่ง ----------
    private void Dispatch(HttpContext ctx, JavaScriptSerializer js)
    {
        string body = new StreamReader(ctx.Request.InputStream).ReadToEnd();
        AdminRequest req = js.Deserialize<AdminRequest>(body);
        _action = req.action ?? "";

        switch (_action)
        {
            case "add_stall": AddStall(ctx, js, req); break;
            case "edit_stall": EditStall(ctx, js, req); break;
            case "delete_stall": DeleteStall(ctx, js, req); break;
            case "add_day": AddDay(ctx, js, req); break;
            case "set_day_open": SetDayOpen(ctx, js, req); break;
            case "delete_day": DeleteDay(ctx, js, req); break;
            default: Fail(ctx, js, 400, "คำสั่งไม่ถูกต้อง"); break;
        }
    }

    // ===================== แผงค้า =====================

    // ตรวจข้อมูลแผงที่ฝั่งเซิร์ฟเวอร์ (ห้ามเชื่อแค่การตรวจในหน้าเว็บ)
    private bool ReadStallInput(HttpContext ctx, JavaScriptSerializer js, AdminRequest req,
                                out string code, out object size)
    {
        code = (req.stall_code ?? "").Trim();
        size = DBNull.Value;

        if (code == "" || code.Length > 10)
        {
            Fail(ctx, js, 400, "กรุณากรอกรหัสแผง (ไม่เกิน 10 ตัวอักษร)");
            return false;
        }
        if (req.status != "available" && req.status != "maintenance")
        {
            Fail(ctx, js, 400, "สถานะแผงไม่ถูกต้อง");
            return false;
        }
        if (req.size_sqm.HasValue)
        {
            decimal v = Math.Round(req.size_sqm.Value, 2);
            if (v <= 0 || v > 999.99m)
            {
                Fail(ctx, js, 400, "ขนาดล็อกต้องมากกว่า 0 และไม่เกิน 999.99 ตร.ม.");
                return false;
            }
            size = v;
        }
        return true;
    }

    private static void AddStallParams(SqlCommand cmd, AdminRequest req, string code, object size)
    {
        cmd.Parameters.Add("@zone", SqlDbType.Int).Value = req.zone_id;
        cmd.Parameters.Add("@code", SqlDbType.NVarChar, 10).Value = code;
        var p = cmd.Parameters.Add("@size", SqlDbType.Decimal);
        p.Precision = 5;
        p.Scale = 2;
        p.Value = size;
        cmd.Parameters.Add("@status", SqlDbType.VarChar, 15).Value = req.status;
    }

    private void AddStall(HttpContext ctx, JavaScriptSerializer js, AdminRequest req)
    {
        string code; object size;
        if (!ReadStallInput(ctx, js, req, out code, out size)) return;

        string sql = @"INSERT INTO stalls (zone_id, stall_code, size_sqm, status)
                       OUTPUT INSERTED.stall_id
                       VALUES (@zone, @code, @size, @status)";
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            AddStallParams(cmd, req, code, size);
            conn.Open();
            int newId = (int)cmd.ExecuteScalar();
            ctx.Response.Write(js.Serialize(new { ok = true, stall_id = newId }));
        }
    }

    private void EditStall(HttpContext ctx, JavaScriptSerializer js, AdminRequest req)
    {
        string code; object size;
        if (!ReadStallInput(ctx, js, req, out code, out size)) return;

        // กฎ: แผงที่มีสัญญาแล้วเปลี่ยนโซนไม่ได้ (กันประวัติรายได้ของโซนเพี้ยน)
        // ใส่เงื่อนไขไว้ใน UPDATE เดียว ทำงานแบบอะตอมมิก ไม่ต้องตรวจแยกก่อน
        string sql = @"UPDATE stalls
                       SET zone_id = @zone, stall_code = @code, size_sqm = @size, status = @status
                       WHERE stall_id = @id
                         AND (zone_id = @zone
                              OR NOT EXISTS (SELECT 1 FROM leases l WHERE l.stall_id = @id))";
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            AddStallParams(cmd, req, code, size);
            cmd.Parameters.Add("@id", SqlDbType.Int).Value = req.stall_id;
            conn.Open();

            if (cmd.ExecuteNonQuery() == 0)
            {
                // ไม่มีแถวถูกแก้: ไม่พบแผง หรือถูกกฎห้ามเปลี่ยนโซนกันไว้
                if (!RowExists(conn, "SELECT COUNT(*) FROM stalls WHERE stall_id = @id", req.stall_id))
                    Fail(ctx, js, 404, "ไม่พบแผงนี้");
                else
                    Fail(ctx, js, 409, "แผงนี้มีสัญญาแล้ว เปลี่ยนโซนไม่ได้");
                return;
            }
        }
        ctx.Response.Write(js.Serialize(new { ok = true }));
    }

    private void DeleteStall(HttpContext ctx, JavaScriptSerializer js, AdminRequest req)
    {
        // ถ้ามีสัญญาอ้างถึงแผงนี้ ฐานข้อมูลจะไม่ยอมให้ลบ (FOREIGN KEY) -> จับได้ใน catch ด้านบน
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand("DELETE FROM stalls WHERE stall_id = @id", conn))
        {
            cmd.Parameters.Add("@id", SqlDbType.Int).Value = req.stall_id;
            conn.Open();
            if (cmd.ExecuteNonQuery() == 0)
            {
                Fail(ctx, js, 404, "ไม่พบแผงนี้");
                return;
            }
        }
        ctx.Response.Write(js.Serialize(new { ok = true }));
    }

    // ===================== วันตลาด =====================

    private void AddDay(HttpContext ctx, JavaScriptSerializer js, AdminRequest req)
    {
        DateTime date;
        if (!DateTime.TryParseExact(req.market_date ?? "", "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                    DateTimeStyles.None, out date))
        {
            Fail(ctx, js, 400, "รูปแบบวันที่ไม่ถูกต้อง");
            return;
        }

        // เพิ่มได้เฉพาะวันนี้หรืออนาคต: วันตลาดที่เปิดและผ่านมาแล้วถูกนับในตัวหารของอัตราการเช่า
        // ถ้าเพิ่มย้อนหลังจะทำให้อัตราการเช่าใน View เพี้ยน
        // INSERT ... SELECT ... WHERE: ถ้าเงื่อนไขไม่ผ่านจะไม่มีแถวถูกเพิ่ม และ ExecuteScalar คืน null
        string sql = @"INSERT INTO market_days (market_date, is_open)
                       OUTPUT INSERTED.market_day_id
                       SELECT @d, @open
                       WHERE @d >= CAST(SYSDATETIME() AS date)";
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.Add("@d", SqlDbType.Date).Value = date.Date;
            cmd.Parameters.Add("@open", SqlDbType.Bit).Value = req.is_open;
            conn.Open();

            object result = cmd.ExecuteScalar();
            if (result == null)
            {
                Fail(ctx, js, 400, "เพิ่มได้เฉพาะวันตลาดตั้งแต่วันนี้เป็นต้นไป");
                return;
            }
            ctx.Response.Write(js.Serialize(new { ok = true, market_day_id = Convert.ToInt32(result) }));
        }
    }

    private void SetDayOpen(HttpContext ctx, JavaScriptSerializer js, AdminRequest req)
    {
        // เปลี่ยนได้เฉพาะวันนี้หรืออนาคต (วันที่ผ่านมาแล้วเป็นประวัติ ห้ามแก้)
        string sql = @"UPDATE market_days SET is_open = @open
                       WHERE market_day_id = @id AND market_date >= CAST(SYSDATETIME() AS date)";
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.Add("@open", SqlDbType.Bit).Value = req.is_open;
            cmd.Parameters.Add("@id", SqlDbType.Int).Value = req.market_day_id;
            conn.Open();

            if (cmd.ExecuteNonQuery() == 0)
            {
                if (!RowExists(conn, "SELECT COUNT(*) FROM market_days WHERE market_day_id = @id", req.market_day_id))
                    Fail(ctx, js, 404, "ไม่พบวันตลาดนี้");
                else
                    Fail(ctx, js, 409, "วันตลาดที่ผ่านมาแล้วเปลี่ยนสถานะไม่ได้");
                return;
            }
        }
        ctx.Response.Write(js.Serialize(new { ok = true }));
    }

    private void DeleteDay(HttpContext ctx, JavaScriptSerializer js, AdminRequest req)
    {
        // ลบได้เฉพาะวันนี้หรืออนาคต และต้องไม่มีสัญญา (ถ้ามี FOREIGN KEY จะกันไว้ -> จับได้ใน catch ด้านบน)
        string sql = @"DELETE FROM market_days
                       WHERE market_day_id = @id AND market_date >= CAST(SYSDATETIME() AS date)";
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.Add("@id", SqlDbType.Int).Value = req.market_day_id;
            conn.Open();

            if (cmd.ExecuteNonQuery() == 0)
            {
                if (!RowExists(conn, "SELECT COUNT(*) FROM market_days WHERE market_day_id = @id", req.market_day_id))
                    Fail(ctx, js, 404, "ไม่พบวันตลาดนี้");
                else
                    Fail(ctx, js, 409, "วันตลาดที่ผ่านมาแล้วลบไม่ได้");
                return;
            }
        }
        ctx.Response.Write(js.Serialize(new { ok = true }));
    }

    // ---------- ตัวช่วย ----------
    private static string ConnStr()
    {
        return ConfigurationManager.ConnectionStrings["market_db"].ConnectionString;
    }

    // ตรวจว่ามีแถวนั้นอยู่จริงไหม (ใช้แยกกรณี "ไม่พบ" ออกจาก "ไม่ได้รับอนุญาต")
    private static bool RowExists(SqlConnection conn, string sql, int id)
    {
        using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.Add("@id", SqlDbType.Int).Value = id;
            return (int)cmd.ExecuteScalar() > 0;
        }
    }

    private static void Fail(HttpContext ctx, JavaScriptSerializer js, int status, string message, string detail = null)
    {
        ctx.Response.StatusCode = status;
        // detail ไว้ช่วยหาสาเหตุตอนพัฒนา (ก่อนส่งงานจริงจะลบออกก็ได้)
        ctx.Response.Write(js.Serialize(new { ok = false, message = message, detail = detail }));
    }
}

public class AdminRequest
{
    public string action;
    public int stall_id;
    public int zone_id;
    public string stall_code;
    public decimal? size_sqm;
    public string status;
    public int market_day_id;
    public string market_date;
    public bool is_open;
}
