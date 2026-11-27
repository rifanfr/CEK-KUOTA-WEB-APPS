# PHASE 4.3.4 — AUTHENTICATED STAGING UAT EXECUTION REPORT

**Project:** Catat Kuota KK  
**Target Environment:** `evexaeyryfayfbffzzhh` (`CATAT KUOTA KK - STAGING`, `ap-southeast-1`, `PostgreSQL 17.12.0.000`)  
**Baseline Accepted:** Phase 4.3 + 4.3.1 + 4.3.2 + 4.3.3 (`dispatch-console.html` SHA256 `8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734`)  
**Migration 007 Status:** **NOT EXECUTED**  
**Production Isolation:** `jziahfqjawqivesknkms` untouched (`0` accesses)  
**Final Decision:** **`BLOCKED — AUTHENTICATED UAT INCOMPLETE`**

---

## 1. Mandatory Preflight Summary

All technical baseline invariants passed verification at `2026-11-27T08:26:58+07:00`, while **dedicated staging UAT account provisioning (`PRE-06`) remains unfulfilled**:

- Staging ref `evexaeyryfayfbffzzhh` confirmed active and healthy (`https://evexaeyryfayfbffzzhh.supabase.co`).
- Restored frontend hashes verified bit-for-bit:
  - [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html): `8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734`
  - [kuota.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/kuota.html): `C5B8443B0EC18F1E42560434D71DF31D8BE64AE10E6DFEF366E865099ABC9E63`
  - [config.js](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/config.js): `34E8FFC8905306B8B82722A97B6208AA4A568F79296412469D42F514733CD5C2`
- Active Supabase migrations: `20261126153951` (`004`), `20261126154914` (`005`), `20261127004356` (`006`); Migration `007` absent.
- Three Expand read policies active (`"Staging read customers"`, `"Staging read logs"`, `"Staging read warehouse_logs"`).
- `auth.users` still contains **only** the two pre-existing personal/operator accounts (`gimelbersama@gmail.com` [`supervisor`] and `rfrtoolsofficial@gmail.com` [`cashier`]); zero dedicated UAT users (`cashier`, `warehouse_admin`, `supervisor`, `admin`) exist, and zero runtime UAT credentials or staging `service_role` secret exist in `.env*` or process environment variables.
- Per safety rules, existing operator accounts were **not** used and SQL `set_config` JWT simulation was **not** substituted for HTTP tests.

---

## 2. Test Execution Matrix

