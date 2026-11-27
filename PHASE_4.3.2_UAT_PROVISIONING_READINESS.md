# PHASE 4.3.2 — STAGING UAT PROVISIONING & TEST READINESS

**Project:** Catat Kuota KK  
**Phase:** 4.3.2 — Staging UAT Credential Provisioning & Test Readiness  
**Baseline:** Applied Staging Migrations `004`–`006` + Phase 4.3 & Phase 4.3.1 Reports  
**Mode:** STRICT UAT PREPARATION — NO MIGRATION `007`  
**Final Decision:** **`BLOCKED — OWNER PROVISIONING REQUIRED`**

---

## 1. Verified Staging Identity & Safety Baseline

Verified directly against Supabase MCP (`get_project`, `get_project_url`, and read-only SQL catalog checks) at `2026-11-27T08:12Z`:

| Property | Verified Value |
|---|---|
| Supabase Project ID / Ref | `evexaeyryfayfbffzzhh` |
| Project Name | `CATAT KUOTA KK - STAGING` |
| Region / Status | `ap-southeast-1` / `ACTIVE_HEALTHY` |
| Database / Engine | `postgres` on `db.evexaeyryfayfbffzzhh.supabase.co` (`PostgreSQL 17.12.0.000`) |
| PostgREST API Base URL | `https://evexaeyryfayfbffzzhh.supabase.co` |
| Production Project (`jziahfqjawqivesknkms`) | **Untouched** (strictly prohibited) |
| Applied Schema Migrations | `20261126153951` (`004`), `20261126154914` (`005`), `20261127004356` (`006`) |
| Migration `007` Contract Status | **NOT CREATED / NOT EXECUTED** (`"Staging read customers"`, `"Staging read logs"`, `"Staging read warehouse_logs"` policies active) |
| Active Table Baseline Counts | `customers=2`, `logs=0`, `warehouse_logs=2`, `transaction_audit_trail=14`, `customer_registration_requests=3`, `operational_change_feed=0`, `kiosk_tokens=0`, `kiosk_rate_limits=1`, `offline_reconciliation_conflicts=0` |

### Observed Existing `auth.users` Accounts (Read-Only Non-Secret Metadata)
Only two pre-existing accounts exist on staging `evexaeyryfayfbffzzhh`:
1. `64f0edb5-e37d-4a72-9c87-ed7384415c71` — `gimelbersama@gmail.com` (`raw_app_meta_data.role = 'supervisor'`, `email_confirmed = true`, last sign-in `2026-11-24`)
2. `1f99b09a-cfc7-4ed0-bf9a-0457dcfd80a3` — `rfrtoolsofficial@gmail.com` (`raw_app_meta_data.role = 'cashier'`, `email_confirmed = true`, last sign-in `2026-11-23`)

Per Phase 4.3.2 safety boundaries, these existing personal/operator accounts are **not** used for synthetic/destructive UAT operations without explicit owner authorization, and no credentials or secrets exist in workspace files or environment variables.

---

## 2. UAT Account Matrix & Provisioning Status

