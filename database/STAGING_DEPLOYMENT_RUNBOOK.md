# STAGING DEPLOYMENT RUNBOOK: PHASE 1 & PHASE 2
**Sistem**: Catat Kuota KK (PostgreSQL / Supabase Staging)  
**Target Rilis**: Phase 1 (Database Foundation) & Phase 2 (Atomic RPC Dispense Transaction)  
**Dokumen Referensi**: `AUDIT_PACKAGE.md` (RULE-001 s/d RULE-017)  
**Status Audit**: Static Review Approved — Awaiting Owner Execution on Staging  

---

## 1. PANDUAN KEAMANAN & PRASYARAT OPERASIONAL

1. **Lingkungan Target**: **STAGING SAJA**. Dilarang keras mengeksekusi runbook ini langsung ke instans Produksi.
2. **Karakter Kredensial & Operator**:
   - Nilai parameter `p_operator_id` berstatus **client-reported dan UNTRUSTED**. Nilai ini bukan identitas terverifikasi.
   - Hak `GRANT EXECUTE ... TO anon` pada Phase-2 adalah **sementara untuk keperluan uji staging** dan wajib dievaluasi/diperketat pada Phase-4 (RLS Hardening).
3. **Pemberitahuan Efek Mutasi Khusus**:
   - Entri `GR-BATAL` (qty 5) menambah stok fisik gudang sebesar **tepat +5 sak**, tetapi **TIDAK** memulihkan kuota warga pada Phase-2.
   - Entri `GR-REFUND` (qty 3) menambah stok fisik gudang sebesar **tepat +3 tabung**, tetapi **TIDAK** memulihkan kuota warga pada Phase-2.
   - Pemulihan kuota warga ditangguhkan hingga perancangan RPC pembatalan & refund atomik pada Phase-5.
4. **Kebijakan Rollback Disiplin**:
   - Rollback langsung HANYA dijalankan jika **eksekusi file migrasi SQL gagal/error**.
   - Jika migrasi sukses terpasang namun **verifikasi/uji menghasilkan kegagalan**, **STOP dan investigasi** penyebabnya. **DILARANG menjalankan rollback secara membabi buta** tanpa analisis akar masalah.

---

## 2. DAFTAR BERKAS EKSEKUSI

| Kode | Tipe | Path Berkas Lokal |
|---|---|---|
| **MIG-01** | Phase 1 Migration | `database/migrations/001_phase1_database_foundation.sql` |
| **VER-01** | Phase 1 Verify | `database/verification/001_phase1_database_foundation_verify.sql` |
| **ROL-01** | Phase 1 Rollback | `database/rollback/001_phase1_database_foundation_rollback.sql` |
| **MIG-02** | Phase 2 Migration | `database/migrations/002_phase2_atomic_rpc_dispense.sql` |
| **VER-02** | Phase 2 Verify | `database/verification/002_phase2_atomic_rpc_dispense_verify.sql` |
| **ROL-02** | Phase 2 Rollback | `database/rollback/002_phase2_atomic_rpc_dispense_rollback.sql` |

---

## 3. URUTAN EKSEKUSI RUNBOOK (12 LANGKAH DETERMINISTIK)

### LANGKAH 1: Pre-Flight Schema Inspection
- **Tujuan**: Memastikan tabel dasar eksis sebelum modifikasi.
- **Kueri SQL**:
  ```sql
  SELECT table_name 
  FROM information_schema.tables 
  WHERE table_schema = 'public' 
    AND table_name IN ('customers', 'logs', 'warehouse_logs', 'transaction_audit_trail');
  ```
- **Hasil yang Diharapkan**: Mengembalikan 4 baris tabel di atas.
- **Stop Condition**: Jika ada tabel yang hilang, STOP segera.
- **Bukti yang Dicatat**: Screenshot / raw query output 4 nama tabel.

---

### LANGKAH 2: Historical Warehouse Mutation Anomaly Discovery
- **Tujuan**: Mendeteksi secara menyeluruh seluruh anomali data historis gudang:
  1. `type IS NULL`
  2. `type` tidak dikenal (di luar 8 tipe yang disetujui)
  3. `item IS NULL`
  4. `item` di luar `'beras'` dan `'gas'`
  5. `qty IS NULL` atau `qty <= 0`
