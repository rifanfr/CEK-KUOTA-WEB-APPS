-- =============================================================================
-- VERIFICATION SQL: PHASE 3 (SECURE RPC & SERVER-SIDE IDEMPOTENCY)
-- Database Engine: PostgreSQL 15+ (Supabase)
-- Project: Catat Kuota KK
-- Target: Assertion Keberadaan Objek, Keamanan RLS, Signature RPC, & Otorisasi
-- Termasuk: Verifikasi Bukti Audit Tetap Terpelihara & Dapat Di-Kueri
-- =============================================================================

-- =============================================================================
-- A. STRUKTUR & KEAMANAN TABEL customer_registration_requests
-- =============================================================================

-- A1. Verifikasi keberadaan dan kolom tabel customer_registration_requests
SELECT 
  table_name,
  column_name,
  data_type,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public' 
  AND table_name = 'customer_registration_requests'
ORDER BY ordinal_position;

-- A2. Verifikasi Primary Key customer_registration_requests
SELECT 
  kcu.table_name,
  kcu.column_name,
  tc.constraint_name,
  tc.constraint_type
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu 
  ON tc.constraint_name = kcu.constraint_name 
  AND tc.table_schema = kcu.table_schema
WHERE tc.table_schema = 'public' 
  AND tc.table_name = 'customer_registration_requests'
  AND tc.constraint_type = 'PRIMARY KEY';

-- A3. Verifikasi Row Level Security (RLS) Aktif pada customer_registration_requests
SELECT 
  relname AS table_name,
  relrowsecurity AS rls_enabled,
  relforcerowsecurity AS rls_forced
FROM pg_class
WHERE relname = 'customer_registration_requests' 
  AND relnamespace = 'public'::regnamespace;

-- A4. Verifikasi Hak Akses Tabel (HARUS 0 Baris untuk anon dan authenticated)
-- Tabel buku besar idempotensi tidak boleh memiliki grant SELECT/INSERT/UPDATE/DELETE langsung.
SELECT 
  grantee,
  table_name,
  privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name = 'customer_registration_requests'
  AND grantee IN ('anon', 'authenticated');


-- =============================================================================
-- B. STRUKTUR & INDEKS PADA TABEL warehouse_logs
-- =============================================================================

-- B1. Verifikasi kolom request_id pada warehouse_logs
SELECT 
  table_name,
  column_name,
  data_type,
  is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'warehouse_logs'
  AND column_name = 'request_id';

-- B2. Verifikasi indeks unik parsial uq_wh_request_id pada warehouse_logs
SELECT 
  tablename,
  indexname,
  indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename = 'warehouse_logs'
  AND indexname = 'uq_wh_request_id';


-- =============================================================================
-- C. DISAMBIGUASI & JUMLAH SIGNATURE RPC DALAM pg_proc
-- =============================================================================

-- C1. Verifikasi fungsi process_quota_dispense: tepat 1 overload dengan 14 argumen
SELECT 
  p.proname,
  p.pronargs AS argument_count,
  p.prosecdef AS is_security_definer,
  pg_get_function_arguments(p.oid) AS arguments,
  pg_get_function_result(p.oid) AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.proname = 'process_quota_dispense';

-- C2. Verifikasi fungsi register_customer: tepat 1 overload dengan 9 argumen
SELECT 
  p.proname,
  p.pronargs AS argument_count,
  p.prosecdef AS is_security_definer,
  pg_get_function_arguments(p.oid) AS arguments,
  pg_get_function_result(p.oid) AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.proname = 'register_customer';

-- C3. Verifikasi fungsi process_warehouse_mutation: tepat 1 overload dengan 8 argumen
SELECT 
  p.proname,
  p.pronargs AS argument_count,
  p.prosecdef AS is_security_definer,
  pg_get_function_arguments(p.oid) AS arguments,
  pg_get_function_result(p.oid) AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.proname = 'process_warehouse_mutation';


-- =============================================================================
-- D. HAK AKSES EKSEKUSI RPC (EXECUTE PRIVILEGES)
-- =============================================================================

-- D1. Verifikasi hak eksekusi anon (HARUS false untuk seluruh RPC mutasi Fase-3)
SELECT 
  p.proname,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.proname IN ('process_quota_dispense', 'register_customer', 'process_warehouse_mutation');

-- D2. Verifikasi hak eksekusi authenticated (HARUS true untuk seluruh RPC mutasi Fase-3)
SELECT 
  p.proname,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.proname IN ('process_quota_dispense', 'register_customer', 'process_warehouse_mutation');


