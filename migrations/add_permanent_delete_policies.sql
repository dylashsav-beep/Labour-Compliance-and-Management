-- Enable PERMANENT (hard) DELETE from the Deleted Items archive.
--
-- BACKGROUND
--   The app soft-deletes by setting active=false and archiving a row in
--   deleted_items. The new "Delete Permanently" button (admin only) issues real
--   DELETE statements. Most tables only have INSERT/SELECT/UPDATE RLS policies,
--   so without an explicit DELETE policy PostgREST silently affects 0 rows and the
--   permanent delete appears to work but leaves the data in place. This migration
--   adds DELETE policies for authenticated users on the tables the feature touches.
--
-- SECURITY MODEL
--   Role-gating (admin-only) is enforced in the app (sbUserRole==='admin' guards the
--   button, and sbCanWriteTable guards each call). These policies match the existing
--   permissive auth_only pattern used elsewhere in this schema. If you later move to
--   DB-enforced roles, tighten the USING clause to check the caller's profiles.role.
--
-- SAFE TO RE-RUN: each policy is dropped first if it exists.

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'worker_document_files',
    'worker_documents',
    'project_assignments',
    'project_assignment_files',
    'projects',
    'document_set_items',
    'document_sets',
    'properties',
    'accommodation_assignments',
    'vehicles',
    'vehicle_assignments',
    'deleted_items'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_auth_delete', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (true)',
      t || '_auth_delete', t
    );
  END LOOP;
END $$;

-- VERIFY — list the DELETE policies just created
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND policyname LIKE '%_auth_delete'
ORDER BY tablename;
