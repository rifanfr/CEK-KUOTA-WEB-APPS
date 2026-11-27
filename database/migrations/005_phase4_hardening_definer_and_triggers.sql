-- =============================================================================
-- PHASE 4 MIGRATION 005: SECURITY DEFINER HARDENING, AUDIT INTEGRITY & DEFERRED FEED TRIGGERS
-- Project: Catat Kuota KK (Staging: evexaeyryfayfbffzzhh)
-- Baseline: Phase 4.2.2 Corrected Blueprint (F-02, F-03, F-05, C-02, C-03, C-05)
-- Depends on: 004_phase4_acl_cleanup_and_feed_tables.sql
-- =============================================================================

-- 0. PRE-MIGRATION ASSERTIONS
DO $$
BEGIN
  IF pg_catalog.current_database() <> 'postgres' THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: expected database postgres, got %', pg_catalog.current_database();
  END IF;

  IF CURRENT_USER <> 'postgres' THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: migration 005 must run as postgres, got %', CURRENT_USER;
  END IF;

  IF pg_catalog.getdatabaseencoding() <> 'UTF8' THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: UTF8 encoding required, got %', pg_catalog.getdatabaseencoding();
  END IF;

  IF NOT (pg_catalog.normalize('Se' || pg_catalog.chr(769), 'NFC') = pg_catalog.normalize('S' || pg_catalog.chr(233), 'NFC')) THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: pg_catalog.normalize(..., ''NFC'') check failed';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'private_internal') OR
     NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname = 'change_feed_tracker') OR
     NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname = 'operational_change_feed') THEN
    RAISE EXCEPTION 'PRECONDITION_FAILED: migration 004 foundations missing';
  END IF;
END
$$;


-- =============================================================================
-- 1. EVENT TRIGGER HANDLER HARDENING (C-03 / Advisor 0028 & 0029 CLEANUP)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  cmd record;
  tbl name;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_catalog.pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table', 'partitioned table')
  LOOP
    IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public')
       AND cmd.schema_name NOT IN ('pg_catalog', 'information_schema')
       AND cmd.schema_name NOT LIKE 'pg_toast%'
       AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        SELECT c.relname INTO tbl FROM pg_catalog.pg_class c WHERE c.oid = cmd.objid;
        EXECUTE pg_catalog.format('alter table if exists %I.%I enable row level security', cmd.schema_name, tbl);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
    ELSE
      RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rls_auto_enable() TO postgres;


-- =============================================================================
-- 2. AUDIT TRAIL ATTRIBUTION & CUSTOMER AUDIT COVERAGE (F-03)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.capture_audit_trail_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_req_id     pg_catalog.text := NULL;
  v_op_id      pg_catalog.text := NULL;
  v_raw_claims pg_catalog.text := NULL;
  v_claims     pg_catalog.jsonb := NULL;
  v_jwt_sub    pg_catalog.text := NULL;
  v_jwt_role   pg_catalog.text := NULL;
  v_actor      pg_catalog.text := NULL;
BEGIN
  IF TG_TABLE_NAME = 'logs' THEN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
      v_req_id := NEW.request_id;
      v_op_id  := NEW.operator_id;
    ELSIF TG_OP = 'DELETE' THEN
      v_req_id := OLD.request_id;
      v_op_id  := OLD.operator_id;
    END IF;
  ELSIF TG_TABLE_NAME = 'warehouse_logs' THEN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
      v_req_id := NEW.request_id;
    ELSIF TG_OP = 'DELETE' THEN
      v_req_id := OLD.request_id;
    END IF;
    v_op_id := NULL;
  END IF;

  -- Authoritative server-derived changed_by: NEVER prioritize client operator_id over verified JWT/session
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_claims     := v_raw_claims::pg_catalog.jsonb;
  v_jwt_sub    := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_claims ->> 'sub'
  ), '');
  v_jwt_role   := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_claims ->> 'role'
  ), '');

  IF v_jwt_sub IS NOT NULL THEN
    v_actor := v_jwt_sub;
  ELSIF v_jwt_role IS NOT NULL THEN
    v_actor := 'jwt_role:' || v_jwt_role;
  ELSE
    v_actor := SESSION_USER;
  END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, new_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'INSERT', NEW.id::pg_catalog.text, v_req_id, v_op_id, pg_catalog.to_jsonb(NEW), v_actor, pg_catalog.clock_timestamp()
    );
    RETURN NULL;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, old_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'DELETE', OLD.id::pg_catalog.text, v_req_id, v_op_id, pg_catalog.to_jsonb(OLD), v_actor, pg_catalog.clock_timestamp()
    );
    RETURN NULL;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO public.transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, old_data, new_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'UPDATE', NEW.id::pg_catalog.text, v_req_id, v_op_id, pg_catalog.to_jsonb(OLD), pg_catalog.to_jsonb(NEW), v_actor, pg_catalog.clock_timestamp()
    );
    RETURN NULL;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.capture_audit_trail_trigger() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.capture_audit_trail_trigger() TO postgres;

CREATE OR REPLACE FUNCTION public.capture_customers_audit_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_req_id     pg_catalog.text := NULL;
  v_raw_claims pg_catalog.text := NULL;
  v_claims     pg_catalog.jsonb := NULL;
  v_jwt_sub    pg_catalog.text := NULL;
  v_jwt_role   pg_catalog.text := NULL;
  v_actor      pg_catalog.text := NULL;
BEGIN
  v_req_id     := NULLIF(pg_catalog.current_setting('app.current_request_id', true), '');
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_claims     := v_raw_claims::pg_catalog.jsonb;
  v_jwt_sub    := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_claims ->> 'sub'
  ), '');
  v_jwt_role   := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_claims ->> 'role'
  ), '');

  IF v_jwt_sub IS NOT NULL THEN
    v_actor := v_jwt_sub;
  ELSIF v_jwt_role IS NOT NULL THEN
    v_actor := 'jwt_role:' || v_jwt_role;
  ELSE
    v_actor := SESSION_USER;
  END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, new_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'INSERT', NEW.no_kk, v_req_id, NULL, pg_catalog.to_jsonb(NEW), v_actor, pg_catalog.clock_timestamp()
    );
    RETURN NULL;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, old_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'DELETE', OLD.no_kk, v_req_id, NULL, pg_catalog.to_jsonb(OLD), v_actor, pg_catalog.clock_timestamp()
    );
    RETURN NULL;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO public.transaction_audit_trail(
      table_name, action_type, record_id, request_id, operator_id, old_data, new_data, changed_by, changed_at
    ) VALUES (
      TG_TABLE_NAME, 'UPDATE', NEW.no_kk, v_req_id, NULL, pg_catalog.to_jsonb(OLD), pg_catalog.to_jsonb(NEW), v_actor, pg_catalog.clock_timestamp()
    );
    RETURN NULL;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.capture_customers_audit_trigger() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.capture_customers_audit_trigger() TO postgres;