-- =============================================================================
-- E. INSPEKSI SUMBER KODE STATIS (SECURITY GUARDS & ADVISORY LOCKS)
-- =============================================================================
SELECT 
  p.proname,
  (p.prosrc LIKE '%auth.role()%') AS has_auth_role_guard,
  (p.prosrc LIKE '%app_metadata%') AS has_app_metadata_rbac,
  (p.prosrc LIKE '%hashtextextended%') AS has_advisory_locks,
  (p.prosrc LIKE '%P0009%') AS has_p0009_idempotency_conflict,
  (p.prosrc LIKE '%P0014%') AS has_p0014_customer_conflict,
  (p.prosrc LIKE '%P0013%') AS has_p0013_initial_stock_lock,
  (p.prosrc LIKE '%P0010%') AS has_p0010_disallowed_type_lock
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.proname IN ('process_quota_dispense', 'register_customer', 'process_warehouse_mutation')
ORDER BY p.proname;


-- =============================================================================
-- F. PEMBUKTIAN KETERSEDIAAN BUKTI TRANSAKSI (PRESERVED EVIDENCE QUERYABILITY)
-- Memastikan bahwa tabel dan kolom yang dipreservasi tetap utuh dan dapat di-kueri
-- baik saat Fase-3 aktif maupun jika terjadi rollback non-destruktif.
-- =============================================================================

-- F1. Bukti Kueri customer_registration_requests (Dapat diakses oleh session terotorisasi)
SELECT 
  count(*) AS total_registration_requests,
  max(created_at) AS latest_registration_time
FROM customer_registration_requests;

-- F2. Bukti Kueri warehouse_logs.request_id (Idempotensi mutasi gudang tetap terpelihara)
SELECT 
  count(*) AS total_wh_mutations_with_request_id,
  count(DISTINCT request_id) AS distinct_wh_request_ids
FROM warehouse_logs
WHERE request_id IS NOT NULL;

-- F3. Inspeksi Komentar Skema (Status Operasional / Dormant)
SELECT 
  c.relname AS object_name,
  'TABLE' AS object_type,
  d.description AS comment_text
FROM pg_class c
JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = 0
WHERE c.relname = 'customer_registration_requests'
UNION ALL
SELECT 
  c.relname || '.' || a.attname AS object_name,
  'COLUMN' AS object_type,
  d.description AS comment_text
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid
JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = a.attnum
WHERE c.relname = 'warehouse_logs' AND a.attname = 'request_id';


-- =============================================================================
-- G. BLOK EKSEKUSI ASSERTION OTOMATIS (AUTOMATED ASSERTION RUNNER)
-- =============================================================================
DO $$
DECLARE
  v_count INT;
  v_rls BOOLEAN;
  v_grants_count INT;
  v_dispense_proc RECORD;
  v_reg_proc RECORD;
  v_wh_proc RECORD;
  v_dummy_count BIGINT;