| Test Identity | Proposed Staging-Only Email | Required `app_metadata.role` | Email Confirmed | Least-Privilege Test Scope | Cleanup / Expiration Plan | Current Status |
|---|---|---|---|---|---|---|
| UAT Cashier | `uat-cashier@catatkuota-staging.invalid` | `cashier` | Yes (auto-confirm on create) | Authenticated login/refresh; snapshot/sync limited to `customers` + `logs` (`stock_summary = null`); register/verify customer; dispense quota; conflict escalation; negative checks (`warehouse_logs`, `stock_summary`, `warehouse_mutation`, `issue_kiosk_token`, `prune`) | Revoke active sessions + disable/delete Auth user after Phase 4.3.1 UAT sign-off; auto-expire target `<= 7 days` | **Pending provisioning** (`NOT PROVISIONED`) |
| UAT Warehouse | `uat-warehouse@catatkuota-staging.invalid` | `warehouse_admin` | Yes (auto-confirm on create) | Authenticated login/refresh; snapshot/sync limited to `warehouse_logs` + `stock_summary`; warehouse mutations (`INITIAL-STOCK`/`GR`/`GI-MANUAL`); negative checks (`customers`, `logs`, `register_customer`, `dispense`, `issue_kiosk_token`, `prune`) | Revoke active sessions + disable/delete Auth user after Phase 4.3.1 UAT sign-off; auto-expire target `<= 7 days` | **Pending provisioning** (`MISSING ROLE IN AUTH.USERS`) |
| UAT Supervisor | `uat-supervisor@catatkuota-staging.invalid` | `supervisor` | Yes (auto-confirm on create) | Full operational snapshot (`customers`, `logs`, `warehouse_logs`, `stock_summary`) & delta sync; kiosk token issuance & revocation (`issue_kiosk_token` / `revoke_kiosk_token`); operator handoff unlock verification; negative checks (`prune` PostgREST rejection) | Revoke synthetic kiosk tokens (`revoke_kiosk_token`); revoke sessions + disable/delete Auth user after Phase 4.3.1 UAT sign-off; `<= 7 days` | **Pending provisioning** (`NOT PROVISIONED`) |
| UAT Admin | `uat-admin@catatkuota-staging.invalid` | `admin` | Yes (auto-confirm on create) | Cross-domain admin parity checks across snapshot, sync, warehouse, dispense, verify, and kiosk management RPCs; negative checks (`prune` via `authenticated` JWT must still return `401`/`42501`) | Revoke synthetic kiosk tokens; revoke sessions + disable/delete Auth user after Phase 4.3.1 UAT sign-off; `<= 7 days` | **Pending provisioning** (`MISSING ROLE IN AUTH.USERS`) |

> **Important Note on Non-Deliverable Mailbox Domains:** Using Supabase Admin Dashboard **Create User** with `Auto Confirm User = ON` avoids sending outbound verification mail. Any internal reserved staging domain chosen by the project owner (e.g., `@catatkuota-staging.local` or internal alias) works equally cleanly once confirmed by owner.

---

## 3. Actual Authorization-Source Verification (Backend + Frontend)

Direct inspection of live staging functions (`pg_catalog.pg_proc` & migrations `005`/`006`), `auth` triggers (`pg_catalog.pg_trigger`), active `pg_policies`, and [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) confirmed the following exact authorization chain:

1. **No Auto-Provisioning Triggers on `auth.*` (`0` rows):**
   - `pg_trigger` inspection on `auth.users`, `auth.identities`, and `auth.sessions` confirmed **0 custom triggers**. Creating a Supabase Auth user does **not** automatically grant any operational role.
2. **Database RPC Role Source (`app_metadata.role` Only):**
   - Verified in live `pg_get_functiondef` of `process_quota_dispense`, `register_customer`, `process_warehouse_mutation` and migration `006` RPCs (`get_operational_snapshot_page_v4`, `get_operational_sync_data_v4`, `verify_customer_registration_v4`, `issue_kiosk_token`, `revoke_kiosk_token`, `report_offline_reconciliation_conflict`):
     - Session claim gate: `COALESCE(NULLIF(current_setting('request.jwt.claim.role', true), ''), v_jwt_claims ->> 'role', '')` **must equal `'authenticated'`** (raises `42501` otherwise).
     - Application role gate: `v_app_role := COALESCE(v_jwt_claims #>> '{app_metadata,role}', '')`. **Client-editable `user_metadata` is completely ignored.**
     - Actor audit attribution (`changed_by` / `operator_id` / `issued_by`): reads verified JWT `sub` (`COALESCE(NULLIF(current_setting('request.jwt.claim.sub', true), ''), v_jwt_claims ->> 'sub')`), never allowing client spoofing of `changed_by`.
3. **Database Table Access Control (`pg_policies` & ACLs):**
   - All `004`/`006` internal & kiosk tables (`change_feed_tracker`, `operational_change_feed`, `offline_reconciliation_conflicts`, `transaction_audit_trail`, `customer_registration_requests`, `kiosk_tokens`, `kiosk_rate_limits`) have RLS enabled, `0` permissive policies, and `0` grants to `PUBLIC`, `anon`, `authenticated`, or `service_role`.
   - `customers`, `logs`, and `warehouse_logs` temporarily keep only `"Staging read ..."` `SELECT` policies (`anon`, `authenticated`) until Migration `007` Contract.
