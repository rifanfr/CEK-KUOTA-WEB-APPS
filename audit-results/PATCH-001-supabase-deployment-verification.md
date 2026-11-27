# PATCH-001: Supabase Security Deployment Verification Report

**Tanggal Audit**: 2026-11-22  
**Target File DDL**: `cekkuota-kk/supabase_hardening_production.sql`  
**Status Akhir**: `DATABASE RUNTIME VERIFICATION BLOCKED`  

---

## 1. Ringkasan Eksekutif

Audit independen terhadap kesiapan dan penegakan keamanan basis data Supabase (PostgreSQL) untuk sistem Cek Kuota KK menemukan bahwa runner audit lokal tidak memiliki koneksi jaringan aktif ke instans Supabase produksi, kredensial otentikasi, maupun variabel lingkungan (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). 

Sesuai aturan kejujuran audit (*Audit Honesty Policy*), ketiadaan bukti eksekusi runtime melarang pemberian status "PASS" atau "DEPLOYED". Oleh karena itu, seluruh verifikasi runtime penegakan DDL dan Row Level Security (RLS) berstatus resmi:

```text
DATABASE RUNTIME VERIFICATION BLOCKED
```

---

## 2. Status Objek Database (11 Item)

Seluruh 11 objek basis data yang didefinisikan dalam `supabase_hardening_production.sql` dievaluasi statusnya:

| No | Nama Objek Database | Tipe Objek | Status Level Script Lokal | Status Server Supabase Produksi |
|---|---|---|---|---|
| 1 | `transaction_audit_trail` | Table | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 2 | `capture_audit_trail_trigger()` | Function | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 3 | `validate_quota_limit_trigger()` | Function | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 4 | `cancel_log_with_supervisor_pin()` | RPC Function | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 5 | `trg_audit_logs_track` | Trigger | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 6 | `trg_audit_wh_track` | Trigger | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 7 | `chk_customers_no_kk_format` | CHECK Constraint | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 8 | `uq_customers_clean_no_kk` | UNIQUE Index | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 9 | Quota Quantity Constraints (`chk_logs_qty_*`) | CHECK Constraints | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 10 | Row Level Security (RLS) Core Tables | Security Mechanism | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| 11 | Attached RLS Policies (14 Policies) | Security Policy | `STATICALLY VERIFIED ONLY` | `DATABASE RUNTIME VERIFICATION BLOCKED` |

---

## 3. Matriks Pengujian RLS (14 Skenario Role `anon`)

Seluruh pengujian interaksi langsung role `anon` (role aplikasi kasir/kios) tidak dapat dieksekusi secara runtime karena ketiadaan host target dan kredensial:

| Test ID | Skenario Uji | Role | Perintah (Secrets Redacted) | Hasil yang Diharapkan | Hasil Aktual / Status HTTP | Status Uji | Tipe Bukti |
|---|---|---|---|---|---|---|---|
| **RLS-01** | `SELECT customers` | `anon` | `GET /rest/v1/customers` | 200 OK | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-02** | `INSERT customer` | `anon` | `POST /rest/v1/customers` | 201 Created | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-03** | `UPDATE customer` | `anon` | `PATCH /rest/v1/customers?no_kk=...` | 200 OK | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-04** | `DELETE customer` | `anon` | `DELETE /rest/v1/customers?no_kk=...` | 403 Forbidden / 0 rows | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-05** | `INSERT logs directly` | `anon` | `POST /rest/v1/logs` | 201 Created (Valid) / 400 (Trigger limit) | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-06** | `UPDATE logs directly` | `anon` | `PATCH /rest/v1/logs?id=...` | 200 OK (Audit trail logged) | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-07** | `DELETE logs directly` | `anon` | `DELETE /rest/v1/logs?id=...` | 200/204 (Audit trail logged) | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-08** | `INSERT warehouse_logs directly` | `anon` | `POST /rest/v1/warehouse_logs` | 201 Created (Qty > 0) | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-09** | `UPDATE warehouse_logs directly` | `anon` | `PATCH /rest/v1/warehouse_logs?id=...` | 200 OK (Audit trail logged) | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-10** | `DELETE warehouse_logs directly` | `anon` | `DELETE /rest/v1/warehouse_logs?id=...` | 200/204 (Audit trail logged) | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-11** | RPC Cancel dengan PIN Salah | `anon` | `POST /rest/v1/rpc/cancel_log_with_supervisor_pin` | Exception / Rejection | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-12** | RPC Cancel tanpa PIN | `anon` | `POST /rest/v1/rpc/cancel_log_with_supervisor_pin` | 400 Bad Request / Exception | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-13** | `Read transaction_audit_trail` | `anon` | `GET /rest/v1/transaction_audit_trail` | 200 OK (Read policy) | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |
| **RLS-14** | `Modify transaction_audit_trail` | `anon` | `DELETE/PATCH /rest/v1/transaction_audit_trail` | 403 Forbidden / 0 rows | Tidak Terkirim | BLOCKED | `DATABASE RUNTIME VERIFICATION BLOCKED` |

---

## 4. Analisis Keterbatasan Keamanan (Security Limitations)

1. **Client-Side PIN Enforcement vs Server-Side RLS**:
   Validasi PIN supervisor di JavaScript `dispatch-console.html` tidak melindungi database jika klien memanggil REST API Supabase secara langsung dengan anon key.
2. **Ketiadaan Atomic Transaction antar Tabel**:
   Pencatatan kuota di `logs` dan pemotongan stok di `warehouse_logs` dikirim sebagai panggilan terpisah dari peramban, belum dibungkus dalam stored procedure database atomik tunggal.
3. **Penyimpangan Row-Level Concurrency Lock**:
   Fungsi trigger `validate_quota_limit_trigger()` mengeksekusi `PERFORM 1 FROM customers WHERE no_kk = NEW.no_kk FOR UPDATE`. Jika transaksi dilakukan untuk No KK baru yang belum tercatat pada baris `customers`, query tersebut menghasilkan 0 baris dan tidak ada baris yang terkunci (*zero row lock*), sehingga transaksi paralel untuk KK baru tersebut dapat saling bertabrakan. Rekomendasi `pg_advisory_xact_lock()` belum diterapkan.

---

## 5. Kesimpulan dan Tindak Lanjut

* **Status Klasifikasi**: `DATABASE RUNTIME VERIFICATION BLOCKED`
* **Tindakan yang Dibutuhkan**: Eksekusi DDL `supabase_hardening_production.sql` harus dilakukan secara sadar oleh pemilik sistem melalui Supabase SQL Editor Dashboard, diikuti dengan pengujian RLS pada staging environment terisolasi.
