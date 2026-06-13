# TMC Labour Compliance & Management — Claude Code Reference

> **⚠️ SYSTEM IS LIVE IN PRODUCTION**
> Real users and real data. Every change must be tested mentally before committing.
> Never break existing functionality. When in doubt, ask before implementing.

> **📋 SELF-IMPROVING REFERENCE — MANDATORY**
> This file is the single source of truth for how this codebase works. When a bug is
> found, a constraint is discovered, or a pattern proves brittle, **document it here
> immediately** in the "Lessons Learnt & Bug Fixes Log" section at the bottom. Then
> promote the rule into the relevant checklist or critical-rules section above so it
> prevents the same class of mistake in future features — not just in the specific
> case that surfaced it. The log entry records what happened; the promoted rule
> prevents recurrence. Both are required.

---

> ## 🔒 IMPORTANT — MULTI-TENANT DATA ISOLATION IS A HARD INVARIANT
>
> This app is **pooled multi-tenant**: every organisation's data lives in the
> same Supabase tables, separated only by an `org_id` column and RLS. A single
> mistake here exposes one customer's worker PII (passports, VOGs, BSNs) to
> another. A cross-org leak is the most severe class of bug in this system.
> **Every change must preserve these invariants. Never weaken one for convenience.**
>
> **Database (the primary guard — never rely on the app alone):**
> 1. **Every tenant table has `org_id` AND RLS enabled AND only org-scoped policies.** A table with an `org_id` column but `relrowsecurity = false`, or with any extra `USING (true)` / role-wide policy, is a leak. RLS policies are **permissive and OR together** — one wide policy defeats all others.
> 2. **When adding a table:** add `org_id uuid` (FK organisations), `ENABLE ROW LEVEL SECURITY`, and exactly two policies — `FOR SELECT … USING (org_id = current_org_id())` and `FOR ALL … USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id())`. Then update `sbCanWriteTable`, `sbLoadAll`, and the `org_id:oid` stamp in `sbPersistAll`.
> 3. **Never drop RLS policies by a guessed name list.** Enumerate `pg_policies` and drop them all, then recreate (see `fix_rls_rebuild_all_policies.sql`). Legacy/Supabase-template names are unpredictable and survive name-based drops.
> 4. **`SECURITY DEFINER` functions BYPASS RLS.** Any such function that touches tenant tables must scope org **manually** and derive `org_id` from a trusted source (the matched row or `auth.uid()`), never blindly from a caller-supplied parameter. Add `SET search_path = public`. Worker-portal RPCs must require a concrete `p_org_id` (reject NULL — NULL = "match any org" is a cross-org hole for direct anon API callers).
> 5. **Service-role code (edge functions) bypasses RLS entirely** — it MUST filter every query by `org_id` and loop per-org. Never select a tenant table service-side without an `org_id` filter.
>
> **Application (`app.html`):**
> 6. **Never resolve a logged-in user's org to `SITE_ORG_ID` as a fallback.** Only the explicit owner-email override may use `SITE_ORG_ID`. An unassigned user resolves to `currentOrgId = null` and is gated out of all load/sync (`sbLoadProfile`, `sbLoadAll`, `sbPersistAll`, `sbBoot`).
> 7. **Never seed default/demo data into a new org** (no fake projects/workers). Seeds get persisted into whatever org is active.
> 8. **localStorage caches (`tmc_*`/`btm_*`) are global to the browser, not per-org.** They must be wiped on logout, on the no-workspace gate, and on org switch (`sbClearLocalCache`, `wf_cache_org` marker).
> 9. Prefer `if(!currentOrgId) return;` over `org_id: currentOrgId || SITE_ORG_ID` in any NEW write helper — the `|| SITE_ORG_ID` pattern is brittle and only safe today because of the three gates.
>
> **Supabase Storage:**
> 10. **The `tmc-documents` bucket is shared across all orgs.** Document file paths must be namespaced by `org_id` (e.g. `${org_id}/workers/${wid}/…`) and storage RLS must check `(storage.foldername(name))[1] = current_org_id()::text`. Paths keyed only by worker-id are NOT org-isolated. *(See "Open isolation gaps" below — this is being remediated.)*
>
> **After ANY tenancy-related change, re-run this audit and confirm a fresh org sees zero rows:**
> ```sql
> -- (a) any tenant table with RLS OFF?  -> must return zero rows
> SELECT t.table_name FROM information_schema.columns c
> JOIN information_schema.tables t ON t.table_schema=c.table_schema AND t.table_name=c.table_name
> JOIN pg_class pc ON pc.relname=t.table_name
> JOIN pg_namespace n ON n.oid=pc.relnamespace AND n.nspname='public'
> WHERE c.table_schema='public' AND c.column_name='org_id'
>   AND t.table_type='BASE TABLE' AND pc.relrowsecurity=false;
> -- (b) any policy with a wide-open qual?  -> inspect every row
> SELECT tablename, policyname, cmd, roles::text, qual FROM pg_policies
> WHERE schemaname='public' ORDER BY tablename, policyname;
> ```
>
> ### Open isolation gaps (from the 2026-06 full audit)
> | Gap | Severity | Status |
> |---|---|---|
> | Storage bucket `tmc-documents` not org-scoped (whole-bucket `authenticated` read/write/delete; paths keyed by worker-id) | **CRITICAL** | ✅ **Fixed** — upload paths org-prefixed (`${org_id}/…`) in app.html + worker.html; `fix_storage_org_isolation.sql` drops the bucket-wide policies and adds org-scoped ones with a TMC grandfather. Worker PII (`workers/`, `worker-submissions/`, `compliance/`, `assignments/`, `tool-assignments/`) is now org-isolated. |
> | `daily-digest` edge function: service-role, no `org_id` filter, hardcoded TMC recipients | **CRITICAL** | ✅ **Fixed in code** — rewritten to loop per-org, filter every query by `org_id`, email each org's own compliance/owner address. **Must redeploy the edge function**; still do NOT schedule until redeployed. |
> | Storage: `issued-docs/` + `doc-templates/` remain **public read** (anon worker portal downloads them via signed URL; anon can't be org-scoped in RLS) | Warning (residual) | ⏳ Open — close via a SECURITY DEFINER edge function that verifies the worker owns the path before returning a signed URL, then make these two policies authenticated/org-scoped. Lower sensitivity (company-issued forms / blank templates), not worker PII. |
> | Stale single-param `get_worker_portal` + old `handle_new_user` in superseded migration files (re-runnable footguns; not org-scoped) | High (latent) | ✅ **Fixed** — 7 stale migration files (`worker_portal_anon_rpc.sql`, `update_worker_portal_rpc_resources.sql`, `fix_issued_documents_rls.sql`, `add_issued_documents.sql`, `combined_apply_all.sql`, `worker_portal_setup.sql`, `worker_resource_return_requests.sql`) now have prominent ⛔ DO NOT RUN headers explaining the cross-org risk. |
> | `submit_worker_document` RPC inserts submissions with `org_id = NULL` (orphaned, hidden from staff Approvals) | Warning | ✅ **Fixed** — `fix_worker_submission_org_id.sql` derives `org_id` from the worker row + backfills existing NULL-org submissions. |
> | `get_worker_portal` `p_org_id DEFAULT NULL` = "match any org" (direct anon API only; all app clients now pass a concrete org) | Warning | ✅ **Fixed in code** — `harden_get_worker_portal_org_id.sql` adds `RAISE EXCEPTION 'p_org_id is required'` guard and removes the `IS NULL OR` branch. Also adds `SET search_path = public`. **Must run this migration in Supabase SQL Editor.** |
> | ~20 `org_id: currentOrgId \|\| SITE_ORG_ID` write fallbacks in app.html | Warning | Safe via the load/sync/boot gates; convert to `if(!currentOrgId) return` opportunistically |

---

## Site Structure — HTML Files

| File | Purpose | Notes |
|---|---|---|
| `index.html` | **Marketing landing page** — work-force.nl root URL | Links to `login.html` and `worker.html`; no auth |
| `login.html` | **Management sign-in page** | Email/password + magic link; "Create workspace →" link to signup.html; redirects to `app.html` on success |
| `signup.html` | **Self-serve workspace creation** | 3-step flow: account → workspace slug → done; calls `create_workspace()` RPC; 30-day trial auto-starts |
| `worker.html` | **Worker portal** — standalone, email-entry login | Calls `get_worker_portal` RPC (anon); org resolved from `?org=<slug>` param; falls back to TMC SITE_ORG_ID |
| `vault.html` | **Worker Vault** — portable, worker-owned document vault (`vault.work-force.nl`) | **Authenticated** via Supabase magic link (passwordless, 30-day session). Calls `ensure_vault_account()` then `get_vault_portal()`. Merged read-only compliance + assignment view across ALL linked orgs. Free tier = view only; downloads gated to `plan='vault'` (Phase 2). Has its own `BRAND` constant block (rebrand single-source-of-truth). |
| `app.html` | **Management app** — compliance dashboard | All HTML/CSS/JS (~400KB); requires auth; formerly `index.html`. Worker rows have an "Invite to Vault" 🗂️ button (`inviteToVault()`) → `send-vault-invite` edge fn (falls back to a copy-link modal if not deployed). |

When making changes:
- UI changes to the management dashboard → edit `app.html`
- Login page changes → edit `login.html`
- Worker portal changes → edit **both** `worker.html` (standalone) **and** the embedded wp* section in `app.html`
- Marketing/landing page → edit `index.html`

## Architecture

- **Single-file management app**: All HTML, CSS, JS in `app.html` (~400KB). No build step, no framework.
- **Backend**: Supabase (auth, PostgreSQL database, Storage bucket `tmc-documents`)
- **Hosting**: GitHub Pages (served from `main` branch)
- **Git workflow**: develop on `claude/debug-error-400-S0q20`, then **immediately fast-forward merge to `main` and push both branches** in the same session. Never leave `main` behind. Every commit session ends with `main` = working branch.
- **Email**: Supabase Edge Function `daily-digest` → Resend API (`onboarding@resend.dev` sandbox; swap to own domain later)

---

## Critical Rules

1. **No local-only saves** — everything must persist to Supabase. `localStorage` is cache only.
2. **Document uploads are Supabase Storage only** — bucket `tmc-documents`. Never `dataUrl` at rest.
3. **Role-gated uploads**: only `admin` and `compliance` can upload/delete documents. All roles can download/view.
4. **`sbPersistAll` must never throw** — any new table upsert must be wrapped in `try/catch` so a missing table or permission error cannot crash the sync and break unrelated features (e.g. document uploads).
5. **New Supabase tables** always require a SQL migration in `migrations/` AND an update to `sbCanWriteTable` (add to both `complianceTables` and `plannerTables` arrays) AND to the `Promise.all` destructure in `sbLoadAll`.
6. **Before writing a new value to an existing column**, check for CHECK constraints: `SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = '<table>'::regclass AND contype = 'c';` — if a constraint would block the new value, add a migration to drop or widen it as part of the feature.
7. **Fields owned by edge functions** (`signature_status`, `signature_request_id`, etc.) must never appear in `sbPersistAll` writes. Load them read-only in `sbLoadAll`, display in UI, but never write back — the edge function is the sole writer.
8. **`worker.html` and `vault.html` must stay in parity.** These two files are the worker-facing products and must remain almost identical in UX, navigation structure, and feature set. Whenever a bug fix, UI improvement, or feature is applied to one, **immediately check whether the same change is needed in the other** before closing the task. This includes: download patterns, mobile layout fixes, navigation structure (tab bar, avatar button, sign-out placement), Apple HIG compliance, and any new worker-facing functionality. Do not mark a worker-portal task complete until the vault has been audited against the same change.

---

## Roles

| Role | Can do |
|---|---|
| `admin` | Everything |
| `planner` | Projects, assignments, resources, billing |
| `compliance` | Workers, documents, compliance docs |
| `viewer` | Read-only |

`sbCanWriteTable(table)` — controls write access per role. `sbActionForFunction(name)` — maps function names to action categories. `sbWrap(name)` — wraps a global function with auth + role check + `sbScheduleSync()`.

---

## Key State Variables

```js
let workers = []               // active + inactive workers
let projectStore = []          // projects
let projectAssignments = []    // PA assignments (all time periods)
let accomHistory = {}          // {wid: [{id, propId, startDate, endDate, chargeToOperative, weeklyChargeAmount}]}
let vehHistory = {}            // {wid: [{id, vehicleId, startDate, endDate, chargeToOperative, weeklyChargeAmount}]}
let accomCharges = []          // billing charge entries for accommodation
let vehCharges = []            // billing charge entries for vehicles
let resourceEvents = []        // property/vehicle event log entries
let properties = []            // accommodation properties
let vehicles = []              // fleet vehicles
let docSets = []               // document set definitions
let docSetItems = {}           // {setId: [docItem]}
let fileStore = {}             // {wid: {did: [file]}} — in-memory, synced to Storage
let deletedItems = []          // soft-delete archive
let currentWeekMonday          // selected week in Workers tab (used for date-aware modal)
let paGanttOffset = 0          // PA Gantt week offset from today
let ganttOffset = 0            // resource Gantt week offset
let billingOffset = 0          // billing tracker week offset
let paSortKey = 'project'      // PA table/gantt sort (default: project)
let paSortDir = 1
let resGanttSort = 'worker'
let resGanttProjectFilter = 'all'
```

---

## Key Functions

| Function | Purpose |
|---|---|
| `sbPersistAll()` | Full write of all state to Supabase |
| `sbLoadAll()` | Full read from Supabase on login |
| `sbScheduleSync()` | Debounced 650ms sync trigger |
| `sbCanWriteTable(table)` | Role-based write permission check |
| `sbUpsertRows(table, rows)` | Upsert helper — throws on error (wrap in try/catch for optional tables) |
| `renderTable()` | Render active workers table |
| `renderRoster()` | Render PA Gantt + All Assignments table |
| `renderPAGantt()` | PA Gantt chart |
| `renderPAList()` | All Assignments table (active + completed sections) |
| `renderResources()` | Render accom + vehicle tabs |
| `renderBillingTracker(type)` | Billing tracker grid |
| `renderResourceEventLog(type)` | Property/vehicle event log tables |
| `rebuildModal(id)` | Rebuild open worker detail modal (date-aware via `currentWeekMonday`) |
| `_paFilteredAssignments()` | PA assignments visible in current Gantt column range |
| `_paAllAssignments()` | All PA assignments (no date filter, for table) |
| `_paSortRows(list)` | Shared sort for PA assignments |
| `packLanes(assignments)` | Interval-packing for Gantt bar lanes |
| `ganttColumns(zoom, offset)` | Generate Gantt column dates |
| `colDuration(col, zoom)` | Duration of a Gantt column in ms |
| `paRefWeekMonday()` | Centre column of PA Gantt (reference week) |
| `goStatusAt(w, date)` | GO/WARNING/NOGO for worker at date |
| `scoreAt(w, date)` | Document compliance % at date |
| `docStatusAt(doc, date)` | 'ok'/'expiring'/'missing' for a doc at date |
| `currentPA(wid, refDate)` | Current/most-recent PA assignment at refDate |
| `currentAccom(wid, refDate)` | Current accommodation at refDate |
| `currentVeh(wid, refDate)` | Current vehicle at refDate |
| `weekMonday(date)` | Monday of the week containing date |
| `weekSunday(date)` | Sunday of the week containing date |
| `isoWeekKey(date)` | Returns `YYYY-Www` |
| `addWeeks(date, n)` | Date arithmetic |

---

## Supabase Tables

| Table | Notes |
|---|---|
| `workers` | `full_name, worker_type, reference, nationality, agency_name, document_set_id, doc_req (JSONB), notes, active` |
| `worker_documents` | `id = ${wid}__${doc_key}`, `worker_id, doc_key, status, expiry_date, issue_date, active` |
| `worker_document_files` | Files attached to worker documents |
| `document_sets` | Built-in and custom document set definitions |
| `document_set_items` | `id = ${setId}__${docKey}`, `name, category, icon, tip, required, built_in, sort_order` |
| `projects` | `name, client, project_manager, description, active` |
| `project_assignments` | `worker_id, project_id, start_date, end_date, rate, rate_type, notes, active` |
| `project_assignment_files` | Contract files for assignments |
| `properties` | Accommodation properties |
| `vehicles` | Fleet vehicles (`description` column, not `desc`) |
| `accommodation_assignments` | `worker_id, property_id, start_date, end_date, charge_to_operative, weekly_charge_amount, active` |
| `vehicle_assignments` | `worker_id, vehicle_id, start_date, end_date, charge_to_operative, weekly_charge_amount, active` |
| `accommodation_charges` | `assignment_id, week_key (YYYY-Www), charged, invoice_number, invoice_amount, active` |
| `vehicle_charges` | Same pattern as accommodation_charges |
| `resource_events` | `resource_type ('property'|'vehicle'), resource_id, event_date, event_type, description, created_by, active` |
| `compliance_documents` | Company-wide compliance docs (not worker-specific) |
| `deleted_items` | Soft-delete archive with full payload |
| `organisations` | `id, name, slug, logo_url, primary_color, owner_email, plan, trial_ends, stripe_customer_id, stripe_subscription_id, max_workers, warning_days, compliance_email` |
| `profiles` | `id (= auth.uid()), role, active, org_id` |
| `settings` | App-wide settings per org; `id = org_id` |
| `worker_accounts` | **Worker Vault** — portable worker identity; `id (= auth.uid()), email, full_name, plan ('free'\|'vault'), plan_expires, stripe_customer_id, stripe_subscription_id`. NOT org-scoped (worker-owned). |
| `worker_org_links` | **Worker Vault** — junction: one vault account → many org `workers` rows; `worker_account_id, worker_row_id, org_id, status ('invited'\|'active'\|'unlinked'), invited_by, linked_at`. Dual-scoped RLS (worker via `auth.uid()` + org via `current_org_id()`). |
| `vault_documents` | **Worker Vault** — worker-owned doc metadata + expiry; `worker_account_id, doc_key, display_name, file_path, expiry_date, issued_date, source ('org_approved'\|'worker_upload'), source_org_id, active`. Worker-scoped RLS (`auth.uid()`). |
| `vault_assignment_links` | **Worker Vault** — worker-owned contract copies; `worker_account_id, assignment_id, org_id, project_name, org_name, start_date, end_date, contract_status, file_path`. No rate/financial data. |
| `worker_document_sets` | **Per-worker set history** — tracks every document set ever applied to a worker. `workers.document_set_id` remains the primary requirements driver; this table is a management/history layer. `active` flag lets admins deactivate stale sets without deleting them. RLS: `org_id = current_org_id()`. Managed via the worker modal "Applied Document Sets" panel. |
| `worker_competencies` | **Competencies & Training** — org's competency catalogue; `id, org_id, competency_key, name, category, info_text, info_url, template_file_name, template_file_path, allow_issue, expiry_tracking, sort_order, active`. Org-scoped RLS. Managed in Settings → Competencies. |
| `worker_competency_assignments` | **Competencies & Training** — per-worker requirements; `id, org_id, worker_id, competency_id, required, notes, active`. One row per (worker, competency). Org-scoped RLS. Managed in worker modal Training panel. |
| `worker_competency_records` | **Competencies & Training** — evidence submissions; `id, org_id, worker_id, competency_id, file_path, file_name, issued_date, expiry_date, status ('pending'\|'approved'\|'rejected'), submitted_by, reviewed_by, review_notes, active`. Org-scoped RLS. Written by workers (portal/vault) and approved by admins. |
| `project_files` | **Project Files** — project-level file attachments (info docs, images); `id, org_id, project_id (TEXT, matches projects.id), file_name, file_path, caption, mime_type, size_bytes, visible_to_workers (bool, default true), sort_order, active, uploaded_by, created_at`. Org-scoped RLS. Storage under the **anon-readable** `project-files/{org_id}/{project_id}/...` prefix (unguessable random filenames; worker portal is anon so no edge-function broker). Remote-first writes (NOT in sbPersistAll); managed in the Edit Project modal. Surfaced to workers (portal + vault) in assignment detail, filtered to `visible_to_workers=true` + the worker's assigned projects. |

> **⚠️ Worker Vault tables use a DIFFERENT isolation model.** `worker_accounts`,
> `worker_org_links`, `vault_documents`, `vault_assignment_links` carry an `org_id`
> column (on some) but are **worker-scoped by `worker_account_id = auth.uid()`**, NOT
> `org_id = current_org_id()`. The vault belongs to the worker, not the org. The
> standard tenancy audit query (b) WILL flag their policies as "lacking
> `org_id = current_org_id()`" — that is **expected and correct**. Do NOT add
> org-scoped-only policies to these tables; it would break a worker's access to their
> own portable vault. `worker_org_links`/`vault_assignment_links` additionally grant
> org staff an org-scoped path (to invite/track) which ORs with the worker path —
> both sides are properly scoped, so there is no leak. Vault Storage lives under the
> `vault/{account_id}/...` prefix (worker-scoped via `foldername[2] = auth.uid()`),
> deliberately NOT under `workers/` (which TMC staff can grandfather-read).

---

## Built-in Document Sets

| Constant | UUID | Name |
|---|---|---|
| `SET_NL_ZZP` | `00000000-0000-0000-0000-000000000001` | NL – ZZP (Self-employed) |
| `SET_NL_BLUE` | `00000000-0000-0000-0000-000000000002` | NL – Blue Card (Employed) |
| `SET_BE_EMP` | `00000000-0000-0000-0000-000000000003` | BE – Employed |
| `SET_AT_EMP` | `00000000-0000-0000-0000-000000000004` | AT – Employed |

Document set item IDs in Supabase: `${setUUID}__${docKey}` e.g. `00000000-0000-0000-0000-000000000001__aansp`

---

## Migrations Needed (run in Supabase SQL Editor)

All files are in `migrations/`. These must be run manually in Supabase → Database → SQL Editor:

| File | Status | Purpose |
|---|---|---|
| `add_billing_tracker.sql` | ✅ Run | accommodation_charges + vehicle_charges tables |
| `add_worker_agency.sql` | ✅ Run | agency_name column on workers |
| `add_accom_weekly_charge.sql` | ✅ Run | weekly_charge_amount on accommodation_assignments |
| `add_resource_events.sql` | ⏳ Pending | resource_events table for property/vehicle event log |
| `add_org_logo_storage.sql` | ⏳ Pending — **run to enable logo uploads** | Storage RLS policies for `org-logos/` folder: public read (so `<img>` works without auth) + org-scoped authenticated INSERT (each org can only upload into their own subfolder). Drop the old same-path upsert approach — logos now use timestamped filenames so every upload is always a fresh INSERT. |
| `rename_aansp_insurance.sql` | ✅ Run | Renamed insurance doc in document_set_items |
| `schedule_daily_digest.sql` | ⏳ Pending | pg_cron schedule for daily email digest (replace placeholders first) |
| `worker_portal_anon_rpc.sql` | ⛔ DO NOT RUN | Superseded — single-param get_worker_portal leaks workers across orgs. File now has ⛔ header. |
| `worker_storage_policy.sql` | ⏳ Pending | Storage RLS policy allowing anon workers to upload to worker-submissions/ |
| `add_doc_set_item_info_fields.sql` | ⏳ Pending | Adds info_text and info_url columns to document_set_items |
| `add_reject_delete_days_to_settings.sql` | ⏳ Pending | reject_delete_days column on settings table (Approvals auto-delete) |
| `add_digest_sections_to_settings.sql` | ⏳ Pending — **run before implementing digest settings UI** | Adds `digest_sections JSONB` column to settings table. Stores per-org digest preferences: which sections enabled + look-ahead days per category. Backfills all existing orgs with defaults (all sections on). |
| `add_doc_set_item_template.sql` | ⏳ Pending | template_file_name + template_file_path on document_set_items (worker-downloadable form templates) |
| `worker_template_storage_policy.sql` | ⏳ Pending | Storage RLS policy allowing all sessions to read from doc-templates/ path |
| `add_worker_types_to_settings.sql` | ⏳ Pending | worker_types JSONB column on settings table for custom worker type definitions |
| `reactivate_orphaned_doc_parents.sql` | ⚠️ Superseded | First recovery attempt (found 0 — both parent & file were deactivated, not just the parent). Use reactivate_group_deleted_docs.sql instead. |
| `reactivate_stale_doc_set_items.sql` | ✅ Run | Reactivates document_set_items stale-deactivated by the group-delete bug. Run FIRST. |
| `reactivate_group_deleted_docs.sql` | ✅ Run | Reactivates worker_documents + files for doc_keys now active. Run SECOND (after stale_doc_set_items). |
| `reactivate_orphaned_files.sql` | ⏳ Pending | Final recovery: reactivates worker_document_files still inactive after the above two migrations (62 files: vca_vol×51, vca×7, vog/payroll/scc/twv×1 each). Run this last. |
| `retire_worker_document_file_deletions.sql` | ✅ Run | Retired 57 stale worker_document_file deletion records (the eternal-replay loop) and reactivated their files. |
| `add_permanent_delete_policies.sql` | ⏳ Pending | Adds DELETE RLS policies so the admin "Delete Permanently" button in Deleted Items can hard-delete. Required for that feature to work. |
| `block_new_signups_pending_approval.sql` | ⏳ Pending | Changes handle_new_user() trigger to set role='no_access' + active=FALSE so new signups require admin approval before getting any access. Run once — safe to re-run. |
| `add_worker_notification_settings.sql` | ⏳ Pending — **run to enable worker email reminders** | Adds `notify_workers_enabled` boolean to settings + creates `worker_notification_log` table (RLS-protected, org-scoped) used to throttle auto-reminders to once per 7 days per worker. Must be run before toggling the "Worker Email Reminders" setting. Also requires deploying the `send-worker-reminder` edge function. |
| `add_notify_worker_types_to_settings.sql` | ⏳ Pending — **run after add_worker_notification_settings.sql** | Adds `notify_worker_types text[]` to settings. Stores which worker type IDs receive auto reminders (empty = all types). |
| `add_multi_tenancy.sql` | ✅ Run | Phase 0: organisations table, org_id on all tables, org-scoped RLS, `current_org_id()` helper, TMC backfilled. **Idempotent** — every section drops its new policy names before CREATE (a mismatch between dropped/created names caused a 42710 collision on the first re-run; now fixed). |
| `add_org_id_indexes.sql` | ✅ Run | Phase 0: org_id indexes on all hot tables. Uses **plain `CREATE INDEX`** (not CONCURRENTLY) so it runs in the SQL Editor's transaction block. Fine at current scale; use CONCURRENTLY outside a transaction if rebuilding on a large busy table later. |
| `create_workspace_signup.sql` | ✅ Run | Phase 1: `create_workspace()`, `join_workspace()`, `check_slug_available()` RPCs; plan/billing columns on organisations; updated `handle_new_user()` trigger. `handle_new_user()` sets `SET search_path = public` and inserts into `public.profiles` (the trigger fires in the auth schema; without this it failed with "relation profiles does not exist", 42P01). `create_workspace()` guards `already_in_org`. |
| `fix_rls_rebuild_all_policies.sql` | ✅ Run | **CRITICAL security fix.** Drops EVERY policy on each app table dynamically (via `pg_policies`) and recreates only org-scoped ones. The original single-tenant app had a `USING(true)` read-all policy named `auth_only` (plus `workers_own`, `workers_staff`) whose names did not match `add_multi_tenancy.sql`'s fixed drop list, so they survived and ORed over the org policy — exposing every org's workers to any authenticated user. Always drop ALL policies dynamically, never by a guessed name list. |
| `fix_storage_org_isolation.sql` | ✅ Run | **CRITICAL.** Org-isolates the `tmc-documents` Storage bucket. Drops the whole-bucket `authenticated` read/write/delete policies (a cross-org worker-PII leak) and the public/auth issued-docs management policies; adds org-scoped policies keyed on `(storage.foldername(name))[1] = current_org_id()::text` with a TMC grandfather for existing non-prefixed files. |
| `fix_worker_submission_org_id.sql` | ✅ Run | Recreates submit_worker_document to derive org_id from worker row; backfills existing NULL-org submissions. |
| `harden_get_worker_portal_org_id.sql` | ⏳ Pending — **run to close the NULL p_org_id anon API hole** | Adds `RAISE EXCEPTION 'p_org_id is required'` guard to get_worker_portal + adds `SET search_path = public`. Prevents direct anon API callers from omitting p_org_id to match workers across all orgs. |
| `add_assignment_signed_review.sql` | ⏳ Pending — **run to route signed assignment contracts through Approvals** | Adds `signed_file_path` + `signed_at` to `project_assignments`. The dropbox-sign-webhook now parks a signed contract as `signature_status='pending_review'` (instead of auto-applying); admin approves in the Approvals "E-Signed Contracts" card, which attaches the signed PDF to the assignment. **Must also redeploy the `dropbox-sign-webhook` edge function.** |
| `add_contract_signed.sql` | ⏳ Pending — **run to enable manual "Mark as signed" toggle** | Adds `contract_signed boolean DEFAULT false` to `project_assignments`. App-owned field written by `sbPersistAll` (separate from `signature_status` which is edge-function-owned). Allows admins to mark manually-uploaded/wet-signed contracts as executed without going through Dropbox Sign. |
| `add_worker_vault.sql` | ⏳ Pending — **Worker Vault Phase 0** | Creates `worker_accounts`, `worker_org_links`, `vault_documents`, `vault_assignment_links` tables + `workers.vault_account_id` + `ensure_vault_account()` RPC. **Worker-scoped** RLS (`worker_account_id = auth.uid()`), NOT org-scoped — see the Worker Vault isolation note in the Tables section. `ensure_vault_account()` is SECURITY DEFINER (reads workers across all orgs by email but derives identity from `auth.uid()`), auto-links all matching `workers.email` rows to the account. Idempotent. |
| `add_vault_storage_policy.sql` | ⏳ Pending — **run after add_worker_vault.sql** | Storage RLS for the worker-owned `vault/{account_id}/...` prefix in `tmc-documents`. Worker-scoped via `(storage.foldername(name))[2] = auth.uid()::text`. Deliberately uses a `vault/` top-level prefix (NOT `workers/`) to avoid the TMC grandfather clause in `fix_storage_org_isolation.sql` leaking vault files to TMC staff. |
| `add_get_vault_portal.sql` | ⏳ Pending — **Worker Vault Phase 1** | `get_vault_portal()` SECURITY DEFINER RPC: the authenticated read path for `vault.html`. A vault worker's profile has `org_id = NULL` so `current_org_id()` is NULL and org-scoped RLS returns nothing — this RPC aggregates the worker's compliance docs + assignments across all their `worker_org_links` (scoped to `auth.uid()`). Excludes rate/financial data from assignments. |
| `add_vault_stripe_index.sql` | ⏳ Pending — **Worker Vault Phase 2** | Index on `worker_accounts.stripe_customer_id` for fast webhook lookups. The Stripe columns (`plan`, `plan_expires`, `stripe_customer_id`, `stripe_subscription_id`) already exist from `add_worker_vault.sql` — no new columns. |
| `add_worker_document_sets.sql` | ✅ Run | `worker_document_sets` table: per-worker set history & management layer. `workers.document_set_id` remains the single requirements driver. Includes RLS policies (org-scoped), indexes, and a backfill from current `workers.document_set_id`. Enables the "Applied Document Sets" panel in the worker modal. |
| `add_worker_competencies.sql` | ✅ Run (2026-06-12, via MCP) | Creates `worker_competencies`, `worker_competency_assignments`, `worker_competency_records` tables + `submit_worker_competency` + `submit_vault_competency` RPCs + storage RLS for anon competency uploads. Run first before the two portal extension migrations. |
| `add_vault_portal_competencies.sql` | ✅ Run (2026-06-12, via MCP) | Extends `get_vault_portal()` to return competency assignments + records per membership. **File now contains the FULL live definition + competency fields** — earlier draft was simplified and would have wiped live vault fields (see Lesson 31). Safe to re-run. |
| `extend_worker_portal_competencies.sql` | ✅ Run (2026-06-12, via MCP) | Extends `get_worker_portal()` to return competency assignments + records. **File now contains the FULL live definition + competency fields** — earlier draft dropped the rejected-submissions branch (see Lesson 31). Safe to re-run. |
| `add_project_files.sql` | ✅ Run (2026-06-12, via MCP) | Creates `project_files` table (org-scoped RLS) for project-level file attachments + two storage policies for the anon-readable `project-files/` prefix. Extends `get_worker_portal()` (top-level `project_files` array, visible-to-workers only, scoped to assigned projects) and `get_vault_portal()` (`project_files` per membership + `project_id` on each assignment). **Both RPC bodies are the FULL live definitions + project_files fields** (per Lesson 31). Safe to re-run. |
| `add_worker_profile_switcher.sql` | ✅ Run (2026-06-13, via MCP) | Adds `list_worker_profiles(p_email, p_org_id)` SECURITY DEFINER RPC (anon-callable, returns `[{id, full_name, reference, worker_type}]` for all active workers matching email in org). Extends `get_worker_portal()` with optional `p_worker_id uuid DEFAULT NULL` — pins a specific profile when multiple workers share one email; LIMIT 1 behaviour preserved when omitted. Old 2-param signature dropped before recreating. Safe to re-run. |
| `fix_doc_template_storage_write.sql` | ✅ Run (2026-06-12, via MCP) | **Storage fix.** Adds org-scoped INSERT/UPDATE/DELETE policies for the `doc-templates/{org_id}/...` prefix. `fix_storage_org_isolation.sql` had dropped the bucket-wide upload policy, and `doc-templates/` was kept public-READ only — so authenticated template uploads (document sets + competencies) were RLS-blocked for every org. App paths now prefix `org_id` as the 2nd segment: `doc-templates/{org_id}/{set_id}/{doc_id}/…` and `doc-templates/{org_id}/competencies/{key}/…`. Public read (`foldername[1]='doc-templates'`) untouched, so anon worker-portal downloads still work. Safe to re-run. |

---

## Worker Vault — Phase 2 (Monetization + Downloads)

Phase 2 adds the paid tier: Stripe subscription, server-enforced paywall, and working downloads. **Free tier (view-only) is untouched.**

### Edge functions (deploy to Supabase)
| Function | Auth | Purpose |
|---|---|---|
| `create-vault-checkout` | JWT (worker) | Creates/reuses a Stripe customer for the `worker_account`, opens a subscription Checkout session, returns `{url}`. Identity from `auth.uid()` only. |
| `create-vault-portal` | JWT (worker) | Opens the Stripe Billing Portal (update card, view invoices, cancel). Returns `{url}`. |
| `stripe-worker-webhook` | **none** (`verify_jwt=false`) | **Sole writer** of `worker_accounts.plan`/`plan_expires`/`stripe_subscription_id`. REQUIRED Stripe-Signature HMAC check (missing header = rejected). Handles `checkout.session.completed`, `customer.subscription.{created,updated,deleted}`. |
| `get-vault-file` | JWT (worker) | Download broker. Verifies `plan='vault'` (not expired) **server-side**, confirms the file belongs to a worker row the caller owns (via `worker_org_links`), returns a 120s signed URL. Types: `document` (by doc_key), `contract` (by assignment_id), `vault_doc` (worker-owned). |

### Required secrets (Phase 2)
- `STRIPE_SECRET_KEY` — Stripe API secret (set in Edge Function secrets)
- `STRIPE_VAULT_PRICE_ID` — the recurring Price ID for the worker Vault subscription
- `STRIPE_WEBHOOK_SECRET` — signing secret for the `stripe-worker-webhook` endpoint
- `VAULT_URL` — optional; defaults to `https://vault.work-force.nl` (checkout success/cancel + portal return)

> **Paywall is enforced server-side**, not just in the UI. `get-vault-file` returns `402 upgrade_required` for non-Vault accounts regardless of client. The UI lock is cosmetic; the broker is the real gate.

> **`worker_accounts.plan` is edge-function-owned** (Rule 7 class): only `stripe-worker-webhook` writes it. `vault.html` reads it via `get_vault_portal` and never writes plan/billing fields.

### Still pending in Phase 2 (durable copies)
`copy-to-vault` (Option B — durable permanent copies on org approval) is **not yet built**. Today `get-vault-file` brokers directly from the org's Storage copy, so a paid worker can download immediately — but if the org later deletes its file, the worker loses it. The permanence invariant (vault copy survives org deletion) requires the `copy-to-vault` function copying approved files into `vault/{account_id}/...` + a `vault_documents` row. Build next.

---

## Worker Vault — Phase 3 (Personal Documents + Share-to-Email)

Phase 3 adds the worker's own document layer and outbound sharing. **Paid (Vault) tier only** — both are gated server-side.

### What's new
- **My Files tab** (`vault.html` → `renderFiles`): a Vault worker uploads their own documents (passport, certificates, …) straight to `vault/{account_id}/...` Storage + a `vault_documents` row (`source='worker_upload'`). All client-side — the worker-scoped Storage + table RLS already permit it (no edge function needed for upload/download/delete). Worker sets `display_name`, `issued_date`, `expiry_date`; status pill follows the same green/amber/red expiry logic. Downloads use a direct client `createSignedUrl` (worker owns the path); delete is a soft `active=false`.
- **Share modal** (`openShareModal`/`sendShare`): tick any mix of compliance docs, contracts, and personal files → enter a recipient email → `send-vault-share` emails 7-day signed download links, **visually separating "verified by organisation" from "personal — not verified"** so a recipient never mistakes a self-uploaded file for an approved one.

### Edge function
| Function | Auth | Purpose |
|---|---|---|
| `send-vault-share` | JWT (worker) | Paid-gated (`402` otherwise). Resolves each selected item SERVER-SIDE from the worker's own records (never a caller path), signs a 7-day URL each, emails a branded summary split into verified/personal sections. Reuses `RESEND_API_KEY` + `DIGEST_FROM` — **no new secrets**. |

### Isolation / ownership notes
- Personal uploads are worker-owned: `vault_documents` RLS is `worker_account_id = auth.uid()`; Storage RLS is `foldername[1]='vault' AND foldername[2]=auth.uid()`. A worker can only ever touch their own `vault/` prefix.
- `send-vault-share` verifies ownership of every shared item before signing: `document`/`contract` must trace to a `worker_org_links` row the caller owns; `vault_doc` must have `worker_account_id = caller`.
- `source='org_approved'` vault docs (future `copy-to-vault`) are classed **verified** in shares; `worker_upload` are classed **personal/unverified**.

---

## Worker Vault — Phase 3b (Permanence + Submit-to-Employer)

Closes the two items left open after Phase 3. Both are **service-role edge functions**; identity always from the JWT.

### Edge functions
| Function | Auth | Purpose |
|---|---|---|
| `copy-to-vault` | JWT (worker **or** org staff) | Copies org-approved files into `vault/{account_id}/approved/{org_id}/{doc_key}/...` + a `vault_documents` row (`source='org_approved'`). Idempotent. Two shapes: `{worker_row_id, doc_key?}` (staff, on approval) or `{}` (worker self-backfill on sign-in). Single-worker mode authorises as either the linked vault account or org staff of the worker's org. |
| `submit-vault-to-org` | JWT (worker) | Worker pushes a vault doc into an employer's compliance queue: copies the file to `${org_id}/worker-submissions/{worker_row}/{doc_key}/...` and inserts a `worker_document_submissions` row (`status='pending'`) so it shows in that org's Approvals. Verifies the caller owns the vault doc AND is actively linked to the target org. |

### Wiring
- **app.html** `approveSubmission()` → fire-and-forget `_vaultCopyApproved(worker_id, doc_key)` → `copy-to-vault`. Non-fatal; no-op if the worker has no vault account.
- **vault.html** `enterVault()` → `backfillVaultCopies()` → `copy-to-vault {}` (silent permanence backfill on every sign-in).
- **vault.html** My Files → each personal doc has **📨 Submit to employer** → `openSubmitToOrgModal` → `submit-vault-to-org`.
- **get-vault-file** now falls back to the durable `vault_documents` (`source='org_approved'`) copy when the org's own file is gone — **this is the permanence payoff**.

### Notes
- `copy-to-vault` sets `workers.vault_account_id = auth.uid()` during self-backfill so the vault formally owns the copy.
- Org-approved vault copies are hidden from the **My Files** list and excluded from the share modal's "personal" group (they're already shown as compliance docs) to avoid duplicates.
- No new secrets, no new tables — reuses `vault_documents` + existing Storage RLS.

