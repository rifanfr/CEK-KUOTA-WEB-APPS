-- =============================================================================
-- PHASE 4 MIGRATION 004: ACL CLEANUP, DEFAULT PRIVILEGES & FEED FOUNDATIONS
-- Project: Catat Kuota KK (Staging: evexaeyryfayfbffzzhh)
-- Baseline: Phase 4.2.2 Corrected Blueprint (F-01, C-01, C-02, C-07)
-- PostgreSQL Target: 17.12 (UTF8)
-- Preserves: Historical migrations 000-003, Expand SELECT on customers/logs/wh
-- =============================================================================

-- 0. PRE-MIGRATION TARGET & BASELINE ASSERTIONS
DO $$
DECLARE
  v_missing INT;
  v_dup_p4  INT;
BEGIN
  IF pg_catalog.current_database() <> 'postgres' THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: expected database postgres, got %', pg_catalog.current_database();
  END IF;

  IF CURRENT_USER <> 'postgres' THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: migration 004 must run as postgres, got %', CURRENT_USER;
  END IF;

  SELECT count(*) INTO v_missing
  FROM (VALUES ('customers'), ('logs'), ('warehouse_logs'), ('transaction_audit_trail'), ('customer_registration_requests')) AS req(tbl)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = req.tbl AND c.relkind = 'r'
  );
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: missing % baseline table(s) in schema public', v_missing;
  END IF;

  SELECT count(*) INTO v_dup_p4
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN ('change_feed_tracker', 'operational_change_feed', 'offline_reconciliation_conflicts');
  IF v_dup_p4 > 0 THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: Phase 4 feed/reconciliation objects already exist in public';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'private_internal') THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: schema private_internal already exists';
  END IF;
END
$$;


-- =============================================================================
-- 1. PART A (F-01 MANDATORY PRE-CREATION CLEANUP): DEFAULT ACLs & Dxtm REMOVAL
-- =============================================================================
-- 1a. Cabut hak default postgres di public sebelum membuat objek baru apa pun
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;

-- 1b. Cabut SELURUH hak langsung (termasuk Dxtm) dari service_role & PUBLIC
--     pada tabel internal audit & idempotensi (selaras baseline svc_sel=false)
REVOKE ALL ON TABLE public.transaction_audit_trail FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.customer_registration_requests FROM PUBLIC, anon, authenticated, service_role;

-- 1c. Cabut seluruh Dxtm & DML langsung dari service_role & PUBLIC pada 3 tabel operasional,
--     serta pastikan anon/authenticated hanya mempertahankan SELECT selama Expand (pra-007)
REVOKE ALL ON TABLE public.customers, public.logs, public.warehouse_logs FROM PUBLIC, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public.customers, public.logs, public.warehouse_logs
  FROM anon, authenticated;


-- =============================================================================
-- 2. PART B: PRIVATE SCHEMA & PHASE 4 INTERNAL / CHANGE-FEED FOUNDATIONS
-- =============================================================================
-- 2a. Skema internal tertutup (tidak diekspos PostgREST)
CREATE SCHEMA private_internal AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA private_internal FROM PUBLIC, anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA private_internal
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA private_internal
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA private_internal
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;