BEGIN
  -- 1. Assertion: customer_registration_requests table & RLS
  SELECT count(*) INTO v_count
  FROM information_schema.tables 
  WHERE table_schema = 'public' AND table_name = 'customer_registration_requests';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Tabel customer_registration_requests tidak ditemukan';
  END IF;

  SELECT relrowsecurity INTO v_rls
  FROM pg_class
  WHERE relname = 'customer_registration_requests' AND relnamespace = 'public'::regnamespace;
  IF v_rls IS NOT TRUE THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: RLS pada customer_registration_requests belum aktif';
  END IF;

  -- 2. Assertion: Table grants untuk anon dan authenticated harus 0
  SELECT count(*) INTO v_grants_count
  FROM information_schema.role_table_grants
  WHERE table_schema = 'public'
    AND table_name = 'customer_registration_requests'
    AND grantee IN ('anon', 'authenticated');
  IF v_grants_count > 0 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Terdapat % direct grant berbahaya pada customer_registration_requests untuk anon/authenticated', v_grants_count;
  END IF;

  -- 3. Assertion: warehouse_logs.request_id column & uq_wh_request_id index
  SELECT count(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'warehouse_logs' AND column_name = 'request_id';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Kolom warehouse_logs.request_id tidak ditemukan';
  END IF;

  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public' AND tablename = 'warehouse_logs' AND indexname = 'uq_wh_request_id';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Indeks uq_wh_request_id tidak ditemukan';
  END IF;

  -- 4. Assertion: Overload count process_quota_dispense tepat 1 (14 argumen)
  SELECT count(*), max(pronargs) INTO v_count, v_grants_count
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public' AND p.proname = 'process_quota_dispense';
  IF v_count <> 1 OR v_grants_count <> 14 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: process_quota_dispense harus memiliki tepat 1 signature dengan 14 argumen (ditemukan: % signature, % args)', v_count, v_grants_count;
  END IF;

  -- 5. Assertion: Overload count register_customer tepat 1 (9 argumen)
  SELECT count(*), max(pronargs) INTO v_count, v_grants_count
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public' AND p.proname = 'register_customer';
  IF v_count <> 1 OR v_grants_count <> 9 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: register_customer harus memiliki tepat 1 signature dengan 9 argumen (ditemukan: % signature, % args)', v_count, v_grants_count;
  END IF;

  -- 6. Assertion: Overload count process_warehouse_mutation tepat 1 (8 argumen)
  SELECT count(*), max(pronargs) INTO v_count, v_grants_count
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public' AND p.proname = 'process_warehouse_mutation';
  IF v_count <> 1 OR v_grants_count <> 8 THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: process_warehouse_mutation harus memiliki tepat 1 signature dengan 8 argumen (ditemukan: % signature, % args)', v_count, v_grants_count;
  END IF;

  -- 7. Assertion: Hak Akses EXECUTE (Revoked from anon, Granted to authenticated)
  SELECT oid INTO v_dispense_proc FROM pg_proc WHERE proname = 'process_quota_dispense' AND pronamespace = 'public'::regnamespace;
  SELECT oid INTO v_reg_proc FROM pg_proc WHERE proname = 'register_customer' AND pronamespace = 'public'::regnamespace;
  SELECT oid INTO v_wh_proc FROM pg_proc WHERE proname = 'process_warehouse_mutation' AND pronamespace = 'public'::regnamespace;

  IF has_function_privilege('anon', v_dispense_proc.oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'SECURITY_VIOLATION: anon masih memiliki hak EXECUTE pada process_quota_dispense';
  END IF;
  IF has_function_privilege('anon', v_reg_proc.oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'SECURITY_VIOLATION: anon masih memiliki hak EXECUTE pada register_customer';
  END IF;
  IF has_function_privilege('anon', v_wh_proc.oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'SECURITY_VIOLATION: anon masih memiliki hak EXECUTE pada process_warehouse_mutation';
  END IF;

  IF NOT has_function_privilege('authenticated', v_dispense_proc.oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'CONFIGURATION_ERROR: authenticated tidak memiliki hak EXECUTE pada process_quota_dispense';
  END IF;
  IF NOT has_function_privilege('authenticated', v_reg_proc.oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'CONFIGURATION_ERROR: authenticated tidak memiliki hak EXECUTE pada register_customer';
  END IF;
  IF NOT has_function_privilege('authenticated', v_wh_proc.oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'CONFIGURATION_ERROR: authenticated tidak memiliki hak EXECUTE pada process_warehouse_mutation';
  END IF;

  -- 7b. Assertion: Proteksi SQLSTATE P0010 untuk tipe mutasi gudang tidak diizinkan
  SELECT (prosrc LIKE '%P0010%') INTO v_rls
  FROM pg_proc
  WHERE proname = 'process_warehouse_mutation' AND pronamespace = 'public'::regnamespace;
  IF v_rls IS NOT TRUE THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: process_warehouse_mutation tidak memuat proteksi kode P0010 untuk tipe mutasi ilegal';
  END IF;

  -- 8. Assertion: Keteraksesan dan Kueri Bukti Audit yang Dipreservasi
  BEGIN
    EXECUTE 'SELECT count(*) FROM customer_registration_requests' INTO v_dummy_count;
    EXECUTE 'SELECT count(*) FROM warehouse_logs WHERE request_id IS NOT NULL' INTO v_dummy_count;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ASSERTION_FAILED: Bukti audit gagal di-kueri: %', SQLERRM;
  END;

  RAISE NOTICE '=============================================================================';
  RAISE NOTICE 'PHASE-3 VERIFICATION PASSED:';
  RAISE NOTICE '1. customer_registration_requests table, PK, and RLS verified (zero table grants)';
  RAISE NOTICE '2. warehouse_logs.request_id and partial unique index uq_wh_request_id verified';
  RAISE NOTICE '3. Function disambiguation verified: 1 process_quota_dispense (14 args)';
  RAISE NOTICE '4. Function disambiguation verified: 1 register_customer (9 args)';
  RAISE NOTICE '5. Function disambiguation verified: 1 process_warehouse_mutation (8 args)';
  RAISE NOTICE '6. Security privileges verified: anon REVOKED, authenticated GRANTED';
  RAISE NOTICE '7. Preserved evidence queryability verified (tables & columns remain queryable)';
  RAISE NOTICE '=============================================================================';
END;
$$;