| Test ID | Execution Context | Expected Result | Observed Result | Status | Sanitized Evidence Reference |
|---|---|---|---|---|---|
| `PRE-01` | Supabase MCP `get_project` on `evexaeyryfayfbffzzhh` | Active staging project confirmed; production untouched | `id=evexaeyryfayfbffzzhh`, `ACTIVE_HEALTHY`, `PostgreSQL 17.12.0.000` | **PASS** | Phase 4.3.4 MCP `get_project` output (`08:26:53`) |
| `PRE-02` | PowerShell `Get-FileHash -Algorithm SHA256` on frontend files | `dispatch-console.html` equals `8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734` | Exact hash match across `dispatch-console.html`, `kuota.html`, `config.js` | **PASS** | Phase 4.3.4 `Get-FileHash` stdout (`08:27:09`) |
| `PRE-03` | Supabase MCP `list_migrations` | `004`–`006` present; `007` absent | `004`, `005`, `006` listed; `007` absent | **PASS** | Phase 4.3.4 `list_migrations` output (`08:26:56`) |
| `PRE-04` | Supabase MCP `execute_sql` on `pg_policies` | 3 Expand `Staging read ...` policies active | `expand_policies = 3` | **PASS** | Phase 4.3.4 `execute_sql` preflight (`08:26:58`) |
| `PRE-05` | Supabase MCP `execute_sql` baseline table counts | Known baseline row counts preserved | `customers=2, logs=0, warehouse_logs=2, audit=14, reg_req=3, change_feed=0, kiosk_tokens=0, kiosk_rl=1, conflicts=0` | **PASS** | Phase 4.3.4 `execute_sql` preflight (`08:26:58`) |
| `PRE-06` | `auth.users` inspection + `.env*` & env var presence check | 4 dedicated staging UAT accounts (`cashier`, `warehouse_admin`, `supervisor`, `admin`) provisioned with secure local runtime creds | Only 2 pre-existing personal accounts (`2026-11-23`); `warehouse_admin`/`admin` missing; `0` `.env.uat.local` / `$env:UAT_*` | **BLOCKED** | Phase 4.3.4 `execute_sql` `auth_users` + `Get-ChildItem` (`08:26:58–08:27:09`) |
| `UAT-AUTH-01` | Live HTTPS `/auth/v1/token` password + refresh (`cashier`, `warehouse_admin`, `supervisor`, `admin`) | Signed staging JWTs issued & refreshed with strict `app_metadata.role` | Stopped at `PRE-06`; required UAT accounts & passwords unavailable | **BLOCKED** | Pending owner provisioning per [PHASE_4.3.2_UAT_PROVISIONING_READINESS.md](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/PHASE_4.3.2_UAT_PROVISIONING_READINESS.md) |
| `UAT-AUTH-02A` | Live HTTPS PostgREST (`anon` key, missing `Authorization`, malformed Bearer JWT) across 7 protected RPCs + 6 internal/kiosk tables (`39` HTTP probes) | HTTP `401` (`42501` or `PGRST301`) on every probe | `39/39` returned HTTP `401` (`42501` for `anon`/missing auth; `PGRST301` for malformed JWT) | **PASS** | [unauth_negative_http_results.txt](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_4_evidence/unauth_negative_http_results.txt) |
| `UAT-AUTH-02B` | Live HTTPS PostgREST genuine signed expired JWT rejection | HTTP `401` rejection | Not run; cannot obtain real signed staging JWT without UAT account credentials | **NOT RUN** | Blocked by `PRE-06` |
| `UAT-OP-CASHIER` | Live HTTPS PostgREST RPC suite with dedicated `cashier` JWT | Snapshot/delta return `customers` & `logs` (`stock_summary=null`); verify works; warehouse/kiosk/prune rejected `401`/`403` | Not run (`cashier` UAT credentials unavailable; existing operator account prohibited) | **BLOCKED** | Blocked by `PRE-06` |
| `UAT-OP-WAREHOUSE` | Live HTTPS PostgREST RPC suite with dedicated `warehouse_admin` JWT | Snapshot/delta return `warehouse_logs` & `stock_summary`; customer/log/dispense/verify/kiosk/prune rejected `401`/`403` | Not run (`warehouse_admin` user absent in staging `auth.users`) | **BLOCKED** | Blocked by `PRE-06` |
| `UAT-OP-SUPERVISOR` | Live HTTPS PostgREST RPC suite with dedicated `supervisor` JWT | Full snapshot/delta, synthetic `verify_customer_registration_v4`, `report_offline_reconciliation_conflict`, `issue_kiosk_token`; `prune` rejected | Not run (dedicated `supervisor` UAT user/password unavailable; existing operator account prohibited) | **BLOCKED** | Blocked by `PRE-06` |
| `UAT-OP-ADMIN` | Live HTTPS PostgREST RPC suite with dedicated `admin` JWT | Operational/kiosk RPCs allowed; `prune_operational_change_feed_v4` rejected | Not run (`admin` user absent in staging `auth.users`) | **BLOCKED** | Blocked by `PRE-06` |
| `UAT-KIOSK-INVALID` | Live HTTPS PostgREST `anon` `POST /rest/v1/rpc/get_public_kiosk_quota` with invalid token | HTTP `200`, uniform `ERR_INVALID_OR_UNAVAILABLE`, zero PII | Returned HTTP `200 {"status":"ERR_INVALID_OR_UNAVAILABLE","message":"Token kartu kuota tidak valid atau tidak tersedia."}` | **PASS** | [unauth_negative_http_results.txt](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_4_evidence/unauth_negative_http_results.txt) |
| `UAT-KIOSK-LIVE` | Authenticated `supervisor`/`admin` token issuance -> active check -> rotate `REPLACED` -> 50/min rate limit -> DOM Zero-PII check -> `revoke_kiosk_token` cleanup | Active/rotated status transitions cleanly, 51st hit `RATE_LIMITED`, zero PII in JSON & DOM, synthetic tokens revoked | Not run; blocked on `PRE-06` (`issue_kiosk_token`/`revoke_kiosk_token` require `supervisor`/`admin` Auth JWT) | **BLOCKED** | Blocked by `PRE-06` |
| `UAT-PRUNE-PREFLIGHT` | Read-only `SELECT` preview + `pg_proc` inspection on `prune_operational_change_feed_v4` | Non-mutating calculation & ACL confirmation (`0` direct `service_role` table grants) | `hwm=1, min_retained_seq=2, cutoff=2026-10-28 01:27:55.534371+00, buffer_ceiling=-4999, candidate_rows=0` | **PASS** | Phase 4.3.4 `execute_sql` pruning preview (`08:27:55`) |
| `UAT-PRUNE-UNAUTH` | Live HTTPS PostgREST `anon`, missing auth, & malformed JWT on `/rest/v1/rpc/prune_operational_change_feed_v4` | HTTP `401` rejection | `3/3` probes returned HTTP `401` (`42501` / `PGRST301`) | **PASS** | [unauth_negative_http_results.txt](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_4_evidence/unauth_negative_http_results.txt) |
| `UAT-PRUNE-SVC` | Live HTTPS PostgREST `service_role` & signed `authenticated` boundary test (+ separate approved pruning mutation if authorized) | `authenticated` rejected; `service_role` accepted strictly within bounded scope | Not run (`STAGING_SERVICE_ROLE_KEY` & UAT `authenticated` credentials unavailable) | **BLOCKED** | Blocked by `PRE-06` |
| `UAT-SOAK-BROWSER` | Real Chromium Edge authenticated soak on [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) (`cashier`, `warehouse_admin`, `supervisor`, `admin`) | Authenticated snapshot/delta, `0` direct REST GETs, offline reload recovery, dirty/tombstone safety, operator handoff, timeout verify RPC | Not run with authenticated staging sessions (Phase 4.3.3 already proved unauthenticated Edge IDB boot + live `kuota.html`; authenticated soak blocked on `PRE-06`) | **BLOCKED** | Blocked by `PRE-06` |
| `UAT-CLEANUP` | Post-probe staging `execute_sql` row count comparison | Baseline operational & synthetic counts untouched; zero leaked test rows | `customers=2, logs=0, warehouse_logs=2, kiosk_tokens=0, kiosk_rl=1` unchanged | **PASS** | Phase 4.3.4 `execute_sql` post-probe (`08:27:55`) |