- **Kueri SQL Agregasi**:
  ```sql
  SELECT type, item, count(*), min(qty), max(qty) 
  FROM warehouse_logs 
  GROUP BY type, item;
  ```
- **Kueri Deteksi Anomali Lengkap**:
  ```sql
  SELECT id, date, type, item, qty, ref 
  FROM warehouse_logs 
  WHERE type IS NULL 
     OR type NOT IN (
       'INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND',
       'GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN'
     )
     OR item IS NULL 
     OR item NOT IN ('beras', 'gas')
     OR qty IS NULL 
     OR qty <= 0;
  ```
- **Hasil yang Diharapkan**: Kueri deteksi anomali menghasilkan **tepat 0 baris**.
- **Stop Condition**: Jika ditemukan baris anomali ($> 0$), catat ID dan datanya. Remediasi data harus diselesaikan sebelum Langkah 11 (`VALIDATE CONSTRAINT`).
- **Bukti yang Dicatat**: Hasil kueri anomali (0 rows) dan rekapitulasi agregasi.

---

### LANGKAH 3: Deploy Phase-1 Migration
- **Berkas**: `database/migrations/001_phase1_database_foundation.sql`
- **Tindakan**: Buka Supabase SQL Editor, jalankan seluruh isi berkas **MIG-01**.
- **Hasil yang Diharapkan**: `Success. No rows returned`.
  - Kolom `request_id`, `operator_id`, `status` bertambah pada `logs`.
  - Data historis `logs.status` ter-backfill menjadi `'COMPLETED'`.
  - Indeks unik `uq_logs_request_id` dan trigger audit terpasang dengan `search_path = public`.
- **Stop Condition**: Error SQL syntax / lock timeout / constraint violation saat eksekusi DDL.
- **Rollback Decision Point 1**: HANYA jika eksekusi file migrasi ini melempar error DDL, jalankan **ROL-01** (`001_phase1_database_foundation_rollback.sql`) lalu hentikan deployment.
- **Bukti yang Dicatat**: Output status eksekusi SQL Editor dan durasi eksekusi.

---

### LANGKAH 4: Run Phase-1 Metadata Verification
- **Berkas**: `database/verification/001_phase1_database_foundation_verify.sql`
- **Tindakan**: Jalankan seluruh isi berkas **VER-01** (6 kueri assertion).
- **Hasil yang Diharapkan**:
  1. Kueri 1: Kolom `request_id`, `operator_id`, `status` muncul pada tabel `logs`.
  2. Kueri 2: Constraint `chk_logs_status_valid` terdaftar pada `pg_constraint`.
  3. Kueri 3: Indeks `uq_logs_request_id` terdaftar pada `pg_indexes`.
  4. Kueri 4: Indeks `idx_wh_log_id` terdaftar pada `warehouse_logs`.
  5. Kueri 5: Kolom `request_id`, `operator_id` muncul pada `transaction_audit_trail`.
  6. Kueri 6: `capture_audit_trail_trigger` berstatus `prosecdef = true` dan `proconfig = {search_path=public}`.
- **Stop Condition**: Salah satu dari ke-6 kueri tidak menghasilkan baris yang sesuai.
- **Kebijakan Investigasi**: Jika verifikasi metadata gagal, **STOP dan investigasi**. Jangan langsung rollback tanpa mengetahui penyebab diskrepansi katalog.
- **Bukti yang Dicatat**: Salinan hasil tabel dari ke-6 kueri assertion.

---

