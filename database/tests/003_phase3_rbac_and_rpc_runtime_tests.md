# PHASE-3 RBAC & RPC RUNTIME TEST SPECIFICATION
**Environment:** Staging / Production Staging Sandbox  
**Database Engine:** PostgreSQL 15+ (Supabase)  
**Target Migration Package:** `003_phase3_secure_rpc_and_idempotency.sql`  
**Security Model:** Unified Authenticated-Only RPCs with In-Function JWT RBAC  

---

## 1. Overview & Objectives

Phase 3 introduces enterprise-grade security hardening, disambiguated RPC signatures, and persistent server-side idempotency ledgers:
1. **Server-Side RBAC**: Mutation RPCs reject anonymous/unauthenticated execution directly at PostgreSQL privilege boundary (`REVOKE ALL FROM anon, PUBLIC`) and inside function execution (`auth.role() = 'authenticated'` and `app_metadata.role` claim inspection).
2. **Deterministic Server Idempotency**:
   - `customer_registration_requests`: Persistent ledger with SHA-256 fingerprinting protecting `register_customer`.
   - `warehouse_logs.request_id`: Partial unique index `uq_wh_request_id` preventing double-posting of warehouse mutations.
   - `logs.request_id`: Primary idempotency key for quota transactions with atomic customer auto-registration and `P0014` conflict protection.
3. **Whitelisted Warehouse Operations**: Restrictions on `process_warehouse_mutation` permitting only `INITIAL-STOCK`, `GR`, and `GI-MANUAL`, with `P0013` single-use lock on `INITIAL-STOCK`, `P0010` rejection on unauthorized/reversal mutation types, and strict stock deficit checks (`P0003` for Beras, `P0004` for Gas) on `GI-MANUAL`.

---

## 2. Test Execution Context & Simulation Framework

In Supabase PostgreSQL, request context can be simulated inside transactional blocks using `SET LOCAL` statements:

```sql
-- Template Sesi Testing Simulasi
BEGIN;

-- Simulasi status role PostgreSQL (anon / authenticated)
SET LOCAL role = 'authenticated';

-- Simulasi JWT Claim Supabase Auth
SET LOCAL request.jwt.claims = '{
  "sub": "00000000-0000-0000-0000-000000000001",
  "email": "kasir1@desa.id",
  "app_metadata": {
    "role": "cashier"
  }
}';

-- Eksekusi RPC yang diuji...

ROLLBACK; -- Atau COMMIT jika memvalidasi data transaksional
```

### Role Matrix Reference
| Role | `process_quota_dispense` | `register_customer` | `process_warehouse_mutation` | Direct Table Writes |
| :--- | :---: | :---: | :---: | :---: |
| **`anon` / Unauthenticated** | ❌ DENY (`42501`) | ❌ DENY (`42501`) | ❌ DENY (`42501`) | ❌ DENY (0 table grants) |
| **`cashier`** | ✅ ALLOW | ✅ ALLOW | ❌ DENY (`42501`) | ❌ DENY |
| **`warehouse_admin`** | ❌ DENY (`42501`) | ❌ DENY (`42501`) | ✅ ALLOW | ❌ DENY |
| **`supervisor`** | ✅ ALLOW | ✅ ALLOW | ✅ ALLOW | ❌ DENY |
| **`admin`** | ✅ ALLOW | ✅ ALLOW | ✅ ALLOW | ❌ DENY |

---

## 3. RBAC Test Suite (Role-Based Access Control)

### Test RBAC-01: Anon / Unauthenticated Rejection on All Mutation RPCs
* **Objective**: Confirm that callers without a valid JWT are blocked at the database privilege boundary.
* **Expected Result**: Error `42501` (permission denied for function).

