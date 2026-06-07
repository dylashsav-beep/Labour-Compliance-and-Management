# TMC Labour Compliance & Management — Claude Code Reference

> **⚠️ SYSTEM IS LIVE IN PRODUCTION**
> Real users and real data. Every change must be tested mentally before committing.
> Never break existing functionality. When in doubt, ask before implementing.

---

## Site Structure — Four HTML Files

| File | Purpose | Notes |
|---|---|---|
| `index.html` | **Marketing landing page** — work-force.nl root URL | Links to `login.html` and `worker.html`; no auth |
| `login.html` | **Management sign-in page** | Email/password + magic link; "Create workspace →" link to signup.html; redirects to `app.html` on success |
| `signup.html` | **Self-serve workspace creation** | 3-step flow: account → workspace slug → done; calls `create_workspace()` RPC; 30-day trial auto-starts |
| `worker.html` | **Worker portal** — standalone, email-entry login | Calls `get_worker_portal` RPC (anon); org resolved from `?org=<slug>` param; falls back to TMC SITE_ORG_ID |
| `app.html` | **Management app** — compliance dashboard | All HTML/CSS/JS (~400KB); requires auth; formerly `index.html` |

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
| `rename_aansp_insurance.sql` | ✅ Run | Renamed insurance doc in document_set_items |
| `schedule_daily_digest.sql` | ⏳ Pending | pg_cron schedule for daily email digest (replace placeholders first) |
| `worker_portal_anon_rpc.sql` | ⏳ Pending | SECURITY DEFINER RPC functions for worker direct-login portal |
| `worker_storage_policy.sql` | ⏳ Pending | Storage RLS policy allowing anon workers to upload to worker-submissions/ |
| `add_doc_set_item_info_fields.sql` | ⏳ Pending | Adds info_text and info_url columns to document_set_items |
| `add_reject_delete_days_to_settings.sql` | ⏳ Pending | reject_delete_days column on settings table (Approvals auto-delete) |
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
| `add_multi_tenancy.sql` | ⏳ Pending — **Run this in prod before any new orgs join** | Phase 0: organisations table, org_id on all tables, org-scoped RLS, `current_org_id()` helper, TMC backfilled |
| `add_org_id_indexes.sql` | ⏳ Pending — **Run immediately after add_multi_tenancy.sql** | Phase 0: CONCURRENTLY-safe org_id indexes on all hot tables. Without these, RLS does full table scans as orgs grow. |
| `create_workspace_signup.sql` | ⏳ Pending | Phase 1: `create_workspace()`, `join_workspace()`, `check_slug_available()` RPCs; plan/billing columns on organisations; updated `handle_new_user()` trigger |

---

## Email / Edge Function

- **Function**: `supabase/functions/daily-digest/index.ts`
- **Schedule**: Daily 07:00 UTC via pg_cron (after running `schedule_daily_digest.sql`)
- **Recipients**: `dylan@tmconstruction.nl`, `compliance@tmconstruction.nl`
- **From**: `onboarding@resend.dev` (sandbox) — change `FROM` constant when own domain verified
- **Covers**: Expired/missing docs, expiring docs (60d window), assignments ending (14d), uncharged billing weeks
- **No email sent** if nothing to report

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
