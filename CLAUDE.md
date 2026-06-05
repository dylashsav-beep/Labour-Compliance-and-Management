# TMC Labour Compliance & Management — Claude Code Reference

> **⚠️ SYSTEM IS LIVE IN PRODUCTION**
> Real users and real data. Every change must be tested mentally before committing.
> Never break existing functionality. When in doubt, ask before implementing.

---

## Site Structure — Four HTML Files

| File | Purpose | Notes |
|---|---|---|
| `index.html` | **Marketing landing page** — work-force.nl root URL | Links to `login.html` and `worker.html`; no auth |
| `login.html` | **Management sign-in page** | Email/password + magic link; redirects to `app.html` on success |
| `worker.html` | **Worker portal** — standalone, email-entry login | Calls `get_worker_portal` RPC (anon); no Supabase Auth session |
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
| `profiles` | `id (= auth.uid()), role, active` |
| `settings` | App-wide settings (warning days etc) |

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
| `reactivate_orphaned_doc_parents.sql` | ⏳ Pending | One-time recovery: reactivates worker_documents wrongly deactivated by the group-delete bug (BSN files vanishing). Run after the code fix is deployed. |

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
