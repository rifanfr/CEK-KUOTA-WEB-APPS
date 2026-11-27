# PHASE 4.3.3 — SOURCE DRIFT INVESTIGATION & CONTROLLED RECOVERY REPORT

**Project:** Catat Kuota KK  
**Target:** Staging Project `evexaeyryfayfbffzzhh` (`CATAT KUOTA KK - STAGING`)  
**Baseline:** Phase 4.3 Approved Implementation + Phase 4.3.2 Drift Discovery  
**Mode:** STRICT SOURCE INTEGRITY INVESTIGATION & CONTROLLED RECOVERY  
**Final Source-Integrity Decision:** **`SOURCE INTEGRITY RESTORED — READY FOR AUTHENTICATED UAT`**

---

## 1. Evidence Preservation Record

Before modifying or recovering any workspace file, every artifact involved in the drift event was preserved byte-for-byte in `scratch\phase4_3_3_evidence\`:

| Preserved Artifact | Purpose | Size / Lines | Timestamp |
|---|---|---|---|
| [dispatch-console.drifted.20261127_081551.html](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_3_evidence/dispatch-console.drifted.20261127_081551.html) | Byte-for-byte copy of the drifted workspace file | `614,708` bytes / `12,850` lines (`LF`) | `2026-11-27 08:15:51` |
| [dispatch-console.html](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_preflight_backup/dispatch-console.html) (`phase4_3_preflight_backup`) | Step 0 pre-Phase-4.3 baseline (verified identical to `git show ff4b9ee:dispatch-console.html`) | `620,924` bytes / `13,056` lines (`LF`) | `2026-11-24 20:03:43` |
| [dispatch-console.approved_phase4_3.html](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_3_evidence/dispatch-console.approved_phase4_3.html) | Deterministic reconstruction of Step 0 Preflight + exact 16 Phase 4.3 edits (`#31..#46`) | `668,407` bytes / `14,120` lines (`LF`) | Reconstructed & hash-verified |
| [approved_vs_drifted.patch](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_3_evidence/approved_vs_drifted.patch) | Machine-readable unified diff (`22` hunks, `approved -> drifted`) | `2,371` lines | Phase 4.3.3 forensics |
| [drifted_to_approved_recovery.patch](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_3_evidence/drifted_to_approved_recovery.patch) | Minimal reverse unified recovery patch (`drifted -> approved`) | `22` hunks | Applied via `git -c core.autocrlf=false apply` |

---

## 2. Checksums & File Identity Comparison

| Revision / File | SHA256 | Bytes | Lines |
|---|---|---|---|
| Git `HEAD` (`ff4b9ee`) & Step 0 Preflight Backup | `B4347374B5B88B9BA8C78D9038EBAD2E0F5F42766957F903E2F06327962DADB8` | `620,924` | `13,056` (`LF`) |
| Drifted File (`08:15:51`) | `9E2E72CDA428F4257420ACAF13E1E1123EB86216F28FDDE2717CC5C8E56591E9` | `614,708` | `12,850` (`LF`) |
| Approved Phase 4.3 Baseline (Reconstructed & Verified) | `8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734` | `668,407` | `14,120` (`LF`) |
| Recovered Workspace [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) | **`8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734`** | `668,407` | `14,120` (`LF`) |
| Unchanged Companions ([kuota.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/kuota.html) / [config.js](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/config.js) / `004`–`006`) | `C5B8443B...` / `34E8FFC8...` / `B8EA9602...`, `4201DD32...`, `A49312B0...` | — | Unmodified |

---

## 3. Git History & Provenance Findings

- **Git Branch & Commit Lineage (`master`):**
  `fdeb9e2` (`baseline`) → `120f8bc` (`tahap-1`) → `ce45351` (`tahap-2a`) → `7df362a` (`outbox 500ms`) → `0910cfb` (`tahap-2b` SHA-256 PIN & duplicate check) → `ff4b9ee` (`HEAD`: `tahap-3` local vendor assets + dead DOM query cleanup).