---

## 3. Phase 4.3.5 Provisioning Capability Inspection & UAT Update

### A. Capability Inspection Outcome (`2026-11-27T08:30+07:00`)
- **`supabase_mcp` Tooling:** Exposes project/migration/SQL/publishable-key tools (`get_project`, `list_migrations`, `apply_migration`, `execute_sql`, `get_publishable_keys`), **with no Supabase Auth Admin user-creation endpoint** and **no `service_role` key access** (`get_publishable_keys` returns only `anon` and `sb_publishable_...`).
- **Local CLI / Plugin Auth / Runtime Secrets:** `list_plugin_accounts` reports zero plugin account sign-ins; `supabase` CLI is not installed; zero `SUPABASE_ACCESS_TOKEN`, `STAGING_SERVICE_ROLE_KEY`, `.env.uat.local`, or `$env:UAT_*` credentials exist in the runtime environment.
- **Why Raw `execute_sql` Auth Inserts Were Rejected:** Although `CURRENT_USER` (`postgres`) holds table privileges on `auth.users` and `auth.identities`, inserting raw rows directly into GoTrue internal tables bypasses sanctioned Auth Admin lifecycle/password provisioning, and Supabase MCP auto-cancels destructive cleanup SQL (`DELETE`/`DROP`) in `0.1s`, preventing automated teardown of SQL-inserted temporary accounts. Per Phase 4.3.5 Section 1, provisioning stopped cleanly without simulating accounts.