---

## Dropbox Sign Integration Reference

### How it works
1. **Sending**: `supabase/functions/send-for-signature/index.ts` calls the Dropbox Sign REST API (`https://api.hellosign.com/v3/signature_request/send`). Uses `DROPBOX_SIGN_API_KEY` env var. Stores `signature_request_id` in `project_assignments` or `issued_documents`.
2. **Receiving**: `supabase/functions/dropbox-sign-webhook/index.ts` — receives events from Dropbox Sign. `verify_jwt = false` in `config.toml` (Dropbox Sign sends no auth header).

### Webhook verification — HMAC-SHA256
```typescript
// CORRECT — HMAC-SHA256(key=api_key, message=event_time+event_type)
const cryptoKey = await crypto.subtle.importKey(
  'raw', new TextEncoder().encode(apiKey), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
)
const sigBuf = await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(eventTime + eventType))
// compare hex of sigBuf against payload.event.event_hash
```
**NOT** `SHA256(event_time + event_type + api_key)` — that's a plain digest, not an HMAC.

### Webhook payload parsing
Dropbox Sign sends real events as `multipart/form-data` with the JSON in a field named `json`:
```typescript
if (contentType.includes('multipart/form-data')) {
  const formData = await req.formData()
  payloadStr = formData.get('json') as string | null
} else {
  // url-encoded fallback for test pings
  const params = new URLSearchParams(await req.text())
  payloadStr = params.get('json') || params.get('payload')
}
```