- **Preflight Authentication:** `git show ff4b9ee:dispatch-console.html === phase4_3_preflight_backup/dispatch-console.html` (`true` bit-for-bit).
- **Phase 4.3 Baseline Authentication:** Re-applying the exact `16` logged Phase 4.3 `edit_file` calls (`#31..#46`) from the conversation transcript onto Step 0 preflight (`ff4b9ee`) produced **exact SHA256 `8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734`**, matching the Phase 4.3 verified deliverable bit-for-bit.
- **How the Drifted File Originated:** An external write at `2026-11-27 08:15:51` (immediately after Phase 4.3.1 metadata showed `dispatch-console.html` open in the external IDE) produced an uncommitted mixed state: it retained Phase 4.3 edits `#31..#40` (`CatatKuotaIDB`, `ConflictReviewManager`, `stockRestricted`), while regressing `22` hunks (`1,661` deletions, `391` insertions relative to approved Phase 4.3) back to older pre-`ff4b9ee`/pre-`0910cfb`/pre-`7df362a` and pre-Phase-4.3 code. No committed history in Git contained this mixed state; it was an uncommitted external editor/workspace overwrite.

---

## 4. Controlled Differential Analysis (`approved_vs_drifted.patch`)

Diff statistics: `22` hunks (`2,052` lines changed in `--stat`: `391 insertions(+)` / `1,661` deletions(`-`) in `approved -> drifted`). Line-by-line attribution of all `384` non-empty `+` lines present in `drifted.html`:
- `382` lines match historical commits `ff4b9ee`, `0910cfb`, `7df362a`, `ce45351`, or `dispatch-console.backup-user-checkpoint.html` verbatim.
- `2` lines (`Hunk #12` & `Hunk #18` log messages without `500ms`/identity verification) correspond verbatim to the pre-`7df362a` draft before `"hardening rekonsiliasi false-timeout dengan cek identitas dan jeda 500ms"`.
- **Unrelated Legitimate New Changes Found:** **`0`** (zero novel features or intentional post-Phase-4.3 patches existed in `drifted.html`).

---

## 5. Exact Missing Functionality vs Historical Regressions Found in `drifted.html`

### A. Disappeared Phase 4.3 Expand Security & Sync Functionality (Hunks `#9`–`#20`, `#22`)
1. **Direct REST Table Reads Re-Introduced (`L11901-11903`, `L12275`):** `syncWithSupabase` reverted to parallel `GET /rest/v1/customers?select=*`, `GET /rest/v1/logs?select=*`, `GET /rest/v1/warehouse_logs?select=*`; `callRegisterCustomerRPC` timeout fallback reverted to direct `GET /rest/v1/customers?no_kk=eq...` (missing `verify_customer_registration_v4`).
2. **Snapshot Pagination, Delta Sync, & Atomic IDB Reconciliation Removed (`Hunks #15, #22`):** `get_operational_snapshot_page_v4`, `get_operational_sync_data_v4`, frozen `cutoffDate`/`anchorSeq`, `SNAPSHOT_EXPIRED`/`CURSOR_EXPIRED`/`EPOCH_MISMATCH` handling, mid-snapshot dirty protection via `CatatKuotaIDB.commitReconciliationAtomically`, role-switch cursor invalidation (`last_synced_role`), and startup `CatatKuotaIDB.initAndMigrateFromLocalStorage()` in `bootstrapApp` all disappeared.
3. **Outbox Hardening & RPC Contracts Removed (`Hunks #9, #10, #11, #14, #16, #17, #19, #20`):** Removed `RPC_SIGNATURE_CONTRACTS` entries for v4 RPCs, `callRpcWithDeadlockRetry` (`40P01`/`40001`/`55P03`), `operatorUid` handoff lock (`AWAITING_ORIGINAL_OPERATOR`), `P0001`–`P0004` conflict escalation via `report_offline_reconciliation_conflict`, post-login `syncWithSupabase(true)` trigger, and `window` exports (`CatatKuotaIDB`, `ConflictReviewManager`, `getTombstones`, `STORAGE_KEYS`).

### B. Reverted `HEAD` (`ff4b9ee`, `0910cfb`, `7df362a`) Hardening & UI Functions (Hunks `#1`–`#8`, `#21`)
1. **Offline-First Vendor Assets Reverted (`Hunk #1`):** `vendor/tailwind.cdn.js`, `vendor/lucide.min.js`, `vendor/qrcode.min.js`, `vendor/html5-qrcode.min.js` reverted to external CDNs only.
2. **SHA-256 PIN Security Reverted (`Hunks #3, #4, #6, #7, #8`):** Removed `isSha256Hex`, `fallbackSha256Hex`, `hashPinSHA256`, `verifyPinAgainstStored`, plaintext PIN removal in Settings DOM, and async PIN hashing on `saveSettings`.
3. **CR80 Card Preview, Kiosk Preview Modal & Helpers Wiped (`Hunk #5`):** Removed `17` functions (`switchCardPreviewSide`, `downloadCardPNG`, `downloadActiveCardPNG`, `handleReportLostCard`, `openQRCardModal`, `printCR80Card`, `showScanResultModal`, `showPublicKioskScreen`, `roundRect`, etc.), breaking global handler exports.
4. **Edit KK Duplicate Name Check Removed (`Hunk #21`):** Removed `findDuplicateNameCustomer` guard during customer edit, plus minor responsive layout guards in `Hunk #2`.