### LANGKAH 5: Run Phase-1 Behavioral Tests
- **Tujuan**: Menguji penegakan constraint status, trigger audit trail, dan penolakan duplikasi `request_id`.
- **Kueri Pengujian (Dry-Run)**:
  ```sql
  DO $$
  DECLARE
    v_test_id TEXT := 'LOG-TEST-P1-' || substr(md5(random()::text), 1, 6);
  BEGIN
    -- Uji 5.1: Tolak status tidak valid oleh chk_logs_status_valid
    BEGIN
      INSERT INTO logs (id, request_id, no_kk, nama, member_id, qty_beras, qty_gas, total_pcs, status)
      VALUES (v_test_id, 'REQ-P1-INV', '3201010101010001', 'UJI STATUS', 'M-01', 1, 0, 1, 'INVALID_STATUS');
      RAISE EXCEPTION 'TEST_FAILED: Status tidak valid seharusnya ditolak oleh chk_logs_status_valid!';
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'TEST_PASSED: Status INVALID_STATUS berhasil ditolak oleh check constraint.';
    END;

    -- Uji 5.2: Uji trigger audit trail pada INSERT logs
    INSERT INTO logs (id, request_id, no_kk, nama, member_id, qty_beras, qty_gas, total_pcs, status)
    VALUES (v_test_id, 'REQ-P1-VAL', '3201010101010001', 'UJI AUDIT', 'M-01', 1, 0, 1, 'COMPLETED');

    IF NOT EXISTS (SELECT 1 FROM transaction_audit_trail WHERE record_id = v_test_id AND action_type = 'INSERT') THEN
      RAISE EXCEPTION 'TEST_FAILED: Baris audit trail tidak terbuat saat INSERT logs!';
    ELSE
      RAISE NOTICE 'TEST_PASSED: Trigger audit trail berhasil mencatat aksi INSERT.';
    END IF;

    -- Uji 5.3: Buktikan penolakan duplikasi request_id oleh indeks uq_logs_request_id
    BEGIN
      INSERT INTO logs (id, request_id, no_kk, nama, member_id, qty_beras, qty_gas, total_pcs, status)
      VALUES (v_test_id || '-DUP', 'REQ-P1-VAL', '3201010101010001', 'UJI DUPLIKAT', 'M-01', 1, 0, 1, 'COMPLETED');
      RAISE EXCEPTION 'TEST_FAILED: Duplikasi request_id seharusnya ditolak oleh uq_logs_request_id!';
    EXCEPTION WHEN unique_violation THEN
      RAISE NOTICE 'TEST_PASSED: Duplikasi request_id REQ-P1-VAL berhasil ditolak oleh uq_logs_request_id.';
    END;

    -- Cleanup data uji langkah 5
    DELETE FROM logs WHERE id IN (v_test_id, v_test_id || '-DUP');
    DELETE FROM transaction_audit_trail WHERE record_id IN (v_test_id, v_test_id || '-DUP');
  END $$;
  ```
- **Hasil yang Diharapkan**: Output `NOTICE: TEST_PASSED` untuk ketiga assertion (Uji 5.1, 5.2, dan 5.3).
- **Stop Condition**: Muncul `TEST_FAILED`. STOP dan investigasi.
- **Bukti yang Dicatat**: Log NOTICE dari blok pengujian DO.

---

### LANGKAH 6: Deploy Phase-2 Migration
- **Berkas**: `database/migrations/002_phase2_atomic_rpc_dispense.sql`
- **Tindakan**: Buka SQL Editor, jalankan seluruh isi berkas **MIG-02**.
- **Hasil yang Diharapkan**: `Success. No rows returned`.
  - Kolom `is_void` bertambah pada `warehouse_logs`.
  - Constraint `chk_wh_type_valid` terpasang sebagai `NOT VALID`.
  - Indeks `idx_wh_balance_lookup` dan `idx_logs_nokk_date` terbuat.
  - Stored procedure `process_quota_dispense` terpasang dengan hak `GRANT EXECUTE TO anon, authenticated, service_role`.
- **Stop Condition**: Error kompilasi PL/pgSQL / permission denied saat eksekusi DDL.
- **Rollback Decision Point 2**: HANYA jika eksekusi file migrasi ini melempar error DDL, jalankan **ROL-02** (`002_phase2_atomic_rpc_dispense_rollback.sql`) lalu evaluasi.
- **Bukti yang Dicatat**: Pesan sukses eksekusi migrasi Phase-2.

---