CREATE OR REPLACE TRIGGER trg_audit_customers_track
AFTER INSERT OR UPDATE OR DELETE ON public.customers
FOR EACH ROW EXECUTE FUNCTION public.capture_customers_audit_trigger();


-- =============================================================================
-- 3. INTERNAL CANONICAL FINGERPRINT v2 & DEFERRED CHANGE-FEED TRIGGER (F-02, F-05, C-05)
-- =============================================================================
CREATE OR REPLACE FUNCTION private_internal.calculate_canonical_fingerprint_v2(
  p_action pg_catalog.text,
  p_client_tx_id pg_catalog.text,
  p_verified_operator_id pg_catalog.text,
  p_params pg_catalog.jsonb
)
RETURNS pg_catalog.text
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
  v_clean_action pg_catalog.text;
  v_clean_tx_id  pg_catalog.text;
  v_clean_op_id  pg_catalog.text;
  v_allowed_keys pg_catalog.text[];
  v_key          pg_catalog.text;
  v_canonical    pg_catalog.jsonb;
  v_num_beras    pg_catalog.numeric;
  v_num_gas      pg_catalog.numeric;
  v_num_qty      pg_catalog.numeric;
BEGIN
  IF p_params IS NULL OR pg_catalog.jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'FINGERPRINT_ERROR: p_params must be a JSON object' USING ERRCODE = '22004';
  END IF;

  v_clean_action := pg_catalog.btrim(COALESCE(p_action, ''));
  v_clean_tx_id  := pg_catalog.btrim(COALESCE(p_client_tx_id, ''));
  v_clean_op_id  := pg_catalog.btrim(COALESCE(p_verified_operator_id, ''));

  IF v_clean_action = '' OR v_clean_tx_id = '' OR v_clean_op_id = '' THEN
    RAISE EXCEPTION 'FINGERPRINT_ERROR: action, client_tx_id, and operator_id must be non-empty' USING ERRCODE = '22004';
  END IF;

  IF v_clean_action = 'REGISTER_CUSTOMER' THEN
    v_allowed_keys := ARRAY['p_no_kk', 'p_member_id', 'p_nama', 'p_provinsi', 'p_kabupaten', 'p_kecamatan', 'p_desa', 'p_detail'];
    FOR v_key IN SELECT pg_catalog.jsonb_object_keys(p_params) LOOP
      IF NOT (v_key = ANY(v_allowed_keys)) THEN
        RAISE EXCEPTION 'FINGERPRINT_ERROR: unexpected parameter key "%" for REGISTER_CUSTOMER', v_key USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF NOT (p_params ? 'p_no_kk' AND p_params ? 'p_member_id' AND p_params ? 'p_nama'
            AND p_params ? 'p_provinsi' AND p_params ? 'p_kabupaten' AND p_params ? 'p_kecamatan'
            AND p_params ? 'p_desa' AND p_params ? 'p_detail') THEN
      RAISE EXCEPTION 'FINGERPRINT_ERROR: missing required keys for REGISTER_CUSTOMER' USING ERRCODE = '22023';
    END IF;
    IF pg_catalog.jsonb_typeof(p_params -> 'p_no_kk') <> 'string' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_member_id') <> 'string' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_nama') <> 'string' OR
       NOT ((p_params ->> 'p_no_kk') ~ '^[0-9]{16}$') THEN
      RAISE EXCEPTION 'FINGERPRINT_ERROR: invalid REGISTER_CUSTOMER key types or p_no_kk format' USING ERRCODE = '22023';
    END IF;

    v_canonical := pg_catalog.jsonb_build_object(
      'action', 'REGISTER_CUSTOMER',
      'client_tx_id', v_clean_tx_id,
      'fingerprint_version', 2,
      'operator_id', v_clean_op_id,
      'p_no_kk', p_params ->> 'p_no_kk',
      'p_member_id', pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_member_id'), 'NFC'),
      'p_nama', pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_nama'), 'NFC'),
      'p_provinsi', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_provinsi') = 'null' THEN NULL
                         ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_provinsi'), 'NFC') END,
      'p_kabupaten', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_kabupaten') = 'null' THEN NULL
                          ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_kabupaten'), 'NFC') END,
      'p_kecamatan', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_kecamatan') = 'null' THEN NULL
                          ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_kecamatan'), 'NFC') END,
      'p_desa', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_desa') = 'null' THEN NULL
                     ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_desa'), 'NFC') END,
      'p_detail', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_detail') = 'null' THEN NULL
                       ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_detail'), 'NFC') END
    );

  ELSIF v_clean_action = 'DISPENSE_QUOTA' THEN
    v_allowed_keys := ARRAY[
      'p_no_kk', 'p_nama', 'p_member_id', 'p_qty_beras', 'p_qty_gas', 'p_tx_date',
      'p_operator_id', 'p_custom_log_id', 'p_provinsi', 'p_kabupaten', 'p_kecamatan', 'p_desa', 'p_detail'
    ];
    FOR v_key IN SELECT pg_catalog.jsonb_object_keys(p_params) LOOP
      IF NOT (v_key = ANY(v_allowed_keys)) THEN
        RAISE EXCEPTION 'FINGERPRINT_ERROR: unexpected parameter key "%" for DISPENSE_QUOTA', v_key USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF pg_catalog.jsonb_typeof(p_params -> 'p_qty_beras') <> 'number' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_qty_gas') <> 'number' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_no_kk') <> 'string' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_tx_date') <> 'string' OR
       NOT ((p_params ->> 'p_no_kk') ~ '^[0-9]{16}$') THEN
      RAISE EXCEPTION 'FINGERPRINT_ERROR: invalid DISPENSE_QUOTA scalar types' USING ERRCODE = '22023';
    END IF;
    v_num_beras := (p_params ->> 'p_qty_beras')::pg_catalog.numeric;
    v_num_gas   := (p_params ->> 'p_qty_gas')::pg_catalog.numeric;
    IF v_num_beras <> pg_catalog.trunc(v_num_beras) OR v_num_gas <> pg_catalog.trunc(v_num_gas) THEN
      RAISE EXCEPTION 'FINGERPRINT_ERROR: fractional quantities prohibited' USING ERRCODE = '22023';
    END IF;

    v_canonical := pg_catalog.jsonb_build_object(
      'action', 'DISPENSE_QUOTA',
      'client_tx_id', v_clean_tx_id,
      'fingerprint_version', 2,
      'operator_id', v_clean_op_id,
      'p_no_kk', p_params ->> 'p_no_kk',
      'p_nama', pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_nama'), 'NFC'),
      'p_member_id', pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_member_id'), 'NFC'),
      'p_qty_beras', v_num_beras::pg_catalog.int4,
      'p_qty_gas', v_num_gas::pg_catalog.int4,
      'p_tx_date', (p_params ->> 'p_tx_date')::pg_catalog.date::pg_catalog.text,
      'p_operator_id', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_operator_id') = 'null' THEN NULL
                            ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_operator_id'), 'NFC') END,
      'p_custom_log_id', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_custom_log_id') = 'null' THEN NULL
                              ELSE pg_catalog.btrim(p_params ->> 'p_custom_log_id') END,
      'p_provinsi', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_provinsi') = 'null' THEN NULL
                         ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_provinsi'), 'NFC') END,
      'p_kabupaten', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_kabupaten') = 'null' THEN NULL
                          ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_kabupaten'), 'NFC') END,
      'p_kecamatan', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_kecamatan') = 'null' THEN NULL
                          ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_kecamatan'), 'NFC') END,
      'p_desa', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_desa') = 'null' THEN NULL
                     ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_desa'), 'NFC') END,
      'p_detail', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_detail') = 'null' THEN NULL
                       ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_detail'), 'NFC') END
    );

  ELSIF v_clean_action = 'WAREHOUSE_MUTATION' THEN
    v_allowed_keys := ARRAY['p_date', 'p_type', 'p_item', 'p_qty', 'p_ref', 'p_operator_id', 'p_custom_mutation_id'];
    FOR v_key IN SELECT pg_catalog.jsonb_object_keys(p_params) LOOP
      IF NOT (v_key = ANY(v_allowed_keys)) THEN
        RAISE EXCEPTION 'FINGERPRINT_ERROR: unexpected parameter key "%" for WAREHOUSE_MUTATION', v_key USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF pg_catalog.jsonb_typeof(p_params -> 'p_qty') <> 'number' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_date') <> 'string' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_type') <> 'string' OR
       pg_catalog.jsonb_typeof(p_params -> 'p_item') <> 'string' THEN
      RAISE EXCEPTION 'FINGERPRINT_ERROR: invalid WAREHOUSE_MUTATION scalar types' USING ERRCODE = '22023';
    END IF;
    v_num_qty := (p_params ->> 'p_qty')::pg_catalog.numeric;
    IF v_num_qty <> pg_catalog.trunc(v_num_qty) THEN
      RAISE EXCEPTION 'FINGERPRINT_ERROR: fractional warehouse quantity prohibited' USING ERRCODE = '22023';
    END IF;

    v_canonical := pg_catalog.jsonb_build_object(
      'action', 'WAREHOUSE_MUTATION',
      'client_tx_id', v_clean_tx_id,
      'fingerprint_version', 2,
      'operator_id', v_clean_op_id,
      'p_date', (p_params ->> 'p_date')::pg_catalog.date::pg_catalog.text,
      'p_type', pg_catalog.upper(pg_catalog.btrim(p_params ->> 'p_type')),
      'p_item', pg_catalog.lower(pg_catalog.btrim(p_params ->> 'p_item')),
      'p_qty', v_num_qty::pg_catalog.int4,
      'p_ref', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_ref') = 'null' THEN NULL
                    ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_ref'), 'NFC') END,
      'p_operator_id', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_operator_id') = 'null' THEN NULL
                            ELSE pg_catalog.normalize(pg_catalog.btrim(p_params ->> 'p_operator_id'), 'NFC') END,
      'p_custom_mutation_id', CASE WHEN pg_catalog.jsonb_typeof(p_params -> 'p_custom_mutation_id') = 'null' THEN NULL
                                   ELSE pg_catalog.btrim(p_params ->> 'p_custom_mutation_id') END
    );

  ELSE
    RAISE EXCEPTION 'FINGERPRINT_ERROR: unrecognized action "%"', v_clean_action USING ERRCODE = '22023';
  END IF;

  RETURN pg_catalog.encode(extensions.digest(v_canonical::pg_catalog.text, 'sha256'::pg_catalog.text), 'hex');