---

## 6. Recovery Patch & Verification Status

- Generated [drifted_to_approved_recovery.patch](file:///C:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/brain/515c4d75-d755-432d-85fc-9901522dc941/scratch/phase4_3_3_evidence/drifted_to_approved_recovery.patch) (`22` hunks) from `drifted` (`9E2E72CD...`) to authenticated `approved_phase4_3` (`8A387359...`).
- Applied via `git -c core.autocrlf=false apply --whitespace=nowarn` onto [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) (preserving exact `LF` line endings so Windows CRLF conversion did not mutate bytes).
- Confirmed restored [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) matches **`SHA256: 8A387359FFB85AFA40D376ECD285A3DE3D24B1076E5FAD65D87F5A2A40581734`**, **`668,407` bytes**, **`14,120` lines**, **`0` CRLF**.

---

## 7. Regression Verification Results (After Final Recovery)

| Verification Layer | Method & Environment Scope | Result |
|---|---|---|
| JavaScript Syntax Verification *(Static)* | `new Function(...)` across all `8` `<script>` blocks of recovered [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html) | **PASS** (`8/8` blocks valid) |
| Direct REST / Prod URL Scan *(Static)* | `Select-String` across [dispatch-console.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html), [kuota.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/kuota.html), [index.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/index.html) | **PASS** (`0` direct `/rest/v1/{customers,logs,warehouse_logs}` endpoints; `0` `jziahfqjawqivesknkms` occurrences; RPC endpoints verified at `L12811, L13399, L13433, L13467, L13570` and [kuota.html](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/kuota.html#L259)) |
| Divergence Regression Suite *(Mocked Node VM)* | `node scripts/test_customer_registration_divergence.js` (`7` scenarios) | **PASS** (`7/7` scenarios passed, exit `0`) |
| Phase 4 Expand E2E Suite *(Mocked IDB/Lock/Fetch VM)* | `node .../test_phase4_expand_e2e.js` (`6` scenario groups: IDB migration/`in_flight` recovery, frozen-cutoff pagination + `SNAPSHOT_EXPIRED` restart + mid-snapshot dirty protection, `CURSOR_EXPIRED` fallback + `cashier` `stockRestricted` dispense, `operatorUid` handoff + `40P01` retries + `P0003` escalation, `verify_customer_registration_v4`, `kuota.html` Zero-PII/429) | **PASS** (`6/6` groups passed, exit `0`) |
| Chromium Edge CDP E2E *(Real Headless Browser + Live Staging Anon Kiosk HTTPS)* | `node .../test_phase4_browser_edge_cdp.js` (`msedge.exe` CDP `Network.requestWillBeSent` telemetry) | **PASS** (real Edge IDB `idb_migrated: true`, `in_flight -> pending`, live `kuota.html` -> `evexaeyryfayfbffzzhh.supabase.co/rest/v1/rpc/get_public_kiosk_quota`, `0` direct REST GETs, exit `0`) |
| Authenticated Staging UAT *(Live PostgREST Operator JWTs)* | Not executed in Phase 4.3.3 (prohibited by Phase 4.3.3 scope; awaiting Phase 4.3.2 credentials) | **NOT RUN** (per Phase 4.3.3 boundary & Phase 4.3.2 prerequisite) |

---

## 8. Remaining Owner Actions / Preventive Guard

1. **Close / Reload Any Stale Open IDE Tabs Holding `dispatch-console.html`:** Prevent external editor auto-save buffers from re-overwriting the recovered disk file before commit/UAT.
2. **Proceed to Phase 4.3.2 Provisioning:** Provision the 4 staging-only UAT accounts (`cashier`, `warehouse_admin`, `supervisor`, `admin`) with explicit `app_metadata.role` and untracked runtime credentials per [PHASE_4.3.2_UAT_PROVISIONING_READINESS.md](file:///c:/Users/Rifan%20Fakhrur%20Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/PHASE_4.3.2_UAT_PROVISIONING_READINESS.md) before launching live Phase 4.3.1 authenticated UAT. (Still do **not** run Migration `007` until UAT passes.)

---

**FINAL SOURCE-INTEGRITY STATUS:** **`SOURCE INTEGRITY RESTORED — READY FOR AUTHENTICATED UAT`**