### LANGKAH 7: Run Phase-2 Metadata Verification
- **Berkas**: `database/verification/002_phase2_atomic_rpc_dispense_verify.sql` (Bagian A)
- **Tindakan**: Jalankan Bagian A (Kueri A1 s/d A6).
- **Hasil yang Diharapkan**:
  - `process_quota_dispense` terdaftar di `pg_proc` dengan return type `jsonb`, `prosecdef = true`, `proconfig = {search_path=public}`.
  - Role `anon`, `authenticated`, dan `service_role` memiliki privilege `EXECUTE`.
  - Kolom `is_void` dan indeks `idx_wh_balance_lookup` terverifikasi di `warehouse_logs`.
  - Indeks `idx_logs_nokk_date` terverifikasi di `logs`.
- **Stop Condition**: Metadata tidak lengkap atau signature fungsi tidak cocok. STOP dan investigasi.
- **Bukti yang Dicatat**: Raw output tabel kueri A1 s/d A6.

---

### LANGKAH 8: Run Phase-2 Static Definition Inspection
- **Berkas**: `database/verification/002_phase2_atomic_rpc_dispense_verify.sql` (Bagian B)
- **Tindakan**: Jalankan kueri Bagian B.
- **Hasil yang Diharapkan**: Seluruh kolom boolean menghasilkan nilai `true`:
  - `has_req_lock = true`
  - `has_kk_lock = true`
  - `has_stock_beras_lock = true`
  - `has_stock_gas_lock = true`
  - `has_payload_conflict_check = true`
  - `has_correct_date_window = true`
  - `has_gr_batal_inbound = true`
  - `has_gr_refund_inbound = true`
  - `has_null_qty_rejection = true`
  - `has_null_date_rejection = true`
- **Stop Condition**: Salah satu indikator bernilai `false`. STOP dan investigasi.
- **Bukti yang Dicatat**: Tabel hasil inspeksi kode statis `pg_proc`.

---

### LANGKAH 9: Run Phase-2 Behavioral Runtime Tests
- **Tindakan**: Jalankan kueri Bagian C pada `002_phase2_atomic_rpc_dispense_verify.sql` serta skenario fungsional:
  1. **Uji Parameter NULL & Kuantitas Ilegal**:
     - C2.1: Panggil RPC dengan kuantitas `NULL` $\rightarrow$ ditolak (`P0007`).
     - C2.2: Panggil RPC dengan tanggal `NULL` $\rightarrow$ ditolak (`P0006`).
     - C2.3: Panggil RPC dengan nama kosong `   ` $\rightarrow$ ditolak (`P0006`).
  2. **Uji Idempotensi & Deteksi Konflik Payload**:
     - Panggil RPC dengan `REQ-STG-01` (KK: 3201010101010001, 1 Beras, 1 Gas). Respons: `SUCCESS`, `is_idempotent_replay: false`.
     - Panggil ulang persis sama dengan `REQ-STG-01`. Respons: `SUCCESS`, `is_idempotent_replay: true`.
     - Panggil ulang `REQ-STG-01` tetapi ubah qty menjadi 2 Beras. Respons: melempar exception `IDEMPOTENCY_CONFLICT` (`P0009`).
  3. **Uji Jendela Kuota Backdated**:
     - Transaksi bertanggal `p_tx_date = CURRENT_DATE - 5`. Pastikan baris masa depan (`date > p_tx_date`) dikecualikan dari perhitungan berkat filter `date <= p_tx_date`.
  4. **Uji Mutasi Gudang & Batas Kuota**:
     - Entri mutasi `GR-BATAL` (qty 5) menambah stok fisik gudang sebesar **tepat +5 sak**, tetapi **TIDAK** memulihkan kuota warga.
     - Entri mutasi `GR-REFUND` (qty 3) menambah stok fisik gudang sebesar **tepat +3 tabung**, tetapi **TIDAK** memulihkan kuota warga.
- **Hasil yang Diharapkan**: Seluruh assertion lolos sesuai matriks Behavioral Test Plan.
- **Stop Condition**: Muncul inkonsistensi saldo stok atau bypass kuota. STOP dan investigasi.
- **Bukti yang Dicatat**: Output JSON response RPC dari tiap skenario uji.

---