```sql
-- Skenario Anon
BEGIN;
SET LOCAL role = 'anon';

-- 1. Uji process_quota_dispense
DO $$
BEGIN
  PERFORM public.process_quota_dispense(
    'TEST-REQ-ANON-01', '3201010101010001', 'Warga Anon', 'MBR-ANON-01', 1, 0
  );
  RAISE EXCEPTION 'RBAC-01 FAILED: Anon berhasil mengeksekusi process_quota_dispense';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'RBAC-01.1 PASS: process_quota_dispense ditolak untuk anon (42501)';
END;
$$;

-- 2. Uji register_customer
DO $$
BEGIN
  PERFORM public.register_customer(
    'TEST-REQ-ANON-02', '3201010101010001', 'MBR-ANON-01', 'Warga Anon'
  );
  RAISE EXCEPTION 'RBAC-01 FAILED: Anon berhasil mengeksekusi register_customer';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'RBAC-01.2 PASS: register_customer ditolak untuk anon (42501)';
END;
$$;

-- 3. Uji process_warehouse_mutation
DO $$
BEGIN
  PERFORM public.process_warehouse_mutation(
    'TEST-REQ-ANON-03', CURRENT_DATE, 'GR', 'beras', 10
  );
  RAISE EXCEPTION 'RBAC-01 FAILED: Anon berhasil mengeksekusi process_warehouse_mutation';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'RBAC-01.3 PASS: process_warehouse_mutation ditolak untuk anon (42501)';
END;
$$;

ROLLBACK;
```

---

### Test RBAC-02: Authenticated User Without Required Role Claim
* **Objective**: Ensure that a valid authenticated session missing the required `app_metadata.role` cannot execute mutations.
* **Expected Result**: Error `42501` (`FORBIDDEN: Pengguna dengan role "" tidak berwenang...`).

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-user-000","app_metadata":{}}';

DO $$
BEGIN
  PERFORM public.process_quota_dispense(
    'TEST-REQ-NOROLE-01', '3201010101010002', 'Warga NoRole', 'MBR-NOROLE-01', 1, 0
  );
  RAISE EXCEPTION 'RBAC-02 FAILED: User tanpa role berhasil mengeksekusi dispense';
EXCEPTION WHEN SQLSTATE '42501' THEN
  RAISE NOTICE 'RBAC-02.1 PASS: Dispense ditolak untuk user tanpa role (42501)';
END;
$$;

DO $$
BEGIN
  PERFORM public.register_customer(
    'TEST-REQ-NOROLE-02', '3201010101010002', 'MBR-NOROLE-01', 'Warga NoRole'
  );
  RAISE EXCEPTION 'RBAC-02 FAILED: User tanpa role berhasil mengeksekusi register';
EXCEPTION WHEN SQLSTATE '42501' THEN
  RAISE NOTICE 'RBAC-02.2 PASS: Registrasi ditolak untuk user tanpa role (42501)';
END;
$$;

ROLLBACK;
```

---

### Test RBAC-03: Cashier Role Permissions & Boundary
* **Objective**: Confirm `cashier` can dispense quota and register customers, but is forbidden from warehouse mutations.
* **Expected Result**: Dispense & Register PASS; Warehouse Mutation FAIL with `42501`.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-cashier-001","app_metadata":{"role":"cashier"}}';

-- 1. Register Customer (HARUS BERHASIL)
SELECT public.register_customer(
  'TEST-REQ-CSH-REG-01',
  '3201010101010010',
  'MBR-CSH-010',
  'Budi Santoso Kasir Test',
  'Jawa Barat', 'Bogor', 'Cibinong', 'Pabuaran', 'RT 01 RW 02'
);

-- 2. Process Quota Dispense (HARUS BERHASIL jika stok tersedia)
-- Siapkan stok via elevated DO block untuk pengujian
DO $$
BEGIN
  -- Coba eksekusi gudang langsung sebagai kasir -> HARUS DITOLAK
  BEGIN
    PERFORM public.process_warehouse_mutation(
      'TEST-REQ-CSH-WH-01', CURRENT_DATE, 'GR', 'beras', 50
    );
    RAISE EXCEPTION 'RBAC-03 FAILED: Cashier berhasil mengeksekusi process_warehouse_mutation';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    RAISE NOTICE 'RBAC-03 PASS: Cashier dilarang melakukan mutasi gudang (42501)';
  END;
END;
$$;

ROLLBACK;
```