### Event types to handle
| Event | When it fires | Action |
|---|---|---|
| `callback_test` | Manual test ping from dashboard | ACK only (no `signature_request` body) |
| `signature_request_signed` | Each individual signer signs | **Do NOT download PDF here** — files API returns 409 |
| `signature_request_all_signed` | All signers done, final PDF ready | Download PDF, upload to storage, update status |
| `signature_request_declined` | A signer declines | Update `signature_status = 'declined'` |
| `signature_request_canceled` | Request cancelled | Clear `signature_request_id` |

### ACK response
Dropbox Sign requires this exact response body or it will retry:
```typescript
new Response('Hello API Event Received', { status: 200, headers: { 'Content-Type': 'text/plain' } })
```
Always ACK even on errors — a non-200 causes Dropbox Sign to retry, which can cause duplicate processing.

### Metadata
When sending, embed routing metadata in the signature request:
```json
{ "type": "assignment", "reference_id": "<pa_id>", "org_id": "<org_id>", "worker_id": "<wid>" }
```
The webhook reads this to know which table/row to update.

### DB columns
- `project_assignments.signature_status` — `'none'|'pending'|'signed'|'declined'`
- `project_assignments.signature_request_id` — Dropbox Sign request ID
- These are **owned by the edge function** — never write them in `sbPersistAll`