### B. Retained, Executed, & Blocked Tests Summary
- **Previously `PASS` Tests Retained (Unchanged Evidence):**
  - `PRE-01`, `PRE-02` ([dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) SHA256 `8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734`), `PRE-03` (`004`–`006` applied, `007` absent), `PRE-04` (`3` Expand policies), `PRE-05` (`2, 0, 2, 14, 3, 0, 0, 1, 0`), `UAT-AUTH-02A` (`39/39` HTTP `401` across protected RPCs/tables), `UAT-KIOSK-INVALID` (`HTTP 200 ERR_INVALID_OR_UNAVAILABLE`), `UAT-PRUNE-PREFLIGHT`, `UAT-PRUNE-UNAUTH`, `UAT-CLEANUP`.
- **Newly Executed in Phase 4.3.5 (`PASS`):**
  - `CAP-CHECK-01`: Audited `list_plugin_accounts`, `get_organization` (`mlnvgsigmdkmsmcxjgmx`, free tier), local `supabase` CLI / env vars, `auth.*` privileges, and re-verified baseline row counts + frontend SHA256 after no-op exit (`0` mutations occurred).
- **Remaining `BLOCKED` / `NOT RUN` Tests & Exact Prerequisites:**
  - `UAT-AUTH-01`, `UAT-AUTH-02B`, `UAT-OP-CASHIER`, `UAT-OP-WAREHOUSE`, `UAT-OP-SUPERVISOR`, `UAT-OP-ADMIN`, `UAT-KIOSK-LIVE`, `UAT-SOAK-BROWSER`: Blocked on owner provisioning of the 4 dedicated staging-only Auth users (`uat_cashier`, `uat_warehouse`, `uat_supervisor`, `uat_admin`) with `app_metadata.role` and local untracked runtime credentials.
  - `UAT-PRUNE-SVC`: Blocked on secure runtime availability of `STAGING_SERVICE_ROLE_KEY` (and `authenticated` UAT JWTs for live negative HTTP parity).

### C. Concise Owner Action Checklist (Required to Unblock Live UAT)
1. Open **Supabase Staging Dashboard (`evexaeyryfayfbffzzhh`) → Authentication → Users → Add user** and create 4 staging-only auto-confirmed accounts:
   - `uat_cashier` → `App Metadata`: `{"role": "cashier"}`
   - `uat_warehouse` → `App Metadata`: `{"role": "warehouse_admin"}`
   - `uat_supervisor` → `App Metadata`: `{"role": "supervisor"}`
   - `uat_admin` → `App Metadata`: `{"role": "admin"}`
2. Store those temporary passwords (and optionally staging `STAGING_SERVICE_ROLE_KEY` for `UAT-PRUNE-SVC` non-mutating check) in an untracked local `.env.uat.local` (ignored by [.gitignore](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/.gitignore)'s `.env.*.local`) or process env vars right before executing the automated HTTP/browser UAT runner — **never** paste them in chat or commit them to Git.
3. Re-run Phase 4.3.4 UAT, then delete temporary UAT accounts and `.env.uat.local` afterward.

---

## 4. Cleanup Verification & Final Migration 007 Readiness

- **Cleanup Verification (`08:30:54`):** Confirmed `customers=2`, `logs=0`, `warehouse_logs=2`, `transaction_audit_trail=14`, `customer_registration_requests=3`, `operational_change_feed=0`, `kiosk_tokens=0`, `kiosk_rate_limits=1`, `offline_reconciliation_conflicts=0`, `auth.users=2` (`0` synthetic users or records created; production `jziahfqjawqivesknkms` untouched).
- **Final Migration `007` Readiness:** **NOT READY — HOLD MIGRATION `007`** until `UAT-AUTH-01`, `UAT-AUTH-02B`, `UAT-OP-*`, `UAT-KIOSK-LIVE`, and `UAT-SOAK-BROWSER` pass against live staging with genuine authenticated sessions (`UAT-PRUNE-SVC` also required before signing off scheduled service pruning).

---

**FINAL DECISION:** **`BLOCKED — AUTHENTICATED UAT INCOMPLETE`**