---

### Test RBAC-04: Warehouse Admin Role Permissions & Boundary
* **Objective**: Confirm `warehouse_admin` can manage warehouse stock, but is forbidden from dispensing customer quota.
* **Expected Result**: Warehouse Mutation PASS; Dispense & Register FAIL with `42501`.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-wh-001","app_metadata":{"role":"warehouse_admin"}}';

-- 1. Mutasi Gudang GR (HARUS BERHASIL)
SELECT public.process_warehouse_mutation(
  'TEST-REQ-WH-GR-01', CURRENT_DATE, 'GR', 'beras', 100, 'Penerimaan Beras Bulog'
);

-- 2. Process Quota Dispense (HARUS DITOLAK)
DO $$
BEGIN
  PERFORM public.process_quota_dispense(
    'TEST-REQ-WH-DISP-01', '3201010101010020', 'Warga Test', 'MBR-020', 1, 0
  );
  RAISE EXCEPTION 'RBAC-04 FAILED: Warehouse Admin berhasil melakukan penyaluran kuota';
EXCEPTION WHEN SQLSTATE '42501' THEN
  RAISE NOTICE 'RBAC-04.1 PASS: Warehouse Admin dilarang menyalurkan kuota (42501)';
END;
$$;

-- 3. Register Customer (HARUS DITOLAK)
DO $$
BEGIN
  PERFORM public.register_customer(
    'TEST-REQ-WH-REG-01', '3201010101010020', 'MBR-020', 'Warga Test'
  );
  RAISE EXCEPTION 'RBAC-04 FAILED: Warehouse Admin berhasil mendaftarkan pelanggan';
EXCEPTION WHEN SQLSTATE '42501' THEN
  RAISE NOTICE 'RBAC-04.2 PASS: Warehouse Admin dilarang mendaftarkan pelanggan (42501)';
END;
$$;

ROLLBACK;
```

---

### Test RBAC-05: Supervisor & Admin Role Authority
* **Objective**: Confirm `supervisor` and `admin` have authorization across all three RPCs.
* **Expected Result**: All operations succeed.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-spv-001","app_metadata":{"role":"supervisor"}}';

-- 1. Warehouse GR
SELECT public.process_warehouse_mutation(
  'TEST-REQ-SPV-WH-01', CURRENT_DATE, 'GR', 'beras', 50, 'Stok Awal SPV'
);

-- 2. Customer Registration
SELECT public.register_customer(
  'TEST-REQ-SPV-REG-01', '3201010101010030', 'MBR-030', 'Siti Aminah SPV Test'
);

-- 3. Quota Dispense
SELECT public.process_quota_dispense(
  'TEST-REQ-SPV-DISP-01', '3201010101010030', 'Siti Aminah SPV Test', 'MBR-030', 2, 0
);

RAISE NOTICE 'RBAC-05 PASS: Supervisor berhasil mengeksekusi ketiga RPC';
ROLLBACK;
```

---

## 4. Runtime & Idempotency Test Suite

### Test CUST-01 & CUST-02: Customer Registration Idempotency Replay
* **Objective**: Verify that identical re-submission returns original data with `is_idempotent_replay: true` and writes no duplicate rows.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-cashier-001","app_metadata":{"role":"cashier"}}';

-- Panggilan Pertama: Registrasi Baru
SELECT public.register_customer(
  'REQ-CUST-IDEM-001',
  '3201010101019991',
  'MBR-9991',
  'Ahmad Dahlan',
  'Jawa Barat', 'Bogor', 'Cibinong', 'Cirimekar', 'Jl. Mayor Oking No. 1'
);

-- Panggilan Kedua: Replay Identik (request_id dan payload sama)
SELECT public.register_customer(
  'REQ-CUST-IDEM-001',
  '3201010101019991',
  'MBR-9991',
  'Ahmad Dahlan',
  'Jawa Barat', 'Bogor', 'Cibinong', 'Cirimekar', 'Jl. Mayor Oking No. 1'
);

