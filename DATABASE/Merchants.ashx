<%@ WebHandler Language="C#" Class="Merchants" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Text.RegularExpressions;
using System.Web;
using System.Web.Script.Serialization;

// GET  /Merchants.ashx                                  -> รายชื่อผู้ค้าทั้งหมด (JSON array)
// POST /Merchants.ashx  { action: "add",    merchant_name, phone, goods_type }
// POST /Merchants.ashx  { action: "edit",   merchant_id, merchant_name, phone, goods_type }
// POST /Merchants.ashx  { action: "delete", merchant_id }
public class Merchants : IHttpHandler
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
                ListMerchants(ctx, js);
            }
            else if (ctx.Request.HttpMethod == "POST")
            {
                SaveMerchant(ctx, js);
            }
            else
            {
                Fail(ctx, js, 405, "ยังไม่รองรับวิธีนี้");
            }
        }
        catch (SqlException ex)
        {
            // แปลงรหัส error ของ SQL Server เป็นข้อความที่ผู้ใช้เข้าใจ
            if (ex.Number == 2627 || ex.Number == 2601)        // ชน UNIQUE (เบอร์โทรซ้ำ)
                Fail(ctx, js, 409, "เบอร์โทรนี้ถูกใช้แล้ว");
            else if (ex.Number == 547)                         // ชน FOREIGN KEY (มีสัญญาอ้างอิงอยู่)
                Fail(ctx, js, 409, "ผู้ค้ารายนี้มีสัญญาอยู่ ลบไม่ได้");
            else
                Fail(ctx, js, 500, "ระบบฐานข้อมูลขัดข้อง", ex.Message);
        }
        catch (Exception ex)
        {
            Fail(ctx, js, 500, "เกิดข้อผิดพลาดในระบบ", ex.Message);
        }
    }

    // ---------- อ่านรายการ ----------
    private void ListMerchants(HttpContext ctx, JavaScriptSerializer js)
    {
        string sql = @"SELECT m.merchant_id, m.merchant_name, m.phone, m.goods_type,
                              CASE WHEN EXISTS (SELECT 1 FROM leases l WHERE l.merchant_id = m.merchant_id)
                                   THEN 1 ELSE 0 END AS has_lease
                       FROM merchants m
                       ORDER BY m.merchant_id";

        var rows = new List<object>();
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sql, conn))
        {
            conn.Open();
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())
                {
                    rows.Add(new
                    {
                        merchant_id = r.GetInt32(0),
                        merchant_name = r.GetString(1),
                        phone = r.GetString(2),
                        goods_type = r.IsDBNull(3) ? null : r.GetString(3),
                        has_lease = r.GetInt32(4)
                    });
                }
            }
        }
        ctx.Response.Write(js.Serialize(rows));
    }

    // ---------- เพิ่ม / แก้ไข / ลบ ----------
    private void SaveMerchant(HttpContext ctx, JavaScriptSerializer js)
    {
        string body = new StreamReader(ctx.Request.InputStream).ReadToEnd();
        MerchantRequest req = js.Deserialize<MerchantRequest>(body);

        // --- ลบ ---
        if (req.action == "delete")
        {
            using (var conn = new SqlConnection(ConnStr()))
            using (var cmd = new SqlCommand("DELETE FROM merchants WHERE merchant_id = @id", conn))
            {
                cmd.Parameters.Add("@id", SqlDbType.Int).Value = req.merchant_id;
                conn.Open();
                if (cmd.ExecuteNonQuery() == 0)
                {
                    Fail(ctx, js, 404, "ไม่พบผู้ค้ารายนี้");
                    return;
                }
            }
            ctx.Response.Write(js.Serialize(new { ok = true }));
            return;
        }

        if (req.action != "add" && req.action != "edit")
        {
            Fail(ctx, js, 400, "คำสั่งไม่ถูกต้อง");
            return;
        }

        // --- ตรวจข้อมูลซ้ำที่ฝั่งเซิร์ฟเวอร์ (ห้ามเชื่อแค่การตรวจในหน้าเว็บ) ---
        string name = (req.merchant_name ?? "").Trim();
        string phone = (req.phone ?? "").Trim();
        string goods = (req.goods_type ?? "").Trim();

        if (name == "" || name.Length > 100)
        {
            Fail(ctx, js, 400, "กรุณากรอกชื่อผู้ค้า (ไม่เกิน 100 ตัวอักษร)");
            return;
        }
        if (!Regex.IsMatch(phone, @"^0\d{9}$"))
        {
            Fail(ctx, js, 400, "กรุณากรอกเบอร์โทร 10 หลัก ขึ้นต้นด้วย 0");
            return;
        }
        if (goods.Length > 50)
        {
            Fail(ctx, js, 400, "ประเภทสินค้าต้องไม่เกิน 50 ตัวอักษร");
            return;
        }
        object goodsValue = goods == "" ? (object)DBNull.Value : goods;

        // --- เพิ่ม ---
        if (req.action == "add")
        {
            string sqlAdd = @"INSERT INTO merchants (merchant_name, phone, goods_type)
                              OUTPUT INSERTED.merchant_id
                              VALUES (@name, @phone, @goods)";
            using (var conn = new SqlConnection(ConnStr()))
            using (var cmd = new SqlCommand(sqlAdd, conn))
            {
                AddParams(cmd, name, phone, goodsValue);
                conn.Open();
                int newId = (int)cmd.ExecuteScalar();
                ctx.Response.Write(js.Serialize(new { ok = true, merchant_id = newId }));
            }
            return;
        }

        // --- แก้ไข ---
        string sqlEdit = @"UPDATE merchants
                           SET merchant_name = @name, phone = @phone, goods_type = @goods
                           WHERE merchant_id = @id";
        using (var conn = new SqlConnection(ConnStr()))
        using (var cmd = new SqlCommand(sqlEdit, conn))
        {
            AddParams(cmd, name, phone, goodsValue);
            cmd.Parameters.Add("@id", SqlDbType.Int).Value = req.merchant_id;
            conn.Open();
            if (cmd.ExecuteNonQuery() == 0)
            {
                Fail(ctx, js, 404, "ไม่พบผู้ค้ารายนี้");
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

    // ใช้ parameter (@name ฯลฯ) แทนการเอาข้อความไปต่อใน SQL -> กัน SQL Injection
    private static void AddParams(SqlCommand cmd, string name, string phone, object goodsValue)
    {
        cmd.Parameters.Add("@name", SqlDbType.NVarChar, 100).Value = name;
        cmd.Parameters.Add("@phone", SqlDbType.VarChar, 15).Value = phone;
        cmd.Parameters.Add("@goods", SqlDbType.NVarChar, 50).Value = goodsValue;
    }

    private static void Fail(HttpContext ctx, JavaScriptSerializer js, int status, string message, string detail = null)
    {
        ctx.Response.StatusCode = status;
        // detail ไว้ช่วยหาสาเหตุตอนพัฒนา (ก่อนส่งงานจริงจะลบออกก็ได้)
        ctx.Response.Write(js.Serialize(new { ok = false, message = message, detail = detail }));
    }
}

public class MerchantRequest
{
    public string action;
    public int merchant_id;
    public string merchant_name;
    public string phone;
    public string goods_type;
}