### LANGKAH 10: Run Two-Session Concurrency Tests
- **Peringatan Metodologis Penting**:
  > [!WARNING]
  > **Dua tab SQL Editor di browser yang diklik secara manual TIDAK MEMADAI sebagai bukti konkurensi sesungguhnya (*true concurrency*)** karena terdapat latensi reaksi manusia (*human clicking latency* 100–300 ms).  
  > Untuk pembuktian konkurensi yang valid, gunakan **dua sesi PostgreSQL independen terpisah**, misalnya melalui:
  > - Dua terminal `psql` independen,
  > - Dua koneksi di DBeaver / pgAdmin, ATAU
  > - Runner script Node.js berkoneksi ganda (`pg`) yang menembak RPC menggunakan `Promise.all()`.
- **Skenario Uji Konkurensi**:
  - Siapkan stok gudang Beras tersisa tepat **1 sak**.
  - Sesi 1 (KK-001):
    ```sql
    SELECT process_quota_dispense('REQ-CONC-01', '3201010101010001', 'WARGA 1', 'M-01', 1, 0);
    ```
  - Sesi 2 (KK-002, No KK berbeda memperebutkan sisa 1 sak Beras yang sama):
    ```sql
    SELECT process_quota_dispense('REQ-CONC-02', '3201010101010002', 'WARGA 2', 'M-02', 1, 0);
    ```
  - Jalankan kedua kueri secara simultan.
- **Hasil yang Diharapkan**:
  - Tepat satu sesi berhasil (`SUCCESS`).
  - Sesi lainnya mengantre pada `STOCK:BERAS` lock dan ditolak dengan exception `STOCK_DEFICIT` (`P0003`).
  - Stok fisik akhir di `warehouse_logs` bernilai tepat `0` (tidak pernah minus/overselling).
- **Stop Condition**: Keduanya berhasil (menghasilkan stok minus $-1$) atau terjadi deadlock. STOP dan investigasi.
- **Bukti yang Dicatat**: Output JSON dari Sesi 1 dan pesan error dari Sesi 2 beserta saldo akhir stok gudang.

---

### LANGKAH 11: Validate `chk_wh_type_valid` Constraint
- **Prasyarat Mutlak**: Kueri anomali pada Langkah 2 harus telah terbukti menghasilkan **0 baris**.
- **Tindakan**: Eksekusi validasi fisik constraint:
  ```sql
  ALTER TABLE warehouse_logs VALIDATE CONSTRAINT chk_wh_type_valid;
  ```
- **Hasil yang Diharapkan**: `Success. No rows returned`.
- **Verifikasi**: Jalankan kueri:
  ```sql
  SELECT conname, convalidated 
  FROM pg_constraint 
  WHERE conname = 'chk_wh_type_valid';
  ```
  Kolom `convalidated` bernilai `true`.
- **Stop Condition**: Error validasi karena ada baris historis yang melanggar. Jangan jalankan rollback; biarkan constraint tetap `NOT VALID` sampai data diperbaiki.
- **Bukti yang Dicatat**: Nilai `convalidated = true` pada katalog `pg_constraint`.

---

### LANGKAH 12: Rollback Drill & Synthetic Data Cleanup Procedure

#### A. Prosedur Pembersihan Data Uji Sintetis (Hierarchical Cleanup)
Untuk menjaga integritas relasional, pembersihan data uji sintetis pada Langkah 5, 9, dan 10 **WAJIB mengikuti urutan hirarki berikut**:
1. **Catat ID log transaksi uji ke temporary table**:
   ```sql
   CREATE TEMP TABLE tmp_test_logs AS
   SELECT id, request_id 
   FROM logs 
   WHERE request_id LIKE 'REQ-TEST-%' 
      OR request_id LIKE 'REQ-STG-%' 
      OR request_id LIKE 'REQ-CONC-%'
      OR id LIKE 'LOG-TEST-%';
   ```
2. **Hapus `warehouse_logs` TERLEBIH DAHULU (Child records)**:
   ```sql
   DELETE FROM warehouse_logs 
   WHERE log_id IN (SELECT id FROM tmp_test_logs)
      OR log_id LIKE 'LOG-TEST-%' 
      OR ref LIKE '%WARGA 1%' 
      OR ref LIKE '%WARGA 2%'
      OR ref LIKE '%UJI %';
   ```