4. **Pruning RPC Special Gate (`prune_operational_change_feed_v4`):**
   - `EXECUTE` granted only to `postgres, service_role`.
   - Internal check validates `(SESSION_USER = 'authenticator' AND v_jwt_role = 'service_role') OR (SESSION_USER IN ('postgres', 'supabase_admin') AND v_raw_claims IS NULL AND v_claim_role IS NULL)`.
5. **Public Kiosk Special Gate (`get_public_kiosk_quota`):**
   - `EXECUTE` granted only to `postgres, anon`. Enforces `v_jwt_role = 'anon'` and enforces 50 hits/60s rate limit per hashed IP bucket.
6. **Frontend Authorization Extraction ([dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html#L11208-L11475)):**
   - `VALID_OPERATIONAL_ROLES = ['cashier', 'supervisor', 'warehouse_admin', 'admin']`.
   - `loginWithSupabase` (`L11303-L11305`) and `refreshSupabaseSession` (`L11370-L11372`) pass **only** `resData.user?.app_metadata?.role` and `claims.app_metadata?.role` into `extractStrictAppRole(...)`. Unrecognized/missing roles resolve to `null`, causing `getSupabaseHeaders(..., true)` (`L11430`) to fail closed (`403`) on operational/sync RPCs.

---

## 4. Secure Credential Handling Procedure

1. **Zero In-Chat Secrets Policy:** Never paste UAT user passwords, bearer JWTs, refresh tokens, or `service_role` keys into chat prompts, terminal stdout, markdown reports, screenshots, or browser devtools logs.
2. **Untracked Runtime Storage Only:**
   - [cekkuota-kk/.gitignore](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/.gitignore) already excludes `.env`, `.env.local`, `.env.*.local`, and `_archive_audit_cleanup/`.
   - Store UAT runtime inputs **strictly** in an untracked local file `.env.uat.local` (readable solely by local Node/PowerShell runner at test execution time) OR inject directly into volatile OS session environment variables right before running the UAT harness.
   - Expected **non-committed** variable names (empty template):
     - `STAGING_URL=https://evexaeyryfayfbffzzhh.supabase.co`
     - `UAT_CASHIER_EMAIL`, `UAT_CASHIER_PASSWORD`
     - `UAT_WAREHOUSE_EMAIL`, `UAT_WAREHOUSE_PASSWORD`
     - `UAT_SUPERVISOR_EMAIL`, `UAT_SUPERVISOR_PASSWORD`
     - `UAT_ADMIN_EMAIL`, `UAT_ADMIN_PASSWORD`
     - `STAGING_SERVICE_ROLE_KEY` *(optional server-side-only variable for backend-only `service_role` check; **never** load in browser or `config.js`)*
3. **Redaction Guardrails:** Automated UAT scripts must print only HTTP status codes, role names, structural JSON status keys, and sanitized pass/fail counters — never `Authorization` headers, tokens, passwords, or citizen PII.
4. **Post-UAT Deprovisioning:** After UAT completion, delete `.env.uat.local`, clear shell environment variables, revoke synthetic kiosk tokens (`revoke_kiosk_token`), and delete/disable all 4 UAT accounts in Supabase Staging Dashboard.

---

## 5. Owner Provisioning Instructions Still Required (Supabase Dashboard)

Perform the following actions **strictly inside staging project `evexaeyryfayfbffzzhh` (`CATAT KUOTA KK - STAGING`)**:

1. **Create 4 Staging UAT Users** (Supabase Dashboard → **Authentication → Users → Add user → Create new user**):
   - Use the 4 synthetic UAT emails listed in Section 2, generate temporary strong random passwords (kept locally in your password manager / `.env.uat.local`, **not** pasted into chat), and check **Auto Confirm User**.
2. **Assign Authoritative `app_metadata.role` on Each User** (Supabase Auth Dashboard user metadata editor **or** SQL `auth.admin` / Dashboard Edit App Metadata — **NOT `user_metadata`**):
   - UAT Cashier → `App Metadata`: `{"role": "cashier"}`
   - UAT Warehouse → `App Metadata`: `{"role": "warehouse_admin"}`
   - UAT Supervisor → `App Metadata`: `{"role": "supervisor"}`
   - UAT Admin → `App Metadata`: `{"role": "admin"}`
   - Confirm each user has **empty or non-authoritative `user_metadata`** (optional negative tampering check: putting `{"role": "admin"}` inside `user_metadata` on the cashier UAT user must remain completely ignored!).
3. **Optional `service_role` Automated Pruning UAT Secret:**
   - If you also authorize Section 5 live PostgREST `service_role` boundary execution during UAT, place staging's `service_role` JWT exclusively into the server-side test runner environment (`$env:STAGING_SERVICE_ROLE_KEY` or `.env.uat.local`), **never** inside [config.js](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/config.js) or chat.
4. **Confirm Provisioning Readiness Without Sharing Secrets:**
   - Let the agent confirm via read-only `auth.users` catalog check (`id, email, raw_app_meta_data->>'role', email_confirmed_at`) that all 4 UAT users exist cleanly on `evexaeyryfayfbffzzhh`, then run the authenticated UAT test runner locally with credentials populated outside chat.
5. **Restore `dispatch-console.html` Expand Sync Tail Before `UAT-SOAK-01` (Source Drift Alert):**
   - Checksum inspection during Phase 4.3.2 discovered an external write to [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) at `2026-11-27 08:15:51` (`SHA256: 9E2E72CDA428F4257420ACAF13E1E1123EB86216F28FDDE2717CC5C8E56591E9`, `12,850` lines vs Phase 4.3 verified `8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734`).
   - While `CatatKuotaIDB` (`L4591`) and `stockRestricted` (`L5434-L8434`) remain intact, lines `11897-12849` reverted to pre-Phase-4.3 code (`GET /rest/v1/customers?select=*` at `L11901`, `GET /rest/v1/logs?select=*` at `L11902`, `GET /rest/v1/warehouse_logs?select=*` at `L11903`, `GET /rest/v1/customers?no_kk=eq...` at `L12275`, missing `get_operational_snapshot_page_v4`, `get_operational_sync_data_v4`, `verify_customer_registration_v4`, and `CatatKuotaIDB.initAndMigrateFromLocalStorage()` inside `bootstrapApp`). Per Phase 4.3.2 rules (*do not modify application source code*), this file was not edited in Phase 4.3.2; re-apply the Phase 4 Expand tail edits cleanly before running `UAT-SOAK-01`! (`kuota.html`, `config.js`, and migrations `004`–`006` remain checksum-identical to Phase 4.3.)

---

## 6. Service-Role Pruning Test Preparation (`prune_operational_change_feed_v4`)

Phase 4.3.2 strictly separates non-mutating verification from actual feed pruning mutation:

### A. Read-Only Authorization & Preflight Verification (Safe / Non-Mutating)
1. **Catalog & ACL Preflight (Already Verified):** `pg_proc.proacl` = `{postgres=X/postgres,service_role=X/postgres}`; zero direct DML/SELECT privileges to `service_role` on any `public` table; strict `SESSION_USER = 'authenticator' AND jwt_role = 'service_role'` guard inside body.
2. **Read-Only Candidate Preview Query (Already Executed cleanly in Phase 4.3.1):** Computed `current_hwm=1`, `current_min_retained_seq=2`, `buffer_ceiling=-4999`, `candidate_del_ceiling=NULL`, `candidate_row_count=0`, `expected_next_min_retained_seq=2`.
3. **Live PostgREST Rejection Checks:**
   - Verified in Phase 4.3.1 (`401`): `anon` key, missing `Authorization`, and malformed Bearer JWT are rejected.
   - Pending live UAT (`$env:UAT_*` required): invoke `POST /rest/v1/rpc/prune_operational_change_feed_v4` using genuine signed `authenticated` JWTs (`cashier`, `supervisor`, `admin`) and assert `401`/`403`/`42501`.
4. **Live `service_role` PostgREST Boundary Verification (Safe No-Op Scope When Seed/Buffer Applies):**
   - If `$env:STAGING_SERVICE_ROLE_KEY` is provided in secure local runtime:
     - Invoke `POST /rest/v1/rpc/prune_operational_change_feed_v4` with default `{}` (`p_retention_interval: '30 days', p_safety_buffer: 5000, p_batch_limit: 5000`) ONLY AFTER confirming via read-only preview that `candidate_row_count = 0` (`buffer_ceiling < min_retained_seq`), which verifies HTTP `200 {"status": "OK", "rows_deleted": 0, ...}` **without mutating any data**, PLUS assert direct `GET/DELETE /rest/v1/operational_change_feed` with `service_role` returns `401`/`42501` (`0` direct table ACLs!).
     - *(If `STAGING_SERVICE_ROLE_KEY` is not supplied in secure runtime, mark live HTTP `service_role` test `BLOCKED`.)*

### B. Actual Pruning Mutation Gate (Separate Explicit Owner Approval Required)
Actual feed row deletion (`rows_deleted > 0`) MUST **not** be run in Phase 4.3.2 or disguised as a dry-run. Running an actual pruning mutation test requires:
1. Explicit separate owner authorization for synthetic staging feed seeding + deletion.
2. Controlled synthetic feed dataset generated inside isolated test records (with exact pre-test and post-test `operational_change_feed` and `change_feed_tracker` row captures + backup recovery path).
3. Bounded parameters (`p_batch_limit <= 500`, `p_safety_buffer >= 1`, `p_retention_interval >= '1 day'`), verifying contiguous `min_retained_seq` progression (`prev_min -> max_deleted + 1`), absence of sequence gaps, and post-prune `get_operational_sync_data_v4` returning `CURSOR_EXPIRED` below `min_retained_seq - 1`.

---

## 7. Phase 4.3.1 Authenticated UAT Readiness Checklist

When provisioned credentials are loaded into secure local runtime (outside repo & logs), execute each test group below using genuine signed staging Auth JWTs (zero SQL `set_config` substitution):

| ID | Test Case | Expected Contract & Assertions | Pre-Execution Mode |
|---|---|---|---|
| `UAT-AUTH-01` | Login (`/auth/v1/token?grant_type=password`) + Refresh (`/auth/v1/token?grant_type=refresh_token`) across all 4 roles | HTTP `200`; `app_metadata.role` decoded strictly matches intended role; `user_metadata.role` (if altered/forged) ignored by both frontend `extractStrictAppRole` and backend RPCs | **BLOCKED** (needs 4 UAT accounts + creds) |
| `UAT-AUTH-02` | `anon`, missing Auth, malformed JWT, and genuine signed expired JWT (`exp` elapsed / invalidated) | HTTP `401` (`42501` or `PGRST301`) on all `authenticated`/`service_role` RPCs *(anon/missing/malformed already PASS; signed expired JWT pending real Auth session)* | **PARTIAL / BLOCKED** |
| `UAT-ROLE-01` | Cashier (`uat-cashier`) snapshot & delta (`get_operational_snapshot_page_v4`, `get_operational_sync_data_v4`) | `customers` & `logs` -> HTTP `200` (`stock_summary === null`); `warehouse_logs` & `stock_summary` & `process_warehouse_mutation` & `issue_kiosk_token` & `prune_operational_change_feed_v4` -> HTTP `401`/`403` (`42501`) | **BLOCKED** |
| `UAT-ROLE-02` | Warehouse Admin (`uat-warehouse`) boundaries | `warehouse_logs` & `stock_summary` -> HTTP `200` (`stock_summary` array present); `customers`, `logs`, `register_customer`, `process_quota_dispense`, `verify_customer_registration_v4`, `issue_kiosk_token`, `prune` -> HTTP `401`/`403` (`42501`) | **BLOCKED** |
| `UAT-ROLE-03` | Supervisor & Admin (`uat-supervisor`, `uat-admin`) permitted ops + synthetic write/verify/conflict | Full snapshot/delta (`customers`, `logs`, `warehouse_logs`, `stock_summary`), synthetic `register_customer` (`9999...`), `verify_customer_registration_v4` (`COMMITTED_MATCH`/`IDEMPOTENCY_CONFLICT`/`EXISTS_IDENTITY_CHECK`/`NOT_FOUND`), `report_offline_reconciliation_conflict` (`RECORDED`); `prune_operational_change_feed_v4` rejected `401`/`403` (`42501`) | **BLOCKED** |
| `UAT-KIOSK-01` | Kiosk full live lifecycle (`issue_kiosk_token` -> `get_public_kiosk_quota` active -> rotate `REPLACED` -> 50/min rate limit `429` -> `revoke_kiosk_token` -> invalid lookup + real browser DOM check) | Only synthetic KK; `get_public_kiosk_quota` returns Zero-PII payload (`0` occurrences of `no_kk`, `nama`, `member_id`, `detail`, address in HTTP JSON and [kuota.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/kuota.html) DOM); rotated token returns `token_status='REPLACED'`; revoked/invalid returns `ERR_INVALID_OR_UNAVAILABLE`; 51st hit returns `RATE_LIMITED`; all synthetic tokens revoked cleanly | **BLOCKED** |
| `UAT-PRUNE-01` | Service Role (`STAGING_SERVICE_ROLE_KEY`) vs `authenticated`/`anon` pruning boundary | `anon`/`authenticated` -> `401`/`403`; direct `/rest/v1/{operational_change_feed,change_feed_tracker}` DML -> `401`/`403` (`42501`); `service_role` RPC check (only if explicitly provided & pre-checked safe) returns HTTP `200` | **BLOCKED** |
| `UAT-SOAK-01` | Live Staging Authenticated Browser Soak in headless Edge ([dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) & [kuota.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/kuota.html)) | Network telemetry shows `0` direct `GET /rest/v1/{customers,logs,warehouse_logs}`; snapshot -> delta completes cleanly into IndexedDB `catat_kuota_kk_idb_v1`; offline write survives offline toggle & page reload (`in_flight -> pending`); operator switch (`cashier-1 -> cashier-2`) locks `AWAITING_ORIGINAL_OPERATOR`; timeout triggers `verify_customer_registration_v4`; zero dirty/tombstone loss | **BLOCKED** |

---

## 8. Readiness Status Summary

| Category | Status | Evidence / Reason |
|---|---|---|
| Staging target & `004`–`006` baseline verification | **PASS** | `evexaeyryfayfbffzzhh` healthy; PostgreSQL 17.12; migrations `004`–`006` applied; `007` not created/applied |
| Authorization-source audit (DB RPCs, ACLs, Triggers, Frontend) | **PASS** | `app_metadata.role` verified server/client-wide; `user_metadata` ignored; `0` auto-role triggers on `auth.*` |
| Unauthenticated / Malformed JWT HTTP rejection | **PASS** | Live PostgREST HTTP `401` (`42501` / `PGRST301`) across all 7 protected RPCs |
| Strictly Read-Only Pruning Preview (`SELECT`-only) | **PASS** | `current_hwm=1`, `min_retained_seq=2`, `candidate_row_count=0`, `expected_next_min_retained_seq=2` |
| `dispatch-console.html` Phase 4 Expand Integrity | **FAIL (DRIFT)** | External save at `08:15:51` (`9E2E72CD...`) reverted `L11897-12849` back to direct `/rest/v1/{customers,logs,warehouse_logs}` GETs; must be restored before `UAT-SOAK-01` |
| Dedicated Staging UAT Accounts Provisioned (`4/4` roles) | **FAIL** | Only 2 pre-existing personal/operator accounts exist (`supervisor`, `cashier`); `warehouse_admin` & `admin` absent |
| Secure Non-Repo Runtime UAT Passwords Available | **BLOCKED** | Zero staging test passwords provisioned in runtime env / `.env.uat.local` |
| Live Authenticated UAT (`UAT-AUTH-*`, `UAT-ROLE-*`, `UAT-KIOSK-01`, `UAT-PRUNE-01`, `UAT-SOAK-01`) | **NOT RUN** | Awaits owner provisioning, secure local credential injection, & frontend tail restore |

---

**FINAL READINESS DECISION:** **`BLOCKED — OWNER PROVISIONING REQUIRED`**