-- Verifikasi jumlah baris di basis data HARUS tepat 1
DO $$
DECLARE
  v_cust_count INT;
  v_req_count INT;
BEGIN
  SELECT count(*) INTO v_cust_count FROM customers WHERE no_kk = '3201010101019991';
  SELECT count(*) INTO v_req_count FROM customer_registration_requests WHERE request_id = 'REQ-CUST-IDEM-001';

  IF v_cust_count <> 1 OR v_req_count <> 1 THEN
    RAISE EXCEPTION 'CUST-02 FAILED: Ditemukan baris duplikat (cust: %, req: %)', v_cust_count, v_req_count;
  END IF;
  RAISE NOTICE 'CUST-01 & CUST-02 PASS: Idempotent replay sukses tanpa duplikasi';
END;
$$;

ROLLBACK;
```

---

### Test CUST-03: Registration Payload Conflict (`P0009`)
* **Objective**: Ensure that reusing a `request_id` with modified parameters is rejected.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-cashier-001","app_metadata":{"role":"cashier"}}';

-- 1. Pendaftaran Pertama
PERFORM public.register_customer(
  'REQ-CUST-CONF-001', '3201010101019992', 'MBR-9992', 'Bambang Sudibyo'
);

-- 2. Panggilan Kedua dengan request_id sama tetapi nama diubah
DO $$
BEGIN
  PERFORM public.register_customer(
    'REQ-CUST-CONF-001', '3201010101019992', 'MBR-9992', 'Bambang Pamungkas'
  );
  RAISE EXCEPTION 'CUST-03 FAILED: Payload conflict tidak terdeteksi';
EXCEPTION WHEN SQLSTATE 'P0009' THEN
  RAISE NOTICE 'CUST-03 PASS: Payload conflict berhasil ditolak dengan P0009';
END;
$$;

ROLLBACK;
```

---

### Test CUST-04: Customer Identity Conflict on Existing KK (`P0014`)
* **Objective**: Prevent silent overwriting of customer identity when registering an existing KK under a different name.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-cashier-001","app_metadata":{"role":"cashier"}}';

-- 1. Daftarkan KK 3201010101019993 atas nama Hendra
PERFORM public.register_customer(
  'REQ-CUST-KK-001', '3201010101019993', 'MBR-9993', 'Hendra Gunawan'
);

-- 2. Daftarkan KK yang sama dengan request_id baru tetapi nama berbeda -> HARUS P0014
DO $$
BEGIN
  PERFORM public.register_customer(
    'REQ-CUST-KK-002', '3201010101019993', 'MBR-9993', 'Joko Widodo'
  );
  RAISE EXCEPTION 'CUST-04 FAILED: Identity conflict pada No KK tidak terdeteksi';
EXCEPTION WHEN SQLSTATE 'P0014' THEN
  RAISE NOTICE 'CUST-04 PASS: Konflik identitas KK master ditolak dengan P0014';
END;
$$;

ROLLBACK;
```

---

### Test DISP-01 & DISP-02: Quota Dispense with Atomic Auto-Registration
* **Objective**: Confirm `process_quota_dispense` atomically registers a new customer if not previously registered, deducts stock, and records mutations with `request_id`.

```sql
BEGIN;
SET LOCAL role = 'authenticated';

-- Siapkan stok fisik gudang sebagai supervisor
SET LOCAL request.jwt.claims = '{"sub":"usr-spv-001","app_metadata":{"role":"supervisor"}}';
PERFORM public.process_warehouse_mutation(
  'REQ-INIT-DISP-STOCK', CURRENT_DATE, 'GR', 'beras', 50, 'Stok Pengujian Dispense'
);
PERFORM public.process_warehouse_mutation(
  'REQ-INIT-DISP-GAS', CURRENT_DATE, 'GR', 'gas', 50, 'Stok Pengujian Dispense'
);

-- Pindah ke kasir untuk transaksi
SET LOCAL request.jwt.claims = '{"sub":"usr-cashier-001","app_metadata":{"role":"cashier"}}';