---

## Dropbox Sign — Text Tags Reference

Source: [developers.hellosign.com/docs/walkthroughs/text-tags](https://developers.hellosign.com/docs/walkthroughs/text-tags)

### Tag anatomy

```
[type|req|signerN]                              ← minimal form
[type|req|signerN|Label]                        ← with visible label
[type|req|signerN|Label|uniqueID]               ← with label + ID (used for prefill)
[def:$groupName|type|req|signerN|Label|ID]      ← grouped / multiple-choice form
```

- **`req` / `noreq`** — required or optional. Unrecognised values default to `req`.
- **`signerN`** — `signer1`, `signer2`, … In this app the worker is always `signer1`.
- Field **width = literal bracket span** in the PDF. Field height cannot be set.
- **Tag must stay on one line** — if it wraps to a second line it is silently ignored.
- Bad/unknown type tokens also fail **silently** (no API error — only `signature_request_invalid` webhook event).
- API params required: `use_text_tags=1` and `hide_text_tags=1` (already set in `send-for-signature`).

### Single-value field tokens

| Token | Field | Notes |
|---|---|---|
| `sig` | Signature box | |
| `initial` | Initials box | ⚠️ **singular** — `initials` is invalid |
| `date` | Date-signed (auto-filled) | |
| `text` | Free-text input | width = bracket span; keep on one line |
| `check` | Single checkbox | ⚠️ **`checkbox` is invalid** |
| `hyperlink` | Clickable link | rarely needed |

### Multiple-choice / grouped fields

All options share the **same `$groupName`** — Dropbox Sign treats them as one group.
The number after `req` is the selection constraint.

| Constraint suffix | Meaning |
|---|---|
| `req1` | Exactly 1 must be selected (radio-style) |
| `req2` | Exactly 2 must be selected |
| `req1-3` | Between 1 and 3 must be selected |
| `noreq` | Any number (including zero) |

**Yes / No (pick exactly one):**
```
[def:$yn|check|req1|signer1|Yes]    ← place beside "Yes" in the PDF
[def:$yn|check|req1|signer1|No]     ← place beside "No" in the PDF
```
Both share `$yn` → enforces exactly one box ticked.

**Radio group (e.g. 3 options, pick one):**
```
[def:$choice|check|req1|signer1|Option A]
[def:$choice|check|req1|signer1|Option B]
[def:$choice|check|req1|signer1|Option C]
```

**Pick 1–2 from a list:**
```
[def:$skills|check|req1-2|signer1|Skill A]
[def:$skills|check|req1-2|signer1|Skill B]
[def:$skills|check|req1-2|signer1|Skill C]
```

To have **two independent groups** on the same page, use different `$names` (`$yn1`, `$yn2`, etc.).

### Silent-failure safety net
Add a `signature_request_invalid` handler to `dropbox-sign-webhook` — this is the only way
malformed tags surface as an error rather than disappearing. (Not yet implemented — see Lessons Learnt.)

---

## Email / Edge Function

- **Function**: `supabase/functions/daily-digest/index.ts`
- **Schedule**: Daily 07:00 UTC via pg_cron (after running `schedule_daily_digest.sql`)
- **Recipients**: Per-org from `settings.digest_emails`; falls back to `compliance_email` + `owner_email`
- **From**: `onboarding@resend.dev` (sandbox) — change `FROM` constant when own domain verified
- **Covers**: Expired/missing docs, expiring docs (60d window), assignments ending (14d), uncharged billing weeks
- **No email sent** if nothing to report

---

## Edge Function Development Checklist

Every new or modified edge function **must** satisfy all of the following before it is committed. These rules exist because gaps here have caused real production bugs.

### 1. CORS — required on ALL responses, not just OPTIONS
Browser-called functions must return CORS headers on every response path. Missing CORS on error responses causes "Failed to fetch" in the browser even when the function ran successfully.

```typescript
const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  })
}
// At the top of Deno.serve:
if (req.method === 'OPTIONS') return new Response(null, { headers: CORS })
```

### 2. JWT verification — always derive org from profiles, never from caller
```typescript
const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
if (!jwt) return json({ error: 'Unauthorized' }, 401)
const { data: { user }, error: authErr } = await sb.auth.getUser(jwt)
if (authErr || !user?.id) return json({ error: 'Unauthorized' }, 401)
const { data: profile } = await sb.from('profiles').select('org_id, role').eq('id', user.id).maybeSingle()
if (!profile?.org_id) return json({ error: 'No organisation' }, 403)
const orgId = profile.org_id  // NEVER trust a caller-supplied org_id
```

### 3. Service-role functions — filter every query by org_id
Functions using `SUPABASE_SERVICE_ROLE_KEY` bypass RLS entirely. Every `from(table)` call must include `.eq('org_id', orgId)` or loop per-org. A single missing filter is a cross-org data leak.

### 4. Webhook functions — always verify the signature
For inbound webhooks (e.g. Dropbox Sign, Stripe), HMAC or secret verification must be **required**, not optional. A missing header should reject the request — not skip verification:
```typescript
// WRONG — skips verification when header absent
if (headerSig && !(await verify(payload, headerSig))) return reject()
// CORRECT — rejects when header absent OR invalid
if (!headerSig || !(await verify(payload, headerSig))) return reject()
```

### 5. sbPersistAll — never include fields owned by edge functions
Fields that edge functions write (e.g. `signature_status`, `signature_request_id`) must **not** appear in `sbPersistAll`. If they do, the app's next sync will overwrite the webhook-updated value (e.g. resetting `'signed'` back to `'none'`). These fields are read into in-memory state on `sbLoadAll` but written only by the edge function.

### 6. Document/data scoping — always scope to the worker's actual set
When fetching document set items for a specific worker (reminders, portal, etc.), always filter by `document_set_id` from the worker row. Never fetch all items for all sets and let the worker see unrelated requirements.

### 7. Storage paths — always org-prefixed
Any file written by an edge function to `tmc-documents` must use `${org_id}/...` as the path prefix. Paths keyed only by worker-id or reference-id are NOT org-isolated (see multi-tenancy rules above).

### 8. New edge function checklist summary
- [ ] CORS headers on ALL responses (OPTIONS + every json() call)
- [ ] JWT verified; org derived from `profiles`, not caller params
- [ ] Every DB query filtered by `org_id`
- [ ] Webhook HMAC required (not optional)
- [ ] No sbPersistAll-owned fields written by the function appear in sbPersistAll
- [ ] Storage paths are `${org_id}/...` prefixed
- [ ] Migration added to `migrations/` if new columns introduced
- [ ] Migration table in CLAUDE.md updated

---

## PA Gantt — How It Works

- `_paFilteredAssignments()` — determines which workers get a **row** (must have assignment visible in current column range)
- `allFilteredPA` — all assignments for those workers (no date filter) — used for **bar rendering** so all assignments show even if outside the current view
- `packLanes(wA)` — assigns each bar to the minimum lane so non-overlapping bars sit at the top (row height only grows for genuine time overlaps)
- Reference week = centre column, highlighted purple with "REF" label
- Sort default: by project name, then worker name

---

## Billing Tracker

- Amber cells = uncharged weeks (past AND future) within an assignment period
- Green cells = charged
- `charge_to_operative` flag on accommodation/vehicle assignments controls whether the worker appears in billing
- `openBillingDetail(type, assignmentId, wid)` — detail panel with pending week list

---

## Worker Modal (rebuildModal)

- Uses `currentWeekMonday` (selected week in Workers tab) as `refDate` for all calculations
- GO/NO-GO, score, missing/expiring docs, current PA/accom/vehicle panels all reflect that week
- Non-current week shows `(Wxx)` note in the GO/NO-GO banner

---

## Scalability Notes

### Architecture model
The app uses a **"load everything on login"** model: `sbLoadAll()` fetches all rows from every table into memory on sign-in, and `sbPersistAll()` writes all state back on every sync. This is simple and fast at current scale.

### Scale ceiling
| Worker count | State |
|---|---|
| 0–500 | Comfortable — login and sync feel instant |
| 500–1,500 | Noticeably slower on login/sync; still functional |
| 1,500–2,000 | Sluggish; user experience degrades |
| 2,000+ | Needs architectural redesign |

### Hard limits already solved
- **Supabase/PostgREST 1,000-row cap**: All growth tables in `sbLoadAll` use `qPaged()` (paginated fetcher, 1,000 rows per request until exhausted). Never use the bare `q()` helper for tables that grow with workers or documents.
- **Upsert timeout on large batches**: `sbUpsertRows()` chunks writes at 500 rows. Safe for any realistic batch size.

### Warning signal
If login or saving ever starts feeling slow as you grow, that is the signal to revisit the architecture — not before. Do **not** redesign pre-emptively.

### Future redesign direction (if needed)
- Load only active workers + recent data on login; fetch individual worker detail on demand
- Delta sync: only upsert rows that actually changed since last write (track a `dirty` flag per entity)
- Background sync: move `sbPersistAll` off the main thread using a Web Worker
- Supabase Realtime: subscribe to row-level changes instead of polling

### Tables to watch
`worker_documents` and `worker_document_files` grow fastest (one doc + multiple files per worker per doc type). At 500 workers with 10 doc types each that is ~5,000 document rows and potentially 15,000+ file rows — all paginated safely by `qPaged`.

---

## Checkpoint — Production State as of 2026-06-01

**140 commits on main**. System fully live with:
- Worker compliance tracking (docs, expiry, GO/NO-GO scoring)
- Project assignment Gantt with multi-assignment support and lane packing
- Resource management (accommodation + vehicles) with billing tracker
- Property and vehicle event logging
- Daily email digest via Resend + Supabase Edge Functions
- Role-based access (admin/planner/compliance/viewer)
- Supabase Auth with MFA available
- Custom domain: work-force.nl (GitHub Pages + GoDaddy DNS)
- Approvals tab: pending doc submissions + return requests, approved/rejected history with pagination and search, auto-delete rejected, worker portal pending badge

---

## Mobile UI Standards — Apple HIG (vault.html + any future mobile-first UI)

These rules are hard constraints, not suggestions. Apply them automatically on every UI change without waiting to be asked. The reference is Apple's Human Interface Guidelines; the target aesthetic is Revolut / Stripe / Linear — premium, calm, typographically confident.

### Touch & Tap Targets
- **Minimum 44×44 px** for every interactive element: buttons, checkboxes, tappable rows, icon-only actions
- Use `min-height:44px` on all buttons and tappable list rows
- Tappable rows must span full width — never require tapping a small icon inside a row
- Fixed bottom elements must include `padding-bottom: env(safe-area-inset-bottom)` for iPhone home indicator

### Typography
- Minimum sizes: **11px** captions/labels · **13px** secondary text · **15–17px** primary content
- **Never below 16px on any `<input>` or `<textarea>`** — iOS auto-zooms on anything smaller (already enforced via media query)
- Font-weight hierarchy: **800** headings · **700** subheadings · **600** labels · **400–500** body
- Line-height: 1.4–1.6 body · 1.2–1.3 headings
- Tight letter-spacing (–0.02em) on large bold headings only

### Colour & Contrast
- **WCAG AA minimum**: 4.5:1 contrast for normal text, 3:1 for large text (18 px+ or 14 px bold)
- Colour reinforces meaning but is **never the only indicator** — always pair with a label or icon
- **Limit accent colour to 2–3 uses per screen** — when everything is purple, nothing is purple
- Semantic palette: green = valid/success · amber = warning/expiring · red = error/missing · grey = inactive/optional

### Layout & Spacing
- Minimum **16px horizontal padding** from screen edges
- Card border-radius: **12–16 px** (12 px feels premium; below 8 px feels dated on mobile)
- Consistent vertical rhythm based on an **8 px grid** (gap:8, margin:16, padding:24)
- Safe area: `padding-bottom: env(safe-area-inset-bottom)` on any fixed bottom bar

### Icons — MANDATORY
- **Never use emoji for functional UI chrome** (buttons, status, section headers, navigation, form actions)
- Use a **single icon library at a consistent stroke-weight** — project standard is **Lucide Icons (2 px stroke)**
- Icon sizes: 16 px inline with text · 18 px beside content · 20–22 px as primary card icon
- Icons **always inherit `currentColor`** — never hardcode a colour on an SVG icon
- **Always pair icons with a text label** unless the action is universally understood (✕ close is fine alone)
- Emoji acceptable only in: empty-state illustrations, marketing copy, brand logo placeholder

### Status Indicators
- Use a **6–8 px coloured dot** (`.v-sdot`) for inline status — pill/badge boxes are a dashboard pattern, not premium mobile
- Loading: spinner or skeleton — never leave a blank white screen
- Success: brief inline confirmation (checkmark + text), not a blocking `alert()`
- Errors: inline below the relevant field where possible, not blocking alerts

### Modals & Sheets
- **Bottom sheet** (slides up from bottom) for mobile — not centred dialogs ← vault already correct
- Sheet max-height **88vh** to keep visible backdrop for easy dismissal ← vault already correct
- Always provide an explicit close/cancel — never rely on backdrop-only dismissal
- Primary action belongs in the **sheet footer** (sticky if content scrolls)
- Scrollable content + sticky footer: wrap content in `overflow-y:auto` div; footer is `border-top` + `padding-top`

### Buttons
- **One primary (filled) button per screen/modal** — everything else is secondary (ghost) or tertiary (text only)
- Labels: **verb-noun format** ("Download document", "Send documents") — avoid "OK", "Submit", "Confirm"
- Disabled state: `opacity:0.45` + `cursor:not-allowed` — visually unambiguous
- Primary buttons: **full-width on mobile** (`width:100%`)
- Minimum height **44 px** on all buttons

### Lists & Rows
- Minimum **44 px row height** for any tappable row
- Standard row anatomy: **left avatar/icon → main content → right value/chevron**
- Use `border-bottom:1px solid #f1f5f9` or card grouping for separators — never heavy borders
- Disclosure chevron (›) on rows that navigate deeper

### Navigation
- Tab bar at bottom is the correct iOS primary navigation pattern ← vault already correct
- Maximum **5 tabs** — consolidate before adding more
- Tab labels: 1–2 words, paired with an icon in native; text-only tabs are acceptable in web apps
- Active tab: accent colour; inactive: `#64748b` ← vault already correct

### Org/Contact Avatars (replacing emoji)
- Use a **rounded square with 2-letter initials** instead of 🏢 for organisations
- Background: `var(--accent)` with white text, or a tinted version (`rgba(124,58,237,.12)` bg + `var(--accent)` text)
- Size: **36–40 px**, `border-radius:10px` for orgs/companies · `border-radius:50%` for people
- Derive initials from first letter of first two words in the name

---

## Lessons Learnt & Bug Fixes Log

### 1. Demo Mode — Filter Button UI Not Updating
**Symptom**: Workers tab appeared blank in demo mode until the user manually clicked "All".  
**Root cause**: `sbInitDemo()` set `fActive = 'all'` directly, which filtered the data correctly, but the `[data-fa]` button elements were not re-classed — the "Active" button still showed as selected in the UI.  
**Fix**: After setting `fActive`, always also update the button visual state:
```js
fActive = 'all';
document.querySelectorAll('[data-fa]').forEach(b => b.classList.toggle('active', b.dataset.fa === 'all'));
```
**Rule**: Never set `fActive` directly without also syncing the button UI. Use `setFA('all')` where possible, or pair with the `forEach` call above.

---

### 2. Demo Mode — Flash of "Sign In" / "Offline" / "Error" Before Banner Loads
**Symptom**: The header briefly showed the "Sign In" button and "Offline"/"Error" sync pill before the demo banner appeared.  
**Root cause**: `app.html` is ~400KB. The browser does incremental renders during HTML parsing. The `demo-mode` CSS class (which hides those elements) was only added inside `showDemoBanner()`, which runs at the bottom of the file — so the browser could render an intermediate state without the class.  
**Fix**: Add an inline `<script>` immediately after `<body>` opens:
```html
<script>if(new URLSearchParams(location.search).has('demo'))document.body.classList.add('demo-mode');</script>
```
This runs synchronously at parse time, before the browser renders any content.

---

### 3. Demo Mode — Sticky Chrome Layout Break After Early Class Injection
**Symptom**: After fix #2, the main content area slid behind the sticky header in demo mode.  
**Root cause**: `body.demo-mode .sticky-chrome{top:38px;}` applied immediately (because of the early class), but `#demoBanner` was still `display:none` at that point (zero height). The sticky chrome was offset 38px downward with no banner filling the gap — content bled through during incremental render.  
**Fix**: Add a CSS rule so the banner auto-shows whenever `demo-mode` is active:
```css
body.demo-mode #demoBanner { display: flex; }
```
The banner and the sticky-chrome offset are now always in sync from the very first paint. `showDemoBanner()` still sets `b.style.display='flex'` as a redundant no-op (harmless).  
**Rule**: When pairing a sticky element offset (`top:Npx`) with a sibling element that provides that `N`px of height, both must be guaranteed visible at the same time. Use CSS class coupling, not JS timing.

---

### 4. Demo Mode — Relative Dates for Fake Workers
**Symptom concern**: Hardcoded expiry dates on demo workers would become stale, breaking GO/WARNING/NO-GO status over time.  
**Fix**: Use `demoDate(offsetDays)` helper everywhere in `loadDemoDefaults()`:
```js
function demoDate(offsetDays){
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}
```
- `demoDate(730)` = valid for ~2 years from today
- `demoDate(14)` = expiring soon (WARNING)
- `demoDate(-30)` = already expired (NO-GO)
**Rule**: Never hardcode year-specific dates in demo data. Always use relative offsets from `new Date()`.

---

### 5. Demo Mode — Branding: TMC References Must Be Conditional
**Symptom**: Demo mode showed "TMC Compliance", TM Construction logo, and `compliance@tmconstruction.nl` in the compliance report.  
**Fixes applied**:
- `showDemoBanner()` swaps `#headerLogoImg` src to WF SVG and sets `#headerAppTitle` to `'Work Force Compliance'`
- `complianceReportText()` uses `${DEMO_MODE ? 'Work Force' : 'TMC'} Compliance Report`
- `complianceReportRecipient()` falls back to `'sales@work-force.nl'` in demo mode
- CSV download filename prefixed with `wf_` vs `tmc_` conditionally
- `loadDemoDefaults()` sets `settings.complianceReportEmail = 'sales@work-force.nl'`
- HTML input `value=""` cleared (was hardcoded `compliance@tmconstruction.nl`) — `renderComplianceReportSettings()` always populates it from `complianceReportRecipient()`

**Rule**: Search for `tmconstruction`, `TMC`, `TM Construction` whenever adding any new text string. Every user-visible string that names the company must be conditional on `DEMO_MODE`.

---

### 6. Supabase Profiles RLS — Circular Policy Dependency
**Symptom**: Admin could not approve/change roles for new users. Alert: "Role was not saved — Supabase RLS blocked the update."  
**Root cause**: The RLS policies on `profiles` checked "is current user admin?" by querying `profiles` — but querying `profiles` requires the SELECT policy to pass, which runs the same query → circular → Supabase resolves to NULL → update silently blocked.  
**Fix**: Run `migrations/fix_profiles_rls_circular.sql` in Supabase SQL Editor. It creates:
```sql
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER ...
```
A `SECURITY DEFINER` function bypasses RLS entirely when reading `profiles` to check admin status. All three policies (`profiles_select`, `profiles_insert`, `profiles_update`) are rebuilt to use `public.is_admin()` instead of the circular subquery.  
**Rule**: Never write RLS policies on `profiles` that reference `profiles` inline. Always use a `SECURITY DEFINER` helper function.

---

### 7. Profile Approval Silently Fails — `org_id = NULL` on New Signups
**Symptom**: Even after running `fix_profiles_rls_circular.sql`, the role approval still showed "Role was not saved." Zero rows returned by the update.  
**Root cause**: The `handle_new_user()` trigger that creates a profile on signup did not include `org_id`. So new pending profiles had `org_id = NULL`. The update query filtered `.eq('org_id', currentOrgId || SITE_ORG_ID)` — in SQL, `NULL = '...'` is always false — so 0 rows matched even though RLS was now fixed.  
**Fix**:
1. In `app.html`, removed `.eq('org_id', ...)` from all three profile update calls (`updateUserRole`, `updateUserActive`, `quickApproveUser`). The `id` column is the Supabase auth UUID — unique — filtering by it alone is sufficient.
2. Created `migrations/backfill_profiles_org_id.sql` to SET `org_id` on all existing NULL profiles and update the trigger to include `org_id` for future signups.

**Rule**: When filtering a `UPDATE ... WHERE id = X` query, **do not add secondary column filters** (like `org_id`) unless you have verified that every row being updated definitely has that column set. A filter that doesn't match silently returns 0 rows and is indistinguishable from an RLS block. Never conflate "0 rows returned" with "RLS blocked" — always diagnose the filter chain first.

---

### 8. index.html — Hero Section Real Worker Names Leak
**Symptom**: The hero mockup in the marketing page showed real production worker names (Adrian Mitrea, Alexandru Ciolos, Alexandru Leon, Gheorghe Pinau) and real project codes.  
**Fix**: Replace all demo data in the hero section with entirely fictional names: J. van den Berg, M. Schmidt, P. Kowalski, D. Ionescu. `workerData` JS object keys renamed from `mitrea/ciolos/leon/pinau` to `berg/schmidt/kowalski/ionescu`. All `<tr>` HTML elements updated to match.  
**Rule**: **Never copy real worker names, project names, or reference numbers into demo/marketing pages.** The `workerData` object in `index.html` is the single source of truth for hero panel data — always use the generic keys and fictional names defined there.

---

### 9. index.html — CSS Variable Scoping for Real App Classes in Marketing Page
**Symptom**: When embedding real app CSS class names (`status-badge`, `go-dot`, etc.) in the marketing hero mockup, colours were wrong because `index.html` uses different CSS variable values than `app.html`.  
**Root cause**: `index.html` defines `--navy: #1e3a5f`, `--red: #dc2626` etc., while `app.html` uses `--navy: #1a3082`, `--red: #c53030`.  
**Fix**: Wrap the real-app mockup HTML in a container with scoped variable overrides:
```css
.demo-dashboard { --navy: #1a3082; --red: #c53030; /* etc. */ }
```
All descendant elements then inherit the correct values.  
**Rule**: Never assume CSS variables have the same values across files. Always scope overrides to a wrapper class when mixing design systems.

---

### 10. Sticky Banner + Sticky Chrome — Two-Sticky Stack Requires Height Coupling
**Pattern** (for future reference): The demo banner and main nav are both `position:sticky`. They form a stacked pair:
```css
#demoBanner { position:sticky; top:0; min-height:38px; }
.sticky-chrome { position:sticky; top:0; }
body.demo-mode .sticky-chrome { top:38px; } /* offset = banner height */
body.demo-mode #demoBanner { display:flex; }  /* always visible when offset active */
```
The offset value (38px) must exactly match the banner's `min-height`. If the banner height changes, update both values together.  
**Rule**: Keep sticky stack offsets and their matching element heights in sync. Document the coupling explicitly in CSS comments when the values are co-dependent.

---

### 11. `handle_new_user()` Trigger — Always Include `org_id`
**Finding**: The Supabase `handle_new_user()` trigger that fires on every new auth signup creates a row in `profiles`. Any column that has a NOT NULL constraint or is used in app-layer filters **must** be set in this trigger — it cannot be left to the app to fill in afterwards (the user may never log in; the row already exists).  
**Current trigger sets**: `id, email, full_name, role='no_access', active=FALSE, org_id=SITE_ORG_ID`  
**Rule**: When adding new NOT NULL columns to `profiles`, also update `handle_new_user()` to include them and write a migration. Check `migrations/backfill_profiles_org_id.sql` as the template.

---

### 12. Demo Mode — Workers Never Auto-Rendered (`const fileStore` Reassignment Threw)
**Symptom**: On the live demo's first load, the workers table showed the empty state ("No workers added yet") even though demo workers were defined. They only appeared after manually toggling a filter button (All/Active). Multiple render-timing fixes (sync `setFA`, `setTimeout` safety nets, filter-button UI sync) did **not** help.  
**Root cause**: `fileStore` is declared `const fileStore={}`. But `loadDemoDefaults()` and `restoreDemoState()` both did `fileStore={};` (reassignment). **Assigning to a `const` throws `TypeError: Assignment to constant variable`.** That throw happened *after* `workers = [...]` was populated but *before* `sbInitDemo()` reached its `setFA('all')` render call — so `workers` existed in memory (hence a manual filter toggle would render them) but the table never auto-rendered on load. The throw silently aborted `sbInitDemo()` because the `loadDemoDefaults()` call wasn't wrapped in try/catch.  
**Why it was hard to spot**: The visible demo chrome (banner, WF logo, Request Trial button) is all CSS-driven via the early `body.demo-mode` class — it renders regardless of whether the demo JS throws. So "the demo looks like it loaded" proved nothing about whether `sbInitDemo()` completed.  
**Fix**:
```js
// WRONG — throws because fileStore is const
fileStore={};
// RIGHT — clear the const object in place
Object.keys(fileStore).forEach(k=>delete fileStore[k]);
```
Applied in both `loadDemoDefaults()` and `restoreDemoState()`. Also wrapped the demo data-load in `sbInitDemo()` in try/catch so any future throw can't prevent the render.  
**Diagnostic lesson**: When a table shows empty but the data "appears after a manual UI toggle", the data IS in memory — the bug is a render that never fired, almost always because an **uncaught throw aborted the init function before its render call**. Trace what runs *between* the data assignment and the render, and check every statement there — especially assignments to `const`-declared state objects (`fileStore`, and any other `const` global).  
**Rule**: Core mutable state objects that get "reset" (`fileStore`, etc.) must be declared `let`, OR every reset must clear-in-place (`Object.keys(x).forEach(k=>delete x[k])` / `arr.length=0`) — never `x={}`/`x=[]`. And **always wrap optional/demo data-load calls in try/catch** so a throw can't abort the surrounding init and skip the render.

---

### 13. Multi-Tenancy — Cross-Org Data Leak From Surviving Permissive RLS Policies
**Symptom**: A brand-new self-serve org (correct, separate `org_id`) logged in and saw **all of TMC's 63 real workers**. `is_tmc_org` on its profile was `false`, yet workers leaked.
**Root cause (two compounding bugs)**:
1. **Surviving legacy policy.** PostgreSQL RLS policies are **permissive and OR together**. The original single-tenant app had a policy `auth_only` on `workers` with `USING (true)` (plus `workers_own`, `workers_staff`). `add_multi_tenancy.sql` dropped old policies by a **hardcoded list of names** that did not include `auth_only`, so it survived. `true OR (org_id = current_org_id())` → every row visible to every authenticated user. The org-scoped policy was correct but irrelevant.
2. **`ENABLE ROW LEVEL SECURITY` was originally only run on `organisations`** — every other table had policies but RLS switched off, so policies were inert until that was fixed.
**Also found & fixed in the same incident (app.html, single-tenant bootstrap logic that is lethal in multi-tenant)**:
- `currentOrgId = sbProfile?.org_id || SITE_ORG_ID` dropped every org-less user (all new signups) into TMC. → resolve to `null`, never `SITE_ORG_ID`, except the owner email.
- "First admin" auto-promote: RLS hides other orgs' admins from an unassigned user, so the global admin check returned empty, the code thought they were the first admin, and self-created their profile as `admin/active/org_id=TMC`. → removed entirely.
- `sbPersistAll`/`sbLoadAll` `oid = currentOrgId || SITE_ORG_ID` would read/write TMC for a null-org user. → hard-gate both: abort when `currentOrgId` is null.
- localStorage caches (`tmc_*`/`btm_*`) are **global to the browser, not per-org** — one org's cached projects/resources rendered under another account. → `sbClearLocalCache()` on logout, on the no-workspace gate, and when `wf_cache_org` marker differs from the resolved org.
**Fix migration**: `fix_rls_rebuild_all_policies.sql` — enumerates `pg_policies` and **drops every policy** on each app table, then recreates exactly one org-scoped SELECT + one org-scoped ALL policy. Ends with a verification SELECT.
**Diagnostic that nailed it**: `SELECT tablename, policyname, cmd, roles, qual FROM pg_policies WHERE schemaname='public'` — any `qual = 'true'` (or a qual lacking `org_id = current_org_id()`) on a data table is a leak. Also check for org_id tables with RLS off: `pg_class.relrowsecurity = false`.
**Rules**:
- **Never drop RLS policies by a guessed name list.** Enumerate `pg_policies` and drop them all, then recreate. Legacy/Supabase-template policy names are unpredictable.
- **RLS has two switches**: the policy AND `ENABLE ROW LEVEL SECURITY`. Both are required; verify `relrowsecurity = true`.
- **Policies are OR-combined** — one `USING(true)` defeats every other policy on the table. There must be exactly the intended policies and nothing else.
- **Never fall back to `SITE_ORG_ID`** for a logged-in user whose profile has no `org_id`. Resolve to null and gate off all reads/writes. `SITE_ORG_ID` is only valid for the explicit owner-email override.
- **After any tenancy change, re-run the `pg_policies` audit and the RLS-off audit**, and smoke-test a fresh org sees zero rows.

---

### 14. Edge Functions — CORS Missing on Non-OPTIONS Responses
**Symptom**: User saw "Failed to send reminder: Failed to fetch" in the browser. The email was actually sent successfully — the function ran to completion — but the browser rejected the response because it lacked CORS headers.  
**Root cause**: The `send-worker-reminder` edge function returned CORS headers on the OPTIONS preflight but not on the actual POST response. The browser enforced the same-origin policy and threw a network error, making it look like the function failed even though it succeeded.  
**Fix**: Every `Response` or `json()` call in a browser-callable edge function must include the CORS headers — not just the OPTIONS handler. Use a shared `json()` helper that always injects `CORS` headers (see Edge Function Development Checklist above).  
**Rule**: Browser-callable edge functions must return CORS headers on **every** response, including errors, timeouts, and early-return paths. A missing CORS header on an error path means the caller sees "Failed to fetch" instead of the real error message, making debugging harder.

---

### 15. Edge Functions — Document Set Items Not Scoped to Worker's Set
**Symptom**: A worker on the Blue Card (NL – Blue Card) document set received a reminder email listing ZZP (NL – ZZP) documents as missing.  
**Root cause**: The `send-worker-reminder` function fetched all document set items without filtering by the worker's `document_set_id`. Because the built-in sets have overlapping doc keys, the wrong set's items were returned.  
**Fix**: Always scope the document set items query to `document_set_id = worker.document_set_id`. Never fetch all items and rely on client-side filtering when the worker's set is known at query time.  
**Rule**: Any function that fetches document requirements for a specific worker must filter `document_set_items` by the worker's `document_set_id`. Unscoped fetches silently return the wrong documents for workers on non-default sets.

---

### 16. Webhook Verification — Optional HMAC Check Is a Security Hole
**Symptom**: The Dropbox Sign webhook handler used `if (headerSig && !(await verify(...)))` — meaning requests with no `X-HelloSign-Signature` header would skip verification entirely and be processed as valid.  
**Root cause**: The condition was written as "if a header is present, check it" instead of "the header must be present and valid." An attacker posting directly to the webhook URL (with no API key and therefore no valid signature) would have no signature header, so the `&&` short-circuit would let them through.  
**Fix**: Change to `if (!headerSig || !(await verify(...)))` — missing header is treated the same as an invalid signature: rejected.  
**Rule**: Webhook signature checks must be `required`. The pattern is always `if (!sig || !valid) reject` — never `if (sig && !valid) reject`. Absence of the signature header is not a pass condition.

---

### 17. sbPersistAll Race Condition — Fields Owned by Edge Functions
**Symptom**: After a contract was signed (Dropbox Sign webhook set `signature_status = 'signed'`), the next app save would reset it back to `'none'` or `'pending'`, losing the signed status.  
**Root cause**: `signature_status` and `signature_request_id` were included in the `sbPersistAll` upsert for `project_assignments`. On every sync, the in-memory value (which the app set when sending, and never updated after the webhook fired) would overwrite the webhook's update.  
**Fix**: Remove `signature_status` and `signature_request_id` from the `sbPersistAll` upsert. These fields are loaded into memory in `sbLoadAll` (so the UI can display them) but are **written only by edge functions**. The app never writes them back.  
**Rule**: Any column that an edge function owns (writes to) must not appear in `sbPersistAll`. Load it read-only in `sbLoadAll`, display it in the UI, but treat it as immutable from the app's perspective. Document these columns in the Edge Function checklist above.

---

### 18. Database CHECK Constraints — Must Be Audited When Extending a Column's Domain
**Symptom**: Saving a worker with a custom worker type (created in Settings → Worker Types) failed with: "new row for relation 'workers' violates check constraint 'workers_worker_type_check'".  
**Root cause**: The `workers.worker_type` column had a `CHECK` constraint that only allowed the original hardcoded values (e.g. `'zzp'`, `'blue'`). When custom types were implemented in the Settings UI, no one checked whether an existing DB constraint would block them.  
**Fix**: `migrations/drop_worker_type_check_constraint.sql` — `ALTER TABLE workers DROP CONSTRAINT IF EXISTS workers_worker_type_check`.  
**Rule**: **Before implementing any feature that writes a new value to an existing column, check `pg_constraint` for CHECK constraints on that column.** If the constraint would block valid new values, add a migration to drop or widen it as part of the feature, not as a follow-up fix. The pattern to check: `SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'workers'::regclass AND contype = 'c';`

---

### 19. Dropbox Sign Webhook — Form Field Name Is `json` Not `payload`, Sent as `multipart/form-data`
**Symptom**: Signed documents were never stored. The webhook test passed, but real `signature_request_signed` events were silently ACK'd without doing anything.  
**Root cause (two compounding issues)**:
1. Dropbox Sign sends real events as `multipart/form-data` POST — not `application/x-www-form-urlencoded`. `URLSearchParams` cannot parse multipart, so `params.get('json')` always returned null, hitting the early `if (!payloadStr) return ACK` guard with no log output.
2. The field name is `json`, not `payload`. The test ping uses a different format and passes regardless, masking the bug.  
**Fix**: Use `req.formData()` for multipart requests (detected via `content-type` header), with `URLSearchParams` fallback for url-encoded test pings. Extract `formData.get('json')` as the payload string.  
**Rule**: Always verify third-party webhook content-type AND field names against actual API docs. Test ping format ≠ real event format — a passing test does not confirm the real event path works. Add debug logging of `content-type` and body preview to diagnose silently-skipped webhooks.

---

### 20. Dropbox Sign Webhook — event_hash Uses HMAC-SHA256, Not Plain SHA256
**Symptom**: `event_hash verified: false` on every request even after switching away from the header-based approach. Computed and expected hashes were completely different despite the correct API key being loaded (correct `key_len` and `key_first4/key_last4` confirmed via logging).  
**Root cause**: The formula was implemented as `SHA256(event_time + event_type + api_key)` — a plain SHA-256 digest with the key appended to the message. The Dropbox Sign specification requires `HMAC-SHA256(key=api_key, message=event_time+event_type)` — a proper HMAC where the API key is the cryptographic signing key, not part of the message.  
**Fix**:
```typescript
// WRONG — plain SHA256 with key appended to message
const hashBuf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(eventTime + eventType + apiKey))

// CORRECT — HMAC-SHA256, API key is the HMAC key
const cryptoKey = await crypto.subtle.importKey(
  'raw', new TextEncoder().encode(apiKey), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
)
const sigBuf = await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(eventTime + eventType))
```
**Rule**: When a third-party API says "HMAC-SHA256 of X using Y as the key", that means `HMAC(key=Y, msg=X)` — NOT `SHA256(X + Y)`. These produce completely different outputs. Use `crypto.subtle.importKey` + `crypto.subtle.sign('HMAC', ...)`. Add hash-prefix logging before deploying any new webhook verification so mismatches can be diagnosed without access to the full secret.

---

### 21. Modal State Capture — Use Open-Time Snapshot for Flags That Mutations Would Invalidate
**Symptom**: After removing a contract file from an assignment modal, clicking Save did nothing — the form appeared to submit but no changes were applied.  
**Root cause**: `saveProjectAssignment` computed `isProtected = hasContractFile(a)` at save time. But `paRemoveExistingFile` mutated `a.contractFiles` to remove the file (necessary so `sbPersistAll` wouldn't revive it). With all files removed, `hasContractFile(a)` returned `false`, so save took the non-protected path and read rate/notes/worker from disabled form fields — which had no values.  
**Fix**: Capture `paWasProtected = hasContractFile(a)` at modal-open time in `openEditPA` (before any mutations). `saveProjectAssignment` uses `paWasProtected` instead of recalculating from the possibly-mutated state.  
**Rule**: Any flag derived from in-memory state that controls a code path in a save function should be captured as a snapshot when the modal opens (`let paWasProtected = false`, set in `openEditPA`/`openAddProjectAssignment`). Never recalculate it from state that the modal itself mutates — you'll get the post-mutation value, not the original intent.

---

### 22. Supabase Realtime Subscription Overwrites In-Memory Resets
**Symptom**: After removing a signed contract file, the "Signed" banner disappeared immediately but reappeared after a few seconds, and always after a page refresh.  
**Root cause**: The Realtime subscription (`sbRealtimeChannel`) listens to ALL `postgres_changes` on the `public` schema. Any DB write — including the fire-and-forget `project_assignment_files.active=false` — triggers `sbQueueRemoteReload` → `sbLoadAll` 650ms later. `sbLoadAll` re-reads `project_assignments.signature_status` from the DB, which was still `'signed'` (only the in-memory value had been reset). This silently overwrites the in-memory reset.  
**Fix**: When resetting a field in memory, also immediately fire-and-forget the same reset to the DB. For critical resets (like signature_status on Save), use `await` so the DB is updated before the modal closes and before any Realtime-triggered reload can re-read the stale value.  
**Rule**: Any time you reset an in-memory field that is NOT written by `sbPersistAll` (e.g. `signature_status`, `signature_request_id`), you must also write the reset to the DB immediately. The Realtime subscription will fire within ~1 second of any DB write and call `sbLoadAll`, which will overwrite in-memory values from DB. In-memory-only resets do not survive this cycle.  
**Checklist before any in-memory reset of an excluded field**:
1. Is this field excluded from `sbPersistAll`? (check the NOTE near line 10876)
2. Does the Realtime subscription touch this table? (yes — it covers all of `public`)
3. If yes to both: fire-and-forget the DB reset immediately; also `await` it in any save path.

---

### 23. sbPersistAll Reviving Fire-and-Forget Deactivations
**Symptom**: A file deactivated via fire-and-forget (`update({active:false})`) kept reappearing — it was gone from the UI for a moment but came back after a sync.  
**Root cause**: `sbPersistAll` iterates `a.contractFiles` and upserts every entry with `active:true`. The fire-and-forget set the DB row to `active:false`, but `sbPersistAll` (running 650ms later from the debounced sync) re-upserted it as `active:true` because `a.contractFiles` still contained the file.  
**Fix**: Mutate `a.contractFiles` to remove the file at the time of removal, so `sbPersistAll` never sees it. Pair with `paWasProtected` (lesson 21) to preserve modal protected-mode state.  
**Rule**: Fire-and-forget `active:false` is only permanent if the in-memory array that `sbPersistAll` iterates is also mutated to remove the item. Otherwise the next sync revives it. The two operations must happen together: (1) mutate in-memory array, (2) fire-and-forget DB deactivation.

---

### 25. Signature Reset Must Be Awaited BEFORE File-Deactivation Writes

**Symptom**: `signature_status` reverted to `'signed'` on every page refresh and every 5-minute poll, even though the app code appeared to reset it.
**Root cause**: Three cascading failures made the fire-and-forget approach unworkable:
1. The file-deactivation write triggered Supabase Realtime → `sbQueueRemoteReload` → `sbLoadAll` 650ms later, which re-read `signature_status:'signed'` from DB (the sig reset hadn't landed yet)
2. `archiveDeletedItem` set `sbSuppressRealtimeUntil = Date.now() + 2500`, but was called AFTER the writes — and its 2.5s window could expire before subsequent writes completed
3. Even the `paResetSignature` flag approach in `saveProjectAssignment` could fail if Realtime reloaded `signatureStatus:'signed'` into memory between Remove and Save
**Fix**: Make `paRemoveExistingFile` async. **Await the signature DB reset first**, before any write that triggers Realtime. Then extend `sbSuppressRealtimeUntil` to 8 s (overriding `archiveDeletedItem`'s 2.5 s) so the file-deactivation writes don't fire sbLoadAll before the DB is consistent.
**Rule for any DB field excluded from sbPersistAll that must be reset on removal**:
1. Make the removal function `async`
2. `await` the DB reset **first** — before any other write that triggers Realtime
3. After all writes, set `sbSuppressRealtimeUntil = Math.max(sbSuppressRealtimeUntil, Date.now() + 8000)` to prevent sbLoadAll from firing during the window
4. Keep the `paResetSignature`-style flag in Save as a safety net

### 24. Audit Scope — Read sbPersistAll + sbLoadAll + sbQueueRemoteReload Before Touching Modal State
**Pattern for future sessions**: Before modifying any code that touches in-memory state in a modal (especially remove/archive flows), read these three functions in full:
- `sbPersistAll` (~line 10750) — what it writes and what it intentionally excludes
- `sbLoadAll` (~line 11100) — what it re-reads and overwrites on every reload  
- `sbQueueRemoteReload` (~line 10563) — what triggers a reload and the 650ms debounce
Without this context, local fixes introduce side effects that only manifest seconds later via the Realtime loop or the next sync. This is the primary reason incremental fixes in this codebase require more iterations than expected.

### 26. `sbWrap` + `async` Functions = Silent Unhandled Rejections (Modal Stuck Open)
**Symptom**: After removing a file, clicking Save "activated a sync but the modal didn't close." After a hard refresh (which clears `paRemovedFileIds`/`paResetSignature`), Save worked again.
**Root cause**: `sbWrap(name)` wraps every action function like this: `const out=old.apply(this,args); sbScheduleSync(); applyRoleUI(); return out;`. It **calls `sbScheduleSync()` immediately and never `await`s `out`**. When the wrapped function is `async` (e.g. `saveProjectAssignment`) and it **throws before reaching `closeM()`**, the throw becomes a rejected promise that `sbWrap` ignores — a **silent unhandled rejection**. The sync fires (visible) but the modal never closes and there is zero error feedback. The throw only happened when `paRemovedFileIds` was non-empty (an awaited `project_assignment_files`/`project_assignments` write in the removed-files path rejected), which is why a refresh "fixed" it — the removed-files path was skipped entirely.
**Fix** (three parts):
1. Wrap the **entire body** of any async action function that ends in `closeM()` in `try/catch`; on error, surface it (`showDiagError` + `alert`) instead of letting it become an unhandled rejection. The modal then closes only on success (desired) and shows a clear error on failure.
2. Make every **auxiliary** DB write in a save (archiving removed files, signature resets) **best-effort** with its own `try/catch`, so a failure there can never abort the core save + modal close. Removal already persisted those at remove-time via `paPersistFileRemoval`; the save-time writes are just a backstop.
3. Never rely on `.catch(()=>{})` chained on a Supabase builder inside an `await` for control flow — use `try/catch` around the `await` instead.
**Rule**: Any `async` function registered in the `sbWrap` list (see `planningFns`/the `forEach(sbWrap)` array) MUST wrap its body in `try/catch`. `sbWrap` cannot catch async throws for you — it fires the sync and discards the promise. An uncaught throw = silent failure + stuck modal.

### 27. Diagnostic Error Surface — `showDiagError(context, err)` (gated to `DIAG_EMAIL`)
**Added**: A global error surface so production issues can be diagnosed without devtools. `window` `error` + `unhandledrejection` listeners and any `catch` block call `showDiagError(context, err)`, which logs to console for everyone and, **only for `dylan@tmconstruction.nl`** (`DIAG_EMAIL` / `isDiagUser()`), renders a dismissable red banner (bottom of screen) with the message/stack and a Copy button.
**Rule**: When adding a new `catch` in a critical write path, also call `showDiagError('<context>', e)` so the diagnostic account sees it. Keep it gated to `DIAG_EMAIL` — never show raw stacks to all users. To diagnose a new class of bug, ask the user to reproduce on that account and send the banner text.

---

### 28. sbPersistAll Resurrected Superseded Signed Contract Files (Webhook as External Writer)
**Symptom**: After multiple e-sign rounds on the same assignment, a freshly returned signed PDF was replaced by an **older** signed/original file.
**Root cause**: The dropbox-sign-webhook (an external writer) deactivates the original `project_assignment_files` and inserts the new signed PDF. But the app's in-memory `a.contractFiles` still held the **stale** older file. `sbPersistAll` re-upserts every in-memory contract file with `active:true` — resurrecting the superseded row (same class as Lesson 23, but the external writer is the webhook, not a fire-and-forget in the app).
**Fix**: `sbPersistAll` skips writing `project_assignment_files` for assignments whose `signatureStatus` is `'pending'`, `'pending_review'`, or `'signed'`. Those files are owned solely by the webhook + immediate-upload/`_persistPAImmediate` (which persist at upload time). Mirrors Rule 7 (edge-function-owned fields excluded from sbPersistAll), extended to **file rows**, not just columns.
**Rule**: When an edge function owns the lifecycle of rows in a table that `sbPersistAll` also writes (active/inactive toggling), `sbPersistAll` must **exclude those rows by a status guard** — otherwise the "write everything back as active:true" model resurrects whatever the webhook deactivated. Guard on the owning status field (`signatureStatus` here).

### 30. Document Set Copy — Templates and allowIssue Vanish After Hard Refresh
**Symptom**: When creating a new document set by copying an existing one, all tiles appeared correctly (including templates and "issuable" badges) immediately after creation. After a hard refresh or a few seconds, the template attachments and allow_issue flags were gone from every copied tile.
**Root cause (two compounding bugs)**:
1. `sbPersistAll` intentionally excludes `template_file_name`, `template_file_path`, and `allow_issue` from its `document_set_items` upsert (these are meant to be written only by `sbRemoteUpsertDocSetItem`). After `saveDocSet()` returned, `sbWrap` queued `sbPersistAll`, which upserted all the newly copied rows **without those three fields** — writing NULLs to the DB. The next `sbLoadAll` (on refresh or Realtime event) read those NULLs back, wiping what the user saw.
2. Copied items were given `id: 'c'+d.id` (e.g. `cbsn`, `cvca`) to "avoid collisions", but the DB row PK is `${setId}__${docKey}` — since the set UUID differs there is never a collision. The `'c'` prefix was pointless and produced ugly doc-keys that also surfaced as broken export folder names.
**Fix**: `saveDocSet` made `async`. After building the in-memory copy, it calls `sbRemoteUpsertDocSetItem` for every copied item — this is the only function that writes all three excluded fields — using `Promise.all` with per-item `.catch` so one failure can't abort the rest. The `'c'` prefix is dropped; doc-keys are now identical to the source set.
**Rule**: Any create/copy flow that produces new `document_set_items` rows must call `sbRemoteUpsertDocSetItem` for each row immediately — `sbPersistAll` alone will silently NULL out `template_file_name`, `template_file_path`, and `allow_issue`. These fields are excluded from `sbPersistAll` by design (see line ~11144) and must be written via the dedicated function.

### 29. E-Sign Has Two Flows — Only Issued Docs Auto-Route to Approvals
**Finding**: `sendForSignature(type, …)` sends two types. `type='issued_doc'` → webhook sets `issued_documents.status='pending_review'` → Approvals "E-Signed Documents" card → approve files into `worker_documents`. `type='assignment'` previously **auto-applied** the signed PDF onto the assignment, bypassing Approvals.
**Change (2026-06)**: Assignment contracts now also route through Approvals. Webhook parks the signed PDF as `project_assignments.signature_status='pending_review'` + `signed_file_path`/`signed_at` (migration `add_assignment_signed_review.sql`). New Approvals "E-Signed Contracts" card (`renderESignContracts`/`approveESignedContract`/`rejectESignedContract`) — approve inserts the signed PDF as an **additional** active file (the original unsigned contract is kept alongside it, not overwritten), sets status `'signed'`; reject deletes the signed PDF and resets to `'none'`. The two flows stay separate because approval targets differ: issued docs file into a worker's doc set (`worker_documents`); assignment contracts attach to `project_assignments`.
**Rule**: `signature_status` valid values are now `'none'|'pending'|'pending_review'|'signed'|'declined'` (no DB CHECK constraint, so all are accepted). `signed_file_path`/`signed_at` on `project_assignments` are **edge-function/approval-owned** — excluded from `sbPersistAll` (only in `paRows`? no — they must NOT be in paRows). Loaded read-only in `sbLoadAll`.

### 31. CREATE OR REPLACE of an RPC Must Start From the LIVE Definition, Not a Remembered/Hand-Written One
**Symptom (caught before deploy, not after)**: The two competency migration files (`add_vault_portal_competencies.sql`, `extend_worker_portal_competencies.sql`) each did `CREATE OR REPLACE FUNCTION get_vault_portal()` / `get_worker_portal()` from a **simplified, hand-authored body** that only contained the fields the author was thinking about plus the new competency fields. But production's live `get_vault_portal()` had grown far richer over time (`worker_doc_files`, `submissions`, `issued_docs`, full project/accom/vehicle/tool detail, `return_requests`, `phone`/`notes`). `get_worker_portal()` had a `pending OR (rejected AND review_notes IS NOT NULL)` submissions branch the migration draft had flattened to just `pending`.
**Why it's dangerous**: `CREATE OR REPLACE FUNCTION` **wholesale replaces the body** — there is no merge. Running the simplified file would have silently dropped every field not re-listed, breaking vault.html (downloads, submissions, assignments) and hiding rejected submissions in the worker portal. The signature matched, so there was no error to warn you — just a quiet, total regression.
**Fix / process that caught it**: Before applying any `CREATE OR REPLACE` of an existing function, **dump the live definition first** (`SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='…'`), then surgically add only the new fields to that exact body. Applied the corrected full-definition-plus-competency versions, then verified with a `pg_get_functiondef … LIKE '%field%'` check that every pre-existing key (`worker_doc_files`, `tool_assignments`, `issued_docs`) still survived alongside the new `competencies`/`comp_records`. Repo migration files were rewritten to the full live versions so a future re-run is safe.
**Rule**: Never `CREATE OR REPLACE` a function (or view) from memory or from a plan-time draft. Always fetch the current production body with `pg_get_functiondef` first and edit *that*. After applying, assert the old keys are still present — a passing signature check proves nothing about the body. This is the function-body analogue of Lesson 13's "never drop RLS policies by a guessed name list."

---

### 32. Org-Isolating the Storage Bucket Silently Broke Non-Org-Prefixed Upload Paths (doc-templates)
**Symptom**: Uploading a template to a document set (Settings → Document Sets) failed with an RLS error ("Template upload failed: new row violates row-level security policy"). Competency template uploads had the same latent bug.
**Root cause**: `fix_storage_org_isolation.sql` dropped the bucket-wide `authenticated_upload` policy and replaced it with `org insert documents`, which only permits objects whose **first** path segment equals `current_org_id()` (plus a short TMC-grandfathered legacy-folder list). But templates are written under `doc-templates/…`, which was deliberately kept **public-READ** (anon worker portal downloads blank forms via signed URL). No INSERT policy matched `doc-templates/…`, so every authenticated template upload was blocked — for **all** orgs, including TMC (`doc-templates` was not in the grandfather list).
**Fix**: (a) New storage policies (`fix_doc_template_storage_write.sql`) allow authenticated INSERT/UPDATE/DELETE under `doc-templates/{org_id}/…` keyed on `foldername[2]=current_org_id()` — mirroring the org-logos pattern. (b) app.html upload paths changed to put `org_id` as the **2nd** segment: `doc-templates/{org_id}/{set_id}/{doc_id}/…` and `doc-templates/{org_id}/competencies/{key}/…` (the competency path previously had org_id as the 3rd segment — also wrong). The public read policy (`foldername[1]='doc-templates'`) is unchanged, so anon downloads keep working. Existing pre-fix template files at `doc-templates/{set_id}/…` remain readable (public read still matches); only new uploads use the org-prefixed path.
**Rule**: When org-isolating a shared Storage bucket, **every** write path must begin with `{org_id}/…` OR be matched by a dedicated org-scoped policy on its own prefix. A folder kept public-read (templates, issued-docs) still needs its **own** authenticated INSERT/UPDATE/DELETE policy after the bucket-wide write policy is dropped — dropping the wide policy silently removes write access to every prefix that isn't org-id-first. After any storage-isolation change, smoke-test an actual upload to **each** distinct path prefix the app writes to (`workers/`, `doc-templates/`, `project-files/`, `org-logos/`, `vault/`, `worker-submissions/`), not just the worker-PII ones.

---

### 34. CREATE OR REPLACE Cannot Change a Function's Signature — Must DROP First
**Symptom**: `apply_migration` (or SQL Editor) returned `ERROR: 42725: function name "public.get_worker_portal" is not unique` when trying to add a new optional parameter (`p_worker_id uuid DEFAULT NULL`) to `get_worker_portal`.
**Root cause**: PostgreSQL's `CREATE OR REPLACE FUNCTION` can only replace a function if the new signature is identical to the existing one. Adding a new parameter (even with a DEFAULT) creates a different overload — PostgreSQL then sees two candidates for `get_worker_portal` and refuses the ambiguous `REPLACE` with `42725 not unique`. The error looks like a duplicate-function error but is actually a signature-change error.
**Fix**: `DROP FUNCTION IF EXISTS public.get_worker_portal(text, uuid)` first (specifying the exact old arg types), then `CREATE OR REPLACE` the new 3-parameter version. The `DROP` removes the old overload; `CREATE OR REPLACE` then has nothing to conflict with.
**Rule**: When adding or removing parameters from an existing PostgreSQL function, always `DROP FUNCTION IF EXISTS fn_name(old, arg, types)` before `CREATE OR REPLACE`. Specify the exact old argument types in the DROP — without them PostgreSQL may refuse (42725) if there's any ambiguity. Never rely on `CREATE OR REPLACE` alone to handle signature changes.

---

### 33. worker.html and vault.html Drifted — Same Bugs Existed in Both, Only One Was Fixed
**Symptom**: Multiple improvements were made to `worker.html` (iOS download fix, mobile overflow, profile tab → avatar button, sign-out relocation) over several sessions. When audited, `vault.html` had the same issues independently — `downloadTemplate()` still called `window.open` after `await` (popup-blocked on iOS), the header "Sign out" button caused width pressure on narrow screens, and the Account tab consumed a tab-bar slot instead of using an avatar button.
**Root cause**: `worker.html` and `vault.html` are developed as separate files with no shared code. Fixes applied to one were never cross-checked against the other. The two files serve the same user population (workers) on different entry points and must be treated as a single product.
**Fix**: Audited `vault.html` against all recent `worker.html` changes and applied the same fixes: `overflow-x:hidden`, `vUpdateAvatar()`/`vSwitchTab()`/`vSignOut()` pattern, Account tab moved to avatar button, sign-out into Account view, `downloadTemplate()` fixed with pre-`await` `window.open`.
**Rule**: Promoted to Critical Rule 8 — see above. Every worker-portal task must end with an explicit audit of `vault.html` for the same issue, and vice versa. Do not close a task until both files are checked.

---

## Demo Mode — Full Architecture Reference

| Constant / Key | Value | Purpose |
|---|---|---|
| `DEMO_MODE` | `new URLSearchParams(location.search).has('demo')` | True when `?demo=1` in URL |
| `DEMO_SS_KEY` | `'wf_demo_v1'` | sessionStorage key for persisting demo state |
| `SETTINGS_KEY` | `'tmc_settings_v1'` | localStorage key for settings |

**Boot path** (demo): `sbBoot()` → `sbInitDemo()` → `loadDemoDefaults()` or `restoreDemoState()` → `showDemoBanner()` → renders  
**Save path** (demo): `sbPersistAll()` → `saveDemoState()` → sessionStorage (no Supabase calls)  
**Load path** (demo): All Supabase calls are guarded by `if(DEMO_MODE) return;`

**`loadDemoDefaults()` sets up**:
- 4 workers (NL-041, DE-027, BE-089, NL-055) with relative-date docs via `demoDate()`
- 3 projects, 2 properties, 2 vehicles
- `settings.complianceReportEmail = 'sales@work-force.nl'`
- `fActive = 'all'` + button UI sync

**`showDemoBanner()` does**:
- `document.body.classList.add('demo-mode')` (also done early via inline script)
- Makes `#demoBanner` visible (CSS now handles this, JS call is redundant but harmless)
- Injects `🎭 Demo` pill + `Contact us` link into `#headerSyncWrap`
- Swaps `#headerLogoImg` src to WF SVG
- Sets `#headerAppTitle` text to `'Work Force Compliance'`