END;
$$;

REVOKE ALL ON FUNCTION private_internal.calculate_canonical_fingerprint_v2(
  pg_catalog.text, pg_catalog.text, pg_catalog.text, pg_catalog.jsonb
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private_internal.calculate_canonical_fingerprint_v2(
  pg_catalog.text, pg_catalog.text, pg_catalog.text, pg_catalog.jsonb
) TO postgres;


CREATE OR REPLACE FUNCTION private_internal.trg_fn_capture_change_feed_v4()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_old_pk      pg_catalog.text;
  v_new_pk      pg_catalog.text;
  v_old_json    pg_catalog.jsonb;
  v_new_json    pg_catalog.jsonb;
  v_seq         pg_catalog.int8;
  v_seq_end     pg_catalog.int8;
  v_ts          pg_catalog.timestamptz;
  v_action      pg_catalog.text;
  v_payload     pg_catalog.jsonb;
  v_rec_id      pg_catalog.text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_old_json := pg_catalog.to_jsonb(OLD);
    v_new_json := pg_catalog.to_jsonb(NEW);
    IF v_old_json IS NOT DISTINCT FROM v_new_json THEN
      RETURN NULL;
    END IF;
  END IF;

  IF TG_TABLE_NAME = 'customers' THEN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old_pk := OLD.no_kk; END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new_pk := NEW.no_kk; END IF;
  ELSE
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old_pk := OLD.id::pg_catalog.text; END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new_pk := NEW.id::pg_catalog.text; END IF;
  END IF;

  -- Primary-key mutation emits deterministic atomic dual-event (TOMBSTONE old + INSERT new)
  IF TG_OP = 'UPDATE' AND v_old_pk IS DISTINCT FROM v_new_pk THEN
    UPDATE public.change_feed_tracker
    SET last_committed_seq = last_committed_seq + 2,
        updated_at = pg_catalog.clock_timestamp()
    WHERE singleton_id = 1
    RETURNING last_committed_seq, updated_at INTO v_seq_end, v_ts;

    IF v_seq_end IS NULL THEN
      RAISE EXCEPTION 'CHANGE_FEED_INVARIANT: missing singleton_id = 1 in change_feed_tracker';
    END IF;

    INSERT INTO public.operational_change_feed (
      change_seq, table_name, record_id, action_type, record_data, recorded_at
    ) VALUES (
      v_seq_end - 1,
      TG_TABLE_NAME,
      v_old_pk,
      'TOMBSTONE',
      pg_catalog.jsonb_build_object(
        'table_name', TG_TABLE_NAME,
        'record_id', v_old_pk,
        'is_tombstone', true,
        'reason', 'PK_CHANGED',
        'replaced_by', v_new_pk,
        'marked_at', v_ts
      ),
      v_ts
    );

    INSERT INTO public.operational_change_feed (
      change_seq, table_name, record_id, action_type, record_data, recorded_at
    ) VALUES (
      v_seq_end,
      TG_TABLE_NAME,
      v_new_pk,
      'INSERT',
      v_new_json,
      v_ts
    );

    RETURN NULL;
  END IF;

  -- Standard single-event commit allocation (FIFO lock held until COMMIT)
  UPDATE public.change_feed_tracker
  SET last_committed_seq = last_committed_seq + 1,
      updated_at = pg_catalog.clock_timestamp()
  WHERE singleton_id = 1
  RETURNING last_committed_seq, updated_at INTO v_seq, v_ts;

  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'CHANGE_FEED_INVARIANT: missing singleton_id = 1 in change_feed_tracker';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_action  := 'INSERT';
    v_rec_id  := v_new_pk;
    v_payload := pg_catalog.to_jsonb(NEW);
  ELSIF TG_OP = 'DELETE' THEN
    v_action  := 'DELETE';
    v_rec_id  := v_old_pk;
    v_payload := pg_catalog.jsonb_build_object(
      'table_name', TG_TABLE_NAME,
      'record_id', v_old_pk,
      'is_deleted', true,
      'deleted_at', v_ts
    );
  ELSIF TG_OP = 'UPDATE' THEN
    v_rec_id  := v_new_pk;
    v_payload := v_new_json;
    IF TG_TABLE_NAME = 'logs' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('CANCELLED', 'REFUNDED') THEN
      v_action := 'VOID';
    ELSIF TG_TABLE_NAME = 'warehouse_logs' AND COALESCE(OLD.is_void, false) = false AND NEW.is_void = true THEN
      v_action := 'VOID';
    ELSE
      v_action := 'UPDATE';
    END IF;
  END IF;

  INSERT INTO public.operational_change_feed (
    change_seq, table_name, record_id, action_type, record_data, recorded_at
  ) VALUES (
    v_seq, TG_TABLE_NAME, v_rec_id, v_action, v_payload, v_ts
  );

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private_internal.trg_fn_capture_change_feed_v4() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private_internal.trg_fn_capture_change_feed_v4() TO postgres;

CREATE CONSTRAINT TRIGGER trg_cf_customers
AFTER INSERT OR UPDATE OR DELETE ON public.customers
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private_internal.trg_fn_capture_change_feed_v4();

CREATE CONSTRAINT TRIGGER trg_cf_logs
AFTER INSERT OR UPDATE OR DELETE ON public.logs
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private_internal.trg_fn_capture_change_feed_v4();

CREATE CONSTRAINT TRIGGER trg_cf_warehouse_logs
AFTER INSERT OR UPDATE OR DELETE ON public.warehouse_logs
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private_internal.trg_fn_capture_change_feed_v4();


-- =============================================================================
-- 4. HARDEN EXISTING 003 OPERATIONAL RPCs (EXACT SIGNATURES, DEFAULTS & RULES PRESERVED)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.process_quota_dispense(
  p_request_id     TEXT,
  p_no_kk          TEXT,
  p_nama           TEXT,
  p_member_id      TEXT,
  p_qty_beras      INT,
  p_qty_gas        INT,
  p_tx_date        DATE DEFAULT CURRENT_DATE,
  p_operator_id    TEXT DEFAULT NULL,
  p_custom_log_id  TEXT DEFAULT NULL,
  p_provinsi       TEXT DEFAULT '',
  p_kabupaten      TEXT DEFAULT '',
  p_kecamatan      TEXT DEFAULT '',
  p_desa           TEXT DEFAULT '',
  p_detail         TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_clean_no_kk         pg_catalog.text;
  v_clean_nama          pg_catalog.text;
  v_clean_member_id     pg_catalog.text;
  v_log_id              pg_catalog.text;
  v_existing_log        RECORD;
  v_cust_check          RECORD;
  v_used_beras          pg_catalog.int4 := 0;
  v_used_gas            pg_catalog.int4 := 0;
  v_stock_beras         pg_catalog.int4 := 0;
  v_stock_gas           pg_catalog.int4 := 0;
  v_actor               pg_catalog.text;
  v_masked_kk           pg_catalog.text;
  v_total_pcs           pg_catalog.int4;
  v_raw_claims          pg_catalog.text;
  v_jwt_claims          pg_catalog.jsonb;
  v_jwt_role            pg_catalog.text;
  v_jwt_sub             pg_catalog.text;
  v_app_role            pg_catalog.text;
BEGIN
  -- Step 1: Server-side JWT authorization without auth.role()
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Penyaluran kuota sembako mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang menyalurkan kuota', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- Step 2: Explicit validation & business constraints
  IF p_request_id IS NULL OR pg_catalog.btrim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id wajib disertakan dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0005';
  END IF;

  IF p_tx_date IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Tanggal transaksi (p_tx_date) tidak boleh NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_nama := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_nama, '')), 'NFC');
  IF v_clean_nama = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nama warga (p_nama) wajib diisi dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_member_id := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_member_id, '')), 'NFC');
  IF v_clean_member_id = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Member ID (p_member_id) wajib diisi dan tidak boleh kosong/NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_no_kk := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF pg_catalog.length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nomor KK harus tepat 16 digit numerik (diterima: %)', p_no_kk
      USING ERRCODE = 'P0006';
  END IF;

  IF p_qty_beras IS NULL OR p_qty_gas IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas Beras dan Gas tidak boleh bernilai NULL'
      USING ERRCODE = 'P0007';
  END IF;

  IF p_qty_beras < 0 OR p_qty_beras > 5 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas Beras per transaksi harus antara 0 dan 5 (diterima: %)', p_qty_beras
      USING ERRCODE = 'P0007';
  END IF;

  IF p_qty_gas < 0 OR p_qty_gas > 5 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas Gas per transaksi harus antara 0 dan 5 (diterima: %)', p_qty_gas
      USING ERRCODE = 'P0007';
  END IF;

  v_total_pcs := p_qty_beras + p_qty_gas;
  IF v_total_pcs <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Minimal pembelian per transaksi adalah 1 pcs'
      USING ERRCODE = 'P0008';
  END IF;

  -- Bind transaction-local request correlation for customer audit trigger
  PERFORM pg_catalog.set_config('app.current_request_id', pg_catalog.btrim(p_request_id), true);

  -- Step 3: Level 0 Lock (Request ID)
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('REQ:' || pg_catalog.btrim(p_request_id), 0));

  -- Step 4: Idempotency detection
  SELECT id, request_id, operator_id, date, member_id, nama, no_kk,
         qty_beras, qty_gas, total_pcs, status, created_at
  INTO v_existing_log
  FROM public.logs
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_log.no_kk IS DISTINCT FROM v_clean_no_kk OR
       v_existing_log.date IS DISTINCT FROM p_tx_date OR
       pg_catalog.normalize(COALESCE(v_existing_log.member_id, ''), 'NFC') IS DISTINCT FROM v_clean_member_id OR
       v_existing_log.qty_beras IS DISTINCT FROM p_qty_beras OR
       v_existing_log.qty_gas IS DISTINCT FROM p_qty_gas THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay)',
      'log', pg_catalog.to_jsonb(v_existing_log)
    );
  END IF;

  -- Step 5: Level 1 Lock (No KK)
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('KK:' || v_clean_no_kk, 0));

  -- Step 6: Atomic customer check / auto-registration
  SELECT no_kk, member_id, nama INTO v_cust_check
  FROM public.customers
  WHERE no_kk = v_clean_no_kk
  FOR UPDATE;

  IF FOUND THEN
    IF pg_catalog.normalize(v_cust_check.nama, 'NFC') <> v_clean_nama OR
       pg_catalog.normalize(v_cust_check.member_id, 'NFC') <> v_clean_member_id THEN
      RAISE EXCEPTION 'CUSTOMER_CONFLICT: Identitas pemohon (Nama: %, Member: %) tidak cocok dengan data master terdaftar (Nama: %, Member: %). Perubahan data master membutuhkan prosedur otorisasi khusus.',
        v_clean_nama, v_clean_member_id, v_cust_check.nama, v_cust_check.member_id
        USING ERRCODE = 'P0014';
    END IF;
  ELSE
    INSERT INTO public.customers (
      no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail
    ) VALUES (
      v_clean_no_kk, v_clean_member_id, v_clean_nama,
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_provinsi, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kabupaten, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kecamatan, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_desa, '')), 'NFC'),
      pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_detail, '')), 'NFC')
    );
  END IF;

  -- Step 7: Level 3 Locks (Ordered Stock: BERAS -> GAS)
  IF p_qty_beras > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('STOCK:BERAS', 0));
  END IF;
  IF p_qty_gas > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('STOCK:GAS', 0));
  END IF;

  -- Step 8: 30-day rolling quota check
  SELECT
    COALESCE(SUM(qty_beras), 0),
    COALESCE(SUM(qty_gas), 0)
  INTO v_used_beras, v_used_gas
  FROM public.logs
  WHERE no_kk = v_clean_no_kk
    AND status = 'COMPLETED'
    AND date > (p_tx_date - INTERVAL '30 days')
    AND date <= p_tx_date;

  IF (v_used_beras + p_qty_beras) > 5 THEN
    RAISE EXCEPTION 'QUOTA_LIMIT_EXCEEDED: Sisa kuota Beras tersisa %, permintaan % (Total akumulasi: % > 5 pcs / 30 hari)',
      (5 - v_used_beras), p_qty_beras, (v_used_beras + p_qty_beras)
      USING ERRCODE = 'P0001';
  END IF;

  IF (v_used_gas + p_qty_gas) > 5 THEN
    RAISE EXCEPTION 'QUOTA_LIMIT_EXCEEDED: Sisa kuota Gas tersisa %, permintaan % (Total akumulasi: % > 5 pcs / 30 hari)',
      (5 - v_used_gas), p_qty_gas, (v_used_gas + p_qty_gas)
      USING ERRCODE = 'P0002';
  END IF;

  -- Step 9: Warehouse balance check
  SELECT COALESCE(SUM(
    CASE
      WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty
      WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty
      ELSE 0
    END
  ), 0) INTO v_stock_beras
  FROM public.warehouse_logs WHERE item = 'beras' AND (is_void IS NOT TRUE);

  SELECT COALESCE(SUM(
    CASE
      WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty
      WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty
      ELSE 0
    END
  ), 0) INTO v_stock_gas
  FROM public.warehouse_logs WHERE item = 'gas' AND (is_void IS NOT TRUE);

  IF p_qty_beras > 0 AND v_stock_beras < p_qty_beras THEN
    RAISE EXCEPTION 'STOCK_DEFICIT: Stok gudang Beras tidak mencukupi (Tersedia: %, Dibutuhkan: %)',
      v_stock_beras, p_qty_beras
      USING ERRCODE = 'P0003';
  END IF;

  IF p_qty_gas > 0 AND v_stock_gas < p_qty_gas THEN
    RAISE EXCEPTION 'STOCK_DEFICIT: Stok gudang Gas tidak mencukupi (Tersedia: %, Dibutuhkan: %)',
      v_stock_gas, p_qty_gas
      USING ERRCODE = 'P0004';
  END IF;

  -- Step 10: ID & JWT actor attribution
  v_log_id := COALESCE(
    NULLIF(pg_catalog.btrim(p_custom_log_id), ''),
    'LOG-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.md5(pg_catalog.random()::pg_catalog.text || pg_catalog.clock_timestamp()::pg_catalog.text), 1, 8))
  );

  v_jwt_sub := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_jwt_claims ->> 'sub'
  ), '');
  v_actor := COALESCE(v_jwt_sub, NULLIF(pg_catalog.btrim(p_operator_id), ''), SESSION_USER);
  v_masked_kk := pg_catalog.substr(v_clean_no_kk, 1, 4) || ' •••• •••• ' || pg_catalog.substr(v_clean_no_kk, 13, 4);

  -- Step 11: Atomic insert into public.logs
  BEGIN
    INSERT INTO public.logs (
      id, request_id, operator_id, date, member_id, nama, no_kk,
      qty_beras, qty_gas, total_pcs, status
    ) VALUES (
      v_log_id, p_request_id, v_actor, p_tx_date, v_clean_member_id, v_clean_nama,
      v_clean_no_kk, p_qty_beras, p_qty_gas, v_total_pcs, 'COMPLETED'
    );
  EXCEPTION WHEN unique_violation THEN
    SELECT id, request_id, operator_id, date, member_id, nama, no_kk,
           qty_beras, qty_gas, total_pcs, status, created_at
    INTO v_existing_log
    FROM public.logs WHERE request_id = p_request_id;

    IF FOUND THEN
      IF v_existing_log.no_kk IS DISTINCT FROM v_clean_no_kk OR
         v_existing_log.date IS DISTINCT FROM p_tx_date OR
         pg_catalog.normalize(COALESCE(v_existing_log.member_id, ''), 'NFC') IS DISTINCT FROM v_clean_member_id OR
         v_existing_log.qty_beras IS DISTINCT FROM p_qty_beras OR
         v_existing_log.qty_gas IS DISTINCT FROM p_qty_gas THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah digunakan dengan parameter payload berbeda', p_request_id
          USING ERRCODE = 'P0009';
      END IF;

      RETURN pg_catalog.jsonb_build_object(
        'status', 'SUCCESS',
        'is_idempotent_replay', true,
        'message', 'Transaksi sudah tercatat sebelumnya (idempotent replay race)',
        'log', pg_catalog.to_jsonb(v_existing_log)
      );
    ELSE
      RAISE;
    END IF;
  END;

  -- Step 12: Atomic insert into public.warehouse_logs
  IF p_qty_beras > 0 THEN
    INSERT INTO public.warehouse_logs (
      id, request_id, date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-BERAS',
      'REQ-WH-BERAS-' || p_request_id,
      p_tx_date, 'GI-WARGA', 'beras', p_qty_beras,
      v_clean_nama || ' (' || v_masked_kk || ')', v_log_id, false
    );
  END IF;

  IF p_qty_gas > 0 THEN
    INSERT INTO public.warehouse_logs (
      id, request_id, date, type, item, qty, ref, log_id, is_void
    ) VALUES (
      'WH-GI-' || v_log_id || '-GAS',
      'REQ-WH-GAS-' || p_request_id,
      p_tx_date, 'GI-WARGA', 'gas', p_qty_gas,
      v_clean_nama || ' (' || v_masked_kk || ')', v_log_id, false
    );
  END IF;

  -- Step 13: Success response (exact 003 contract preserved)
  RETURN pg_catalog.jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Transaksi kuota dan mutasi stok berhasil diproses secara atomik',
    'log', pg_catalog.jsonb_build_object(
      'id', v_log_id,
      'request_id', p_request_id,
      'operator_id', v_actor,
      'date', p_tx_date,
      'member_id', v_clean_member_id,
      'nama', v_clean_nama,
      'no_kk', v_clean_no_kk,
      'qty_beras', p_qty_beras,
      'qty_gas', p_qty_gas,
      'total_pcs', v_total_pcs,
      'status', 'COMPLETED'
    ),
    'remaining_quota', pg_catalog.jsonb_build_object(
      'beras', 5 - (v_used_beras + p_qty_beras),
      'gas', 5 - (v_used_gas + p_qty_gas)
    ),
    'remaining_stock', pg_catalog.jsonb_build_object(
      'beras', v_stock_beras - p_qty_beras,
      'gas', v_stock_gas - p_qty_gas
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_quota_dispense(
  TEXT, TEXT, TEXT, TEXT, INT, INT, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO postgres, authenticated;


CREATE OR REPLACE FUNCTION public.register_customer(
  p_request_id     TEXT,
  p_no_kk          TEXT,
  p_member_id      TEXT,
  p_nama           TEXT,
  p_provinsi       TEXT DEFAULT '',
  p_kabupaten      TEXT DEFAULT '',
  p_kecamatan      TEXT DEFAULT '',
  p_desa           TEXT DEFAULT '',
  p_detail         TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_clean_no_kk         pg_catalog.text;
  v_clean_nama          pg_catalog.text;
  v_clean_member_id     pg_catalog.text;
  v_v2_fingerprint      pg_catalog.text;
  v_v1_fingerprint      pg_catalog.text;
  v_existing_req        RECORD;
  v_existing_cust       RECORD;
  v_result              RECORD;
  v_actor               pg_catalog.text;
  v_raw_claims          pg_catalog.text;
  v_jwt_claims          pg_catalog.jsonb;
  v_jwt_role            pg_catalog.text;
  v_jwt_sub             pg_catalog.text;
  v_app_role            pg_catalog.text;
BEGIN
  -- 1. Server-side JWT authorization without auth.role()
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Registrasi pelanggan mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('cashier', 'supervisor', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang mendaftarkan pelanggan', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- 2. Parameter validation
  IF p_request_id IS NULL OR pg_catalog.btrim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id registrasi wajib disertakan dan tidak boleh kosong'
      USING ERRCODE = 'P0005';
  END IF;

  v_clean_no_kk := pg_catalog.regexp_replace(COALESCE(p_no_kk, ''), '\D', '', 'g');
  IF pg_catalog.length(v_clean_no_kk) <> 16 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nomor KK harus tepat 16 digit numerik (diterima: %)', p_no_kk
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_nama := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_nama, '')), 'NFC');
  IF v_clean_nama = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Nama pelanggan (p_nama) wajib diisi'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_member_id := pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_member_id, '')), 'NFC');
  IF v_clean_member_id = '' THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Member ID (p_member_id) wajib diisi'
      USING ERRCODE = 'P0006';
  END IF;

  v_jwt_sub := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_jwt_claims ->> 'sub'
  ), '');
  v_actor := COALESCE(v_jwt_sub, SESSION_USER);

  -- 3. Compute canonical v2 fingerprint (+ v1 legacy compat solely for pre-005 existing ledger rows)
  v_v2_fingerprint := private_internal.calculate_canonical_fingerprint_v2(
    'REGISTER_CUSTOMER',
    pg_catalog.btrim(p_request_id),
    v_actor,
    pg_catalog.jsonb_build_object(
      'p_no_kk', v_clean_no_kk,
      'p_member_id', v_clean_member_id,
      'p_nama', v_clean_nama,
      'p_provinsi', p_provinsi,
      'p_kabupaten', p_kabupaten,
      'p_kecamatan', p_kecamatan,
      'p_desa', p_desa,
      'p_detail', p_detail
    )
  );

  v_v1_fingerprint := pg_catalog.encode(
    extensions.digest(
      (v_clean_no_kk || '|' || pg_catalog.btrim(COALESCE(p_member_id, '')) || '|' || pg_catalog.btrim(COALESCE(p_nama, '')) || '|' ||
       pg_catalog.btrim(COALESCE(p_provinsi, '')) || '|' || pg_catalog.btrim(COALESCE(p_kabupaten, '')) || '|' ||
       pg_catalog.btrim(COALESCE(p_kecamatan, '')) || '|' || pg_catalog.btrim(COALESCE(p_desa, '')) || '|' ||
       pg_catalog.btrim(COALESCE(p_detail, '')))::pg_catalog.text,
      'sha256'::pg_catalog.text
    ),
    'hex'
  );

  PERFORM pg_catalog.set_config('app.current_request_id', pg_catalog.btrim(p_request_id), true);

  -- 4. Lock Request ID
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('CUST_REQ:' || pg_catalog.btrim(p_request_id), 0));

  -- 5. Idempotency ledger check
  SELECT request_id, no_kk, payload_fingerprint, customer_no_kk
  INTO v_existing_req
  FROM public.customer_registration_requests
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_req.payload_fingerprint IN (v_v2_fingerprint, v_v1_fingerprint) THEN
      SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
      INTO v_existing_cust
      FROM public.customers
      WHERE no_kk = v_existing_req.customer_no_kk;

      RETURN pg_catalog.jsonb_build_object(
        'status', 'SUCCESS',
        'is_idempotent_replay', true,
        'message', 'Data pelanggan sudah tercatat sebelumnya (idempotent replay)',
        'customer', pg_catalog.to_jsonb(v_existing_cust)
      );
    ELSE
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah terdaftar dengan rincian data pelanggan berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;
  END IF;

  -- 6. Lock No KK
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('KK:' || v_clean_no_kk, 0));

  SELECT no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
  INTO v_existing_cust
  FROM public.customers
  WHERE no_kk = v_clean_no_kk
  FOR UPDATE;

  IF FOUND THEN
    IF pg_catalog.normalize(v_existing_cust.nama, 'NFC') <> v_clean_nama OR
       pg_catalog.normalize(v_existing_cust.member_id, 'NFC') <> v_clean_member_id THEN
      RAISE EXCEPTION 'CUSTOMER_CONFLICT: Nomor KK % sudah terdaftar atas nama "%" (Member: %). Perubahan profil memerlukan RPC otorisasi khusus.',
        v_clean_no_kk, v_existing_cust.nama, v_existing_cust.member_id
        USING ERRCODE = 'P0014';
    END IF;

    INSERT INTO public.customer_registration_requests (
      request_id, no_kk, payload_fingerprint, customer_no_kk, created_by
    ) VALUES (
      p_request_id, v_clean_no_kk, v_v2_fingerprint, v_clean_no_kk, v_actor
    ) ON CONFLICT (request_id) DO NOTHING;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Data pelanggan identik sudah terdaftar di basis data master',
      'customer', pg_catalog.to_jsonb(v_existing_cust)
    );
  END IF;

  -- 7. Register new customer (atomic audit + deferred change feed attached)
  INSERT INTO public.customers (
    no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail
  ) VALUES (
    v_clean_no_kk, v_clean_member_id, v_clean_nama,
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_provinsi, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kabupaten, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_kecamatan, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_desa, '')), 'NFC'),
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_detail, '')), 'NFC')
  )
  RETURNING no_kk, member_id, nama, provinsi, kabupaten, kecamatan, desa, detail, created_at
  INTO v_result;

  -- 8. Write idempotency ledger
  INSERT INTO public.customer_registration_requests (
    request_id, no_kk, payload_fingerprint, customer_no_kk, created_by
  ) VALUES (
    p_request_id, v_clean_no_kk, v_v2_fingerprint, v_clean_no_kk, v_actor
  );

  RETURN pg_catalog.jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Data Kartu Keluarga berhasil didaftarkan di master cloud',
    'customer', pg_catalog.to_jsonb(v_result)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_customer(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.register_customer(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO postgres, authenticated;


CREATE OR REPLACE FUNCTION public.process_warehouse_mutation(
  p_request_id          TEXT,
  p_date                DATE,
  p_type                TEXT,
  p_item                TEXT,
  p_qty                 INT,
  p_ref                 TEXT DEFAULT '',
  p_operator_id         TEXT DEFAULT NULL,
  p_custom_mutation_id  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_clean_type      pg_catalog.text;
  v_clean_item      pg_catalog.text;
  v_wh_id           pg_catalog.text;
  v_existing_wh     RECORD;
  v_stock_available pg_catalog.int4 := 0;
  v_actor           pg_catalog.text;
  v_raw_claims      pg_catalog.text;
  v_jwt_claims      pg_catalog.jsonb;
  v_jwt_role        pg_catalog.text;
  v_jwt_sub         pg_catalog.text;
  v_app_role        pg_catalog.text;
BEGIN
  -- 1. Server-side JWT authorization without auth.role()
  v_raw_claims := NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt_claims := v_raw_claims::pg_catalog.jsonb;
  v_jwt_role   := COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    v_jwt_claims ->> 'role',
    ''
  );
  IF v_jwt_role IS DISTINCT FROM 'authenticated' THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Mutasi gudang mewajibkan sesi login petugas resmi'
      USING ERRCODE = '42501';
  END IF;

  v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '');
  IF v_app_role NOT IN ('supervisor', 'warehouse_admin', 'admin') THEN
    RAISE EXCEPTION 'FORBIDDEN: Pengguna dengan role "%" tidak berwenang mengelola mutasi gudang fisik', v_app_role
      USING ERRCODE = '42501';
  END IF;

  -- 2. Parameter validation
  IF p_request_id IS NULL OR pg_catalog.btrim(p_request_id) = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_ERROR: request_id mutasi gudang wajib disertakan'
      USING ERRCODE = 'P0005';
  END IF;

  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Kuantitas mutasi harus berupa bilangan bulat positif (> 0)'
      USING ERRCODE = 'P0007';
  END IF;

  IF p_date IS NULL THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Tanggal mutasi tidak boleh NULL'
      USING ERRCODE = 'P0006';
  END IF;

  v_clean_type := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_type, '')));
  IF v_clean_type NOT IN ('INITIAL-STOCK', 'GR', 'GI-MANUAL') THEN
    IF v_clean_type IN ('GR-BATAL', 'GR-REFUND') THEN
      RAISE EXCEPTION 'UNAUTHORIZED_MUTATION_TYPE: Tipe mutasi "%" hanya dapat diproses melalui RPC refund/batal khusus berreferensi transaksi asal', v_clean_type
        USING ERRCODE = 'P0010';
    ELSIF v_clean_type IN ('GI-WARGA', 'GI-PELANGGAN') THEN
      RAISE EXCEPTION 'UNAUTHORIZED_MUTATION_TYPE: Tipe mutasi "%" hanya dapat dibukukan melalui RPC penyaluran kuota warga (process_quota_dispense)', v_clean_type
        USING ERRCODE = 'P0010';
    ELSE
      RAISE EXCEPTION 'UNAUTHORIZED_MUTATION_TYPE: Tipe mutasi gudang "%" tidak diizinkan. Hanya INITIAL-STOCK, GR, dan GI-MANUAL yang didukung', v_clean_type
        USING ERRCODE = 'P0010';
    END IF;
  END IF;

  v_clean_item := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_item, '')));
  IF v_clean_item NOT IN ('beras', 'gas') THEN
    RAISE EXCEPTION 'VALIDATION_ERROR: Komoditas "%" tidak valid (harus beras atau gas)', v_clean_item
      USING ERRCODE = 'P0006';
  END IF;

  -- 3. Lock Request ID
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('WH_REQ:' || pg_catalog.btrim(p_request_id), 0));

  -- 4. Idempotency check
  SELECT id, request_id, date, type, item, qty, ref, created_at
  INTO v_existing_wh
  FROM public.warehouse_logs
  WHERE request_id = p_request_id;

  IF FOUND THEN
    IF v_existing_wh.type <> v_clean_type OR
       v_existing_wh.item <> v_clean_item OR
       v_existing_wh.qty <> p_qty OR
       v_existing_wh.date <> p_date THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: request_id "%" sudah terpakai dengan payload mutasi berbeda', p_request_id
        USING ERRCODE = 'P0009';
    END IF;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'SUCCESS',
      'is_idempotent_replay', true,
      'message', 'Mutasi gudang sudah tercatat sebelumnya (idempotent replay)',
      'warehouse_log', pg_catalog.to_jsonb(v_existing_wh)
    );
  END IF;

  -- 5. Lock warehouse commodity
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('STOCK:' || pg_catalog.upper(v_clean_item), 0));

  -- 6. INITIAL-STOCK gatekeeper
  IF v_clean_type = 'INITIAL-STOCK' THEN
    IF EXISTS (
      SELECT 1 FROM public.warehouse_logs
      WHERE item = v_clean_item AND type = 'INITIAL-STOCK' AND (is_void IS NOT TRUE)
    ) THEN
      RAISE EXCEPTION 'INITIAL_STOCK_LOCKED: Saldo awal untuk komoditas % sudah pernah didaftarkan. Penambahan stok fisik wajib menggunakan GR.',
        pg_catalog.upper(v_clean_item)
        USING ERRCODE = 'P0013';
    END IF;
  END IF;

  -- 7. GI-MANUAL deficit check
  IF v_clean_type = 'GI-MANUAL' THEN
    SELECT COALESCE(SUM(
      CASE
        WHEN type IN ('INITIAL-STOCK', 'GR', 'GR-BATAL', 'GR-REFUND') THEN qty
        WHEN type IN ('GI', 'GI-WARGA', 'GI-MANUAL', 'GI-PELANGGAN') THEN -qty
        ELSE 0
      END
    ), 0)
    INTO v_stock_available
    FROM public.warehouse_logs
    WHERE item = v_clean_item AND (is_void IS NOT TRUE);

    IF v_stock_available < p_qty THEN
      RAISE EXCEPTION 'STOCK_DEFICIT: Stok gudang % tidak mencukupi untuk GI-MANUAL (Tersedia: %, Diminta: %)',
        pg_catalog.upper(v_clean_item), v_stock_available, p_qty
        USING ERRCODE = CASE WHEN v_clean_item = 'beras' THEN 'P0003' ELSE 'P0004' END;
    END IF;
  END IF;

  -- 8. Actor & mutation ID
  v_jwt_sub := NULLIF(COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), ''),
    v_jwt_claims ->> 'sub'
  ), '');
  v_actor := COALESCE(v_jwt_sub, NULLIF(pg_catalog.btrim(p_operator_id), ''), SESSION_USER);

  v_wh_id := COALESCE(
    NULLIF(pg_catalog.btrim(p_custom_mutation_id), ''),
    'WH-' || (CASE WHEN v_clean_type = 'INITIAL-STOCK' THEN 'INIT' ELSE v_clean_type END) || '-' ||
      pg_catalog.upper(pg_catalog.substr(pg_catalog.md5(pg_catalog.random()::pg_catalog.text || pg_catalog.clock_timestamp()::pg_catalog.text), 1, 8))
  );

  -- 9. Atomic insert
  INSERT INTO public.warehouse_logs (
    id, request_id, date, type, item, qty, ref, log_id, is_void
  ) VALUES (
    v_wh_id,
    p_request_id,
    p_date,
    v_clean_type,
    v_clean_item,
    p_qty,
    pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_ref, '')), 'NFC'),
    NULL,
    false
  );

  RETURN pg_catalog.jsonb_build_object(
    'status', 'SUCCESS',
    'is_idempotent_replay', false,
    'message', 'Mutasi gudang berhasil dibukukan secara atomik',
    'warehouse_log', pg_catalog.jsonb_build_object(
      'id', v_wh_id,
      'request_id', p_request_id,
      'date', p_date,
      'type', v_clean_type,
      'item', v_clean_item,
      'qty', p_qty,
      'ref', pg_catalog.normalize(pg_catalog.btrim(COALESCE(p_ref, '')), 'NFC'),
      'operator_id', v_actor
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.process_warehouse_mutation(
  TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_warehouse_mutation(
  TEXT, DATE, TEXT, TEXT, INT, TEXT, TEXT, TEXT
) TO postgres, authenticated;


-- =============================================================================
-- 5. POST-MIGRATION CATALOG, TRIGGER & ACL ASSERTIONS (ADVISOR 0009 NON-BLOCKING)
-- =============================================================================
NOTIFY pgrst, 'reload schema';

DO $$
DECLARE
  v_bad_cfg   INT;
  v_bad_pub   INT;
  v_cf_cnt    INT;
BEGIN
  SELECT count(*) INTO v_bad_cfg
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('public', 'private_internal')
    AND p.prosecdef
    AND p.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog'];
  IF v_bad_cfg > 0 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Found % SECURITY DEFINER function(s) without exact search_path=pg_catalog', v_bad_cfg;
  END IF;

  SELECT count(*) INTO v_bad_pub
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('public', 'private_internal')
    AND (p.proacl IS NULL OR pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE'));
  IF v_bad_pub > 0 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Found % function(s) with NULL proacl or PUBLIC EXECUTE', v_bad_pub;
  END IF;

  IF pg_catalog.has_function_privilege('anon', 'public.process_quota_dispense(text,text,text,text,int4,int4,date,text,text,text,text,text,text,text)', 'EXECUTE') OR
     pg_catalog.has_function_privilege('service_role', 'public.process_quota_dispense(text,text,text,text,int4,int4,date,text,text,text,text,text,text,text)', 'EXECUTE') OR
     NOT pg_catalog.has_function_privilege('authenticated', 'public.process_quota_dispense(text,text,text,text,int4,int4,date,text,text,text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT_FAILED: process_quota_dispense EXECUTE ACL mismatch';
  END IF;

  IF pg_catalog.has_function_privilege('anon', 'public.rls_auto_enable()', 'EXECUTE') OR
     pg_catalog.has_function_privilege('authenticated', 'public.rls_auto_enable()', 'EXECUTE') OR
     pg_catalog.has_function_privilege('service_role', 'public.rls_auto_enable()', 'EXECUTE') OR
     NOT pg_catalog.has_function_privilege('postgres', 'public.rls_auto_enable()', 'EXECUTE') THEN
    RAISE EXCEPTION 'ASSERT_FAILED: rls_auto_enable EXECUTE ACL mismatch';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'customers' AND t.tgname = 'trg_audit_customers_track' AND t.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'ASSERT_FAILED: trg_audit_customers_track missing or disabled';
  END IF;

  SELECT count(*) INTO v_cf_cnt
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND t.tgname IN ('trg_cf_customers', 'trg_cf_logs', 'trg_cf_warehouse_logs')
    AND t.tgenabled = 'O'
    AND t.tgdeferrable = true
    AND t.tginitdeferred = true;
  IF v_cf_cnt <> 3 THEN
    RAISE EXCEPTION 'ASSERT_FAILED: Expected 3 enabled deferred change-feed triggers, found %', v_cf_cnt;
  END IF;
END
$$;