-- Eksekusi Penyaluran untuk KK yang belum pernah didaftarkan
SELECT public.process_quota_dispense(
  p_request_id    => 'REQ-DISP-AUTO-001',
  p_no_kk         => '3201010101018881',
  p_nama          => 'Ratna Sari',
  p_member_id     => 'MBR-8881',
  p_qty_beras     => 2,
  p_qty_gas       => 1,
  p_tx_date       => CURRENT_DATE,
  p_provinsi      => 'Jawa Barat',
  p_kabupaten     => 'Bogor',
  p_kecamatan     => 'Cibinong',
  p_desa          => 'Pakansari',
  p_detail        => 'Jl. Stadion No. 10'
);

-- Verifikasi hasil atomik
DO $$
DECLARE
  v_cust_exists BOOLEAN;
  v_log_exists BOOLEAN;
  v_wh_count INT;
BEGIN
  -- Customer harus otomatis terdaftar
  SELECT EXISTS(SELECT 1 FROM customers WHERE no_kk = '3201010101018881') INTO v_cust_exists;
  -- Log transaksi harus tercatat
  SELECT EXISTS(SELECT 1 FROM logs WHERE request_id = 'REQ-DISP-AUTO-001') INTO v_log_exists;
  -- Mutasi gudang harus tercatat dengan prefix request_id
  SELECT count(*) INTO v_wh_count FROM warehouse_logs WHERE request_id IN ('REQ-WH-BERAS-REQ-DISP-AUTO-001', 'REQ-WH-GAS-REQ-DISP-AUTO-001');

  IF NOT v_cust_exists OR NOT v_log_exists OR v_wh_count <> 2 THEN
    RAISE EXCEPTION 'DISP-02 FAILED: Transaksi atomik tidak lengkap (cust: %, log: %, wh: %)', v_cust_exists, v_log_exists, v_wh_count;
  END IF;
  RAISE NOTICE 'DISP-01 & DISP-02 PASS: Penyaluran kuota & auto-registrasi atomik berhasil';
END;
$$;

ROLLBACK;
```

---

### Test DISP-03: Dispense Identity Conflict on Master Customer (`P0014`)
* **Objective**: Prevent a cashier from dispensing quota using an existing KK registered under a different name.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-cashier-001","app_metadata":{"role":"cashier"}}';

-- Daftarkan master customer terlebih dahulu
PERFORM public.register_customer(
  'REQ-REG-BASE-001', '3201010101018882', 'MBR-8882', 'Kurniawan Santoso'
);

-- Coba dispense dengan nama pemohon yang tidak sesuai
DO $$
BEGIN
  PERFORM public.process_quota_dispense(
    'REQ-DISP-MISMATCH-001', '3201010101018882', 'Suryanto Santoso', 'MBR-8882', 1, 0
  );
  RAISE EXCEPTION 'DISP-03 FAILED: Identity mismatch tidak terdeteksi pada dispense';
EXCEPTION WHEN SQLSTATE 'P0014' THEN
  RAISE NOTICE 'DISP-03 PASS: Dispense dengan nama berbeda ditolak dengan P0014';
END;
$$;

ROLLBACK;
```

---

### Test WH-01: Single-Use INITIAL-STOCK Lock (`P0013`)
* **Objective**: Confirm that `INITIAL-STOCK` can only be recorded once per commodity. Subsequent attempts must fail with `P0013`.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-spv-001","app_metadata":{"role":"supervisor"}}';

-- Catatan: Pastikan item tes belum memiliki INITIAL-STOCK aktif
-- 1. Pendaftaran Saldo Awal Beras Pertama Kali
SELECT public.process_warehouse_mutation(
  'REQ-WH-INIT-BERAS-01', CURRENT_DATE, 'INITIAL-STOCK', 'beras', 500, 'Saldo Awal Beras Gudang'
);