-- 2b. Singleton commit-order tracker (populated-DB seed: 1, 2, 1 per C-07)
CREATE TABLE public.change_feed_tracker (
  singleton_id        INT PRIMARY KEY DEFAULT 1 CHECK (singleton_id = 1),
  last_committed_seq  BIGINT NOT NULL CHECK (last_committed_seq >= 0),
  min_retained_seq    BIGINT NOT NULL CHECK (min_retained_seq >= 1),
  feed_epoch          BIGINT NOT NULL DEFAULT 1 CHECK (feed_epoch >= 1),
  last_pruned_at      TIMESTAMPTZ,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

ALTER TABLE public.change_feed_tracker ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.change_feed_tracker FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.change_feed_tracker IS
  'Singleton commit-ordered high-water mark, contiguous retention floor, and epoch counter for operational_change_feed.';

INSERT INTO public.change_feed_tracker (singleton_id, last_committed_seq, min_retained_seq, feed_epoch)
VALUES (1, 1, 2, 1);

-- 2c. Commit-ordered change feed table (zero BIGSERIAL, zero FKs)
CREATE TABLE public.operational_change_feed (
  change_seq   BIGINT PRIMARY KEY CHECK (change_seq >= 1),
  table_name   TEXT NOT NULL CHECK (table_name IN ('customers', 'logs', 'warehouse_logs')),
  record_id    TEXT NOT NULL,
  action_type  TEXT NOT NULL CHECK (action_type IN ('INSERT', 'UPDATE', 'VOID', 'TOMBSTONE', 'DELETE')),
  record_data  JSONB NOT NULL,
  recorded_at  TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE INDEX idx_ocf_recorded_at ON public.operational_change_feed (recorded_at, change_seq);
CREATE INDEX idx_ocf_table_seq ON public.operational_change_feed (table_name, change_seq);

ALTER TABLE public.operational_change_feed ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.operational_change_feed FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.operational_change_feed IS
  'Commit-ordered delta event log written exclusively at COMMIT by deferred triggers and pruned via prune_operational_change_feed_v4.';

-- 2d. Eskalasi konflik rekonsiliasi fisik offline
CREATE TABLE public.offline_reconciliation_conflicts (
  id                  UUID PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  request_id          TEXT NOT NULL UNIQUE,
  operator_uid        TEXT NOT NULL,
  no_kk               TEXT NOT NULL CHECK (no_kk ~ '^[0-9]{16}$'),
  attempted_qty_beras INT NOT NULL CHECK (attempted_qty_beras >= 0),
  attempted_qty_gas   INT NOT NULL CHECK (attempted_qty_gas >= 0),
  conflict_code       TEXT NOT NULL CHECK (conflict_code IN (
    'P0001', 'P0002', 'P0003', 'P0004', 'P0014', 'PHYSICAL_OVERDISPENSE_RECONCILIATION'
  )),
  local_handover_at   TIMESTAMPTZ NOT NULL,
  client_payload      JSONB NOT NULL,
  resolution_status   TEXT NOT NULL DEFAULT 'OPEN' CHECK (resolution_status IN ('OPEN', 'RESOLVED', 'DISMISSED')),
  resolved_by         TEXT,
  resolved_at         TIMESTAMPTZ,
  resolution_note     TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE INDEX idx_orc_status_created ON public.offline_reconciliation_conflicts (resolution_status, created_at DESC);
CREATE INDEX idx_orc_nokk ON public.offline_reconciliation_conflicts (no_kk, created_at DESC);

ALTER TABLE public.offline_reconciliation_conflicts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.offline_reconciliation_conflicts FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.offline_reconciliation_conflicts IS
  'Server escalation queue for offline physical handover conflicts detected during outbox replay.';


-- =============================================================================
-- 3. TRANSACTIONAL POST-MIGRATION CATALOG & ACL ASSERTIONS (C-01 / C-02 / C-07)
-- =============================================================================
DO $$
DECLARE
  v_bad_defacl  INT;
  v_bad_obj_acl INT;
  v_tbl         TEXT;
  v_priv        TEXT;
  v_pol_count   INT;
  v_tracker_cnt INT;
  v_last_seq    BIGINT;
  v_min_seq     BIGINT;
  v_epoch       BIGINT;
BEGIN
  -- 3.1 Verify pg_default_acl for role postgres in public & private_internal grants 0 privileges to PUBLIC/API roles
  SELECT count(*) INTO v_bad_defacl
  FROM pg_catalog.pg_default_acl d
  LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
  CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) AS a
  WHERE d.defaclrole = 'postgres'::pg_catalog.regrole
    AND n.nspname IN ('public', 'private_internal')
    AND a.grantee IN (
      0::pg_catalog.oid,
      'anon'::pg_catalog.regrole,
      'authenticated'::pg_catalog.regrole,
      'service_role'::pg_catalog.regrole
    );
  IF v_bad_defacl > 0 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: pg_default_acl for postgres still exposes % grant(s) to PUBLIC/anon/authenticated/service_role', v_bad_defacl;
  END IF;

  -- 3.2 Verify Category 1 (Expand SELECT preserved for anon/authenticated; 0 DML/Dxtm; 0 service_role/PUBLIC)
  FOREACH v_tbl IN ARRAY ARRAY['public.customers', 'public.logs', 'public.warehouse_logs'] LOOP
    IF NOT pg_catalog.has_table_privilege('anon', v_tbl, 'SELECT') OR
       NOT pg_catalog.has_table_privilege('authenticated', v_tbl, 'SELECT') THEN
      RAISE EXCEPTION 'ASSERT_FAILED: Expand SELECT missing on % for anon/authenticated', v_tbl;
    END IF;

    FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'] LOOP
      IF pg_catalog.has_table_privilege('anon', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('authenticated', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('service_role', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('public', v_tbl, v_priv) THEN
        RAISE EXCEPTION 'ASSERT_FAILED: Forbidden privilege % held on %', v_priv, v_tbl;
      END IF;
    END LOOP;

    IF pg_catalog.has_table_privilege('service_role', v_tbl, 'SELECT') OR
       pg_catalog.has_table_privilege('public', v_tbl, 'SELECT') THEN
      RAISE EXCEPTION 'ASSERT_FAILED: SELECT leaked to service_role or PUBLIC on %', v_tbl;
    END IF;
  END LOOP;

  -- 3.3 Verify Category 3 tables (ALL 8 flags = false for PUBLIC, anon, authenticated, service_role)
  FOREACH v_tbl IN ARRAY ARRAY[
    'public.transaction_audit_trail',
    'public.customer_registration_requests',
    'public.change_feed_tracker',
    'public.operational_change_feed',
    'public.offline_reconciliation_conflicts'
  ] LOOP
    FOREACH v_priv IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'] LOOP
      IF pg_catalog.has_table_privilege('public', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('anon', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('authenticated', v_tbl, v_priv) OR
         pg_catalog.has_table_privilege('service_role', v_tbl, v_priv) THEN
        RAISE EXCEPTION 'ASSERT_FAILED: Internal table % exposes % to disallowed role', v_tbl, v_priv;
      END IF;
    END LOOP;
  END LOOP;

  -- 3.4 Guard against any unexpected non-catalog table/owner in public/private_internal having client/API DML or Dxtm
  SELECT count(*) INTO v_bad_obj_acl
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl, pg_catalog.acldefault(
    CASE c.relkind WHEN 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner
  ))) AS a
  WHERE n.nspname IN ('public', 'private_internal')
    AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
    AND a.grantee IN (
      0::pg_catalog.oid,
      'anon'::pg_catalog.regrole,
      'authenticated'::pg_catalog.regrole,
      'service_role'::pg_catalog.regrole
    )
    AND NOT (
      n.nspname = 'public'
      AND c.relname IN ('customers', 'logs', 'warehouse_logs')
      AND a.grantee IN ('anon'::pg_catalog.regrole, 'authenticated'::pg_catalog.regrole)
      AND a.privilege_type = 'SELECT'
    );
  IF v_bad_obj_acl > 0 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Detected % unexpected table/sequence ACL entry across public/private_internal', v_bad_obj_acl;
  END IF;

  -- 3.5 Verify Category 5 private_internal schema isolation & RLS on all tables
  IF pg_catalog.has_schema_privilege('public', 'private_internal', 'USAGE') OR
     pg_catalog.has_schema_privilege('anon', 'private_internal', 'USAGE') OR
     pg_catalog.has_schema_privilege('authenticated', 'private_internal', 'USAGE') OR
     pg_catalog.has_schema_privilege('service_role', 'private_internal', 'USAGE') THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Schema private_internal USAGE exposed to PUBLIC/API roles';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND (NOT c.relrowsecurity OR c.relforcerowsecurity)
  ) THEN
    RAISE EXCEPTION 'ASSERT_FAILED: All public tables must have relrowsecurity=true and relforcerowsecurity=false';
  END IF;

  -- 3.6 Verify Expand read policies remain intact & tracker seed matches (1, 2, 1)
  SELECT count(*) INTO v_pol_count
  FROM pg_catalog.pg_policies
  WHERE schemaname = 'public'
    AND policyname IN ('Staging read customers', 'Staging read logs', 'Staging read warehouse_logs');
  IF v_pol_count <> 3 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Expected 3 Staging read Expand policies, found %', v_pol_count;
  END IF;

  SELECT count(*), min(last_committed_seq), min(min_retained_seq), min(feed_epoch)
  INTO v_tracker_cnt, v_last_seq, v_min_seq, v_epoch
  FROM public.change_feed_tracker;
  IF v_tracker_cnt <> 1 OR v_last_seq <> 1 OR v_min_seq <> 2 OR v_epoch <> 1 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Invalid tracker initialization (cnt=%, last=%, min=%, epoch=%)',
      v_tracker_cnt, v_last_seq, v_min_seq, v_epoch;
  END IF;
END
$$;
