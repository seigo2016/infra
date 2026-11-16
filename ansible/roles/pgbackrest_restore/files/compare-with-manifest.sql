-- Compares the restored database with the manifest written right before the
-- backup (psql variables manifest_counts, manifest_migrations). Every table in
-- the manifest must exist with at least as many rows, and every migration
-- recorded then must be applied. Read-only.
\set ON_ERROR_STOP on
SELECT to_regclass('public.schema_migrations') IS NOT NULL AS has_migrations \gset
\if :has_migrations
SELECT coalesce(jsonb_agg(name ORDER BY name), '[]'::jsonb) AS restored_migrations FROM schema_migrations \gset
\else
SELECT '[]'::jsonb AS restored_migrations \gset
\endif
WITH restored AS (
  SELECT coalesce(jsonb_object_agg(c.relname,
           (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text::bigint),
         '{}'::jsonb) AS counts
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname = 'public'
)
SELECT jsonb_build_object(
  'counts', restored.counts,
  'migrations', :'restored_migrations'::jsonb,
  'short_tables', (SELECT coalesce(jsonb_agg(m.key ORDER BY m.key), '[]'::jsonb)
                   FROM jsonb_each_text(:'manifest_counts'::jsonb) m
                   WHERE coalesce((restored.counts ->> m.key)::bigint, -1) < m.value::bigint),
  'missing_migrations', (SELECT coalesce(jsonb_agg(x ORDER BY x), '[]'::jsonb)
                         FROM jsonb_array_elements_text(:'manifest_migrations'::jsonb) x
                         WHERE NOT (:'restored_migrations'::jsonb ? x))
)
FROM restored;