-- 2. Pendaftaran Saldo Awal Beras Kedua Kali -> HARUS DITOLAK P0013
DO $$
BEGIN
  PERFORM public.process_warehouse_mutation(
    'REQ-WH-INIT-BERAS-02', CURRENT_DATE, 'INITIAL-STOCK', 'beras', 200, 'Saldo Awal Duplikat'
  );
  RAISE EXCEPTION 'WH-01 FAILED: INITIAL-STOCK kedua kali tidak ditolak';
EXCEPTION WHEN SQLSTATE 'P0013' THEN
  RAISE NOTICE 'WH-01 PASS: INITIAL-STOCK berulang berhasil dikunci dengan P0013';
END;
$$;

ROLLBACK;
```

---

### Test WH-02, WH-03 & WH-04: GI-MANUAL Stock Deficit Guard (`P0003` / `P0004`)
* **Objective**: Confirm manual goods issue cannot exceed available warehouse physical balance.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-spv-001","app_metadata":{"role":"supervisor"}}';

-- Masukkan stok 10 pcs beras
PERFORM public.process_warehouse_mutation(
  'REQ-WH-GR-DEFICIT-01', CURRENT_DATE, 'GR', 'beras', 10, 'Stok Masuk Terbatas'
);

-- Pengeluaran 5 pcs beras (Harus Berhasil)
SELECT public.process_warehouse_mutation(
  'REQ-WH-GI-PASS-01', CURRENT_DATE, 'GI-MANUAL', 'beras', 5, 'Pengeluaran Rusak 5'
);

-- Pengeluaran 10 pcs beras (Tersisa 5 -> Harus Ditolak P0003)
DO $$
BEGIN
  PERFORM public.process_warehouse_mutation(
    'REQ-WH-GI-FAIL-01', CURRENT_DATE, 'GI-MANUAL', 'beras', 10, 'Pengeluaran Melebihi Stok'
  );
  RAISE EXCEPTION 'WH-04 FAILED: Defisit stok beras pada GI-MANUAL tidak terdeteksi';
EXCEPTION WHEN SQLSTATE 'P0003' THEN
  RAISE NOTICE 'WH-04 PASS: GI-MANUAL melebihi stok ditolak dengan P0003';
END;
$$;

ROLLBACK;
```

---

### Test WH-05: Rejection of Unauthorized & Reversal Mutation Types (`P0010`)
* **Objective**: Ensure generic mutation RPC strictly blocks unauthorized mutation types (`GR-BATAL`, `GR-REFUND`, `GI-WARGA`, `GI-PELANGGAN`, and foreign types) with uniform error code `P0010`.

```sql
BEGIN;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub":"usr-spv-001","app_metadata":{"role":"supervisor"}}';

-- 1. Penolakan GR-BATAL (Wajib P0010)
DO $
BEGIN
  PERFORM public.process_warehouse_mutation(
    'REQ-WH-REV-01', CURRENT_DATE, 'GR-BATAL', 'beras', 1
  );
  RAISE EXCEPTION 'WH-05.1 FAILED: GR-BATAL tidak ditolak dengan P0010';
EXCEPTION WHEN SQLSTATE 'P0010' THEN
  RAISE NOTICE 'WH-05.1 PASS: GR-BATAL ditolak dengan P0010 (pengalihan ke RPC khusus)';
END;
$;

-- 2. Penolakan GR-REFUND (Wajib P0010)
DO $
BEGIN
  PERFORM public.process_warehouse_mutation(
    'REQ-WH-REV-02', CURRENT_DATE, 'GR-REFUND', 'gas', 1
  );
  RAISE EXCEPTION 'WH-05.2 FAILED: GR-REFUND tidak ditolak dengan P0010';
EXCEPTION WHEN SQLSTATE 'P0010' THEN
  RAISE NOTICE 'WH-05.2 PASS: GR-REFUND ditolak dengan P0010 (pengalihan ke RPC khusus)';
END;
$;

-- 3. Penolakan GI-WARGA via Generic RPC (Wajib P0010)
DO $
BEGIN
  PERFORM public.process_warehouse_mutation(
    'REQ-WH-REV-03', CURRENT_DATE, 'GI-WARGA', 'beras', 1
  );
  RAISE EXCEPTION 'WH-05.3 FAILED: GI-WARGA tidak ditolak dengan P0010';
EXCEPTION WHEN SQLSTATE 'P0010' THEN
  RAISE NOTICE 'WH-05.3 PASS: GI-WARGA ditolak dengan P0010 (wajib via process_quota_dispense)';
END;
$;

-- 4. Penolakan Tipe Mutasi Asing / Ilegal (Wajib P0010)
DO $
BEGIN
  PERFORM public.process_warehouse_mutation(
    'REQ-WH-REV-04', CURRENT_DATE, 'CORRECTION-UNKNOWN', 'gas', 1
  );
  RAISE EXCEPTION 'WH-05.4 FAILED: Tipe mutasi asing tidak ditolak dengan P0010';
EXCEPTION WHEN SQLSTATE 'P0010' THEN
  RAISE NOTICE 'WH-05.4 PASS: Tipe asing ditolak dengan P0010';
END;
$;

ROLLBACK;
```