3. **Hapus `logs` KEDUA (Parent records)**:
   ```sql
   DELETE FROM logs 
   WHERE id IN (SELECT id FROM tmp_test_logs);
   ```
4. **Hapus `transaction_audit_trail` TERAKHIR (Audit trail records)**:
   ```sql
   DELETE FROM transaction_audit_trail 
   WHERE request_id IN (SELECT request_id FROM tmp_test_logs WHERE request_id IS NOT NULL)
      OR record_id IN (SELECT id FROM tmp_test_logs)
      OR request_id LIKE 'REQ-TEST-%' 
      OR request_id LIKE 'REQ-STG-%' 
      OR request_id LIKE 'REQ-CONC-%'
      OR record_id LIKE 'LOG-TEST-%';

   DROP TABLE IF EXISTS tmp_test_logs;
   ```
*Hasil Pembersihan*: Basis data Staging kembali bersih tanpa data sampah pengujian.

#### B. Prosedur Uji Rollback Drill (Pada Disposable/Transaction-Safe Environment)
Jika Anda menguji kemampuan rollback pada instans staging sementara atau di dalam blok transaksi uji:
1. Jalankan **ROL-02** (`002_phase2_atomic_rpc_dispense_rollback.sql`).
2. Verifikasi fungsi `process_quota_dispense` terhapus dari `pg_proc`.
3. Jalankan **ROL-01** (`001_phase1_database_foundation_rollback.sql`).
4. Verifikasi trigger dan constraint terlepas tanpa menghapus kolom data fisik.

---

## 4. MATRIKS KEBIJAKAN ROLLBACK (STRICT DISCIPLINARY POLICY)

| Kondisi Kejadian | Kebijakan Tindakan | Berkas Terkait | Penjelasan Kebijakan |
|---|---|---|---|
| **Eksekusi file migrasi Phase-1 Gagal** | **Rollback Otomatis** | `001_phase1_database_foundation_rollback.sql` | DDL gagal dieksekusi; batalkan perubahan partial. |
| **Verifikasi / Uji Phase-1 Gagal** | **STOP & INVESTIGASI** | *(Jangan Rollback)* | DDL sukses terpasang; cari tahu penyebab diskrepansi verifikasi sebelum bertindak. |
| **Eksekusi file migrasi Phase-2 Gagal** | **Rollback Otomatis** | `002_phase2_atomic_rpc_dispense_rollback.sql` | Stored procedure/indeks gagal; kembalikan ke Phase 1. |
| **Verifikasi / Uji Phase-2 Gagal** | **STOP & INVESTIGASI** | *(Jangan Rollback)* | DDL sukses terpasang; evaluasi data/konfigurasi tanpa menghapus fungsi secara gegabah. |
| **Validasi Constraint Langkah 11 Gagal** | **ISOLASI DATA** | *(Jangan Rollback)* | Constraint tetap berstatus `NOT VALID`; perbaiki data historis yang melanggar. |

---

## 5. EVIDENCE CHECKLIST RESMI (YANG WAJIB DIKUMPULKAN OWNER)

Setiap bukti eksekusi yang dikumpulkan dari Supabase Staging wajib memuat elemen-elemen berikut:

- [ ] **SQL Execution Timestamp**: Waktu pasti eksekusi (format ISO 8601 / zona waktu lokal).
- [ ] **Target Supabase Project Reference**: Project ref staging (misal `xyzcompany-staging`).
- [ ] **Raw Query Output**: Teks tabel / JSON asli yang dihasilkan PostgreSQL tanpa modifikasi.
- [ ] **SQLSTATE / Error Code**: Kode error jika terjadi kegagalan (misal `P0001`, `P0009`, `23505`).
- [ ] **Affected Row Count**: Jumlah baris terpengaruh pada setiap perintah `INSERT`, `UPDATE`, `DELETE`.
- [ ] **Before/After Transaction Counts**: Jumlah baris tabel `logs` sebelum dan sesudah uji dijalankan.
- [ ] **Before/After Warehouse Balance**: Saldo fisik stok Beras dan Gas sebelum dan sesudah uji dijalankan.
- [ ] **Cleanup Result**: Konfirmasi bahwa seluruh baris data sintetis pengujian telah terhapus sempurna.
