-- Production restore only: raise the Control Plane's epoch for good, so work
-- dispatched before the restore cannot report until it is reconciled with the
-- Bridge journals (RFC-0001 §9, A10). Prints the new epoch, or "absent" for a
-- database from a release that has no epoch yet.
\set ON_ERROR_STOP on
SELECT to_regclass('public.control_plane') IS NOT NULL AS has_epoch \gset
\if :has_epoch
UPDATE control_plane SET epoch = epoch + 1 RETURNING epoch;
\else
SELECT 'absent';
\endif