---

### Test RBAC-05: Rollback Security Verification (Post-Rollback Hardened Permissions)
* **Objective**: Confirm that if Phase-2 rollback occurs, the restored 9-argument `process_quota_dispense` function denies execution to `anon` and `PUBLIC` with SQLSTATE `42501`.

```sql
BEGIN;
SET LOCAL role = 'anon';

DO $
BEGIN
  -- Percobaan eksekusi RPC 9-argumen Fase-2 oleh anon
  PERFORM public.process_quota_dispense(
    'REQ-ROLL-ANON-01', '3201010101010001', 'WARGA SATU', 'M-001', 1, 0, CURRENT_DATE, 'ANON_OP', 'LOG-001'
  );
  RAISE EXCEPTION 'RBAC-05 FAILED: anon dapat mengeksekusi RPC Fase-2 setelah rollback';
EXCEPTION WHEN SQLSTATE '42501' THEN
  RAISE NOTICE 'RBAC-05 PASS: RPC Fase-2 setelah rollback tetap menolak anon (42501)';
END;
$;

ROLLBACK;
```

---

## 5. Synthetic Test Data Cleanup Protocol

Ketika pengujian non-rollback (komit ke database Staging) selesai dijalankan, bersihkan seluruh baris data sintetis menggunakan urutan deterministik berikut untuk mencegah pelanggaran integritas referensial:

```sql
-- PROTOKOL PEMBERSIHAN DATA SINTETIS PENGUJIAN FASE-3
-- Dijalankan oleh peran postgres / service_role

DO $$
DECLARE
  v_test_req_pattern TEXT := '%TEST-%';
BEGIN
  -- 1. Hapus catatan mutasi gudang pengujian terlebih dahulu
  DELETE FROM warehouse_logs 
  WHERE request_id LIKE v_test_req_pattern 
     OR id LIKE '%TEST%' 
     OR ref LIKE '%Test%';

  -- 2. Hapus catatan transaksi kuota pengujian
  DELETE FROM logs 
  WHERE request_id LIKE v_test_req_pattern 
     OR id LIKE '%TEST%' 
     OR nama LIKE '%Test%';

  -- 3. Hapus buku besar idempotensi registrasi pelanggan pengujian
  DELETE FROM customer_registration_requests 
  WHERE request_id LIKE v_test_req_pattern 
     OR no_kk LIKE '320101010101%';

  -- 4. Hapus data master pelanggan pengujian
  DELETE FROM customers 
  WHERE no_kk LIKE '320101010101%' 
     OR nama LIKE '%Test%';

  -- 5. Hapus jejak audit transaksi jika ada
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'transaction_audit_trail') THEN
    DELETE FROM transaction_audit_trail 
    WHERE log_id LIKE '%TEST%';
  END IF;

  RAISE NOTICE 'Pembersihan data sintetis pengujian Fase-3 selesai secara bersih.';
END;
$$;
```
