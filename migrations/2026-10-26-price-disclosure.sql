-- ============================================================================
-- Realtor Helper — migration: per-listing price disclosure
-- File: migrations/2026-10-26-price-disclosure.sql
-- Target: an ALREADY-PROVISIONED live Supabase Postgres database.
-- How to run: Supabase dashboard -> SQL Editor -> New query -> paste this
--             ENTIRE file -> Run. No editing required.
--
-- See migrations/HANDOFF-INSTRUCTIONS.md for context and the operator
-- checklist. The fresh-install schema lives in supabase-schema.sql at the
-- repository root; that file and this one must describe the same final shape.
--
-- WHAT THIS MIGRATION DOES
--   A realtor can choose, per listing, whether customers see the price.
--   When the price is NOT disclosed, public.properties.price is written as
--   NULL so the figure is genuinely absent from the publicly readable row,
--   and the real figure is stored in a new owner-only table,
--   public.property_private_price, which is protected by row-level security.
--   The realtor can turn disclosure back on later without retyping the price.
--
--   The public hide has to happen in the database, not in the page. The
--   properties table has a public read policy and the Supabase anon public key
--   ships in the site's source by design, so anyone can query the REST
--   endpoint directly. A price hidden only in the UI would still be returned
--   by the API and would not be private at all.
--
-- THREE CHANGES
--   1. public.properties.price            -> drop NOT NULL
--   2. public.properties.show_price       -> new boolean, NOT NULL DEFAULT true
--   3. public.property_private_price      -> new table + RLS + 4 owner policies
--
-- NON-DESTRUCTIVE / NO BACKFILL REQUIRED
--   Nothing here deletes, rewrites, or moves existing data. Every existing
--   listing already has a price, and show_price defaults to true, so every
--   existing listing stays public and reads exactly as it does today. There is
--   no backfill step and nothing to run afterwards.
--
-- IDEMPOTENT
--   Safe to run more than once. The column and table use IF NOT EXISTS,
--   DROP NOT NULL is a no-op once applied, and every policy is dropped with
--   DROP POLICY IF EXISTS immediately before it is created (Postgres has no
--   CREATE POLICY IF NOT EXISTS). Re-running replaces the four policies with
--   identical definitions.
--
-- CONTAINS NO CREDENTIALS. Do not paste keys, passwords, or connection
-- strings into this file.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Allow the public price column to hold nothing.
--
-- The column is currently:  price numeric not null check (price >= 0)
-- After this statement it is:  price numeric check (price >= 0)
--
-- The existing CHECK constraint is deliberately left UNCHANGED. In SQL a CHECK
-- constraint is satisfied unless it evaluates to false: when price is NULL the
-- expression `price >= 0` evaluates to NULL (unknown), which the constraint
-- accepts. So a NULL price passes `check (price >= 0)` with no modification,
-- and a negative price is still rejected. Do not drop or re-add it.
--
-- This statement is idempotent: running it when the column is already nullable
-- succeeds and changes nothing.
-- ----------------------------------------------------------------------------
alter table public.properties
  alter column price drop not null;


-- ----------------------------------------------------------------------------
-- 2. Record the realtor's disclosure choice.
--
-- show_price = true  -> customers see properties.price
-- show_price = false -> properties.price is NULL and the real figure lives in
--                       public.property_private_price (step 3)
--
-- The column is itself public, and that is fine: it reveals only that a price
-- is withheld, which is exactly what the customer-facing "Contact owner"
-- treatment tells them anyway. The default of true is what makes this
-- migration backwards compatible with the currently deployed site — existing
-- rows and inserts that never mention show_price keep today's behaviour.
-- ----------------------------------------------------------------------------
alter table public.properties
  add column if not exists show_price boolean not null default true;


-- ----------------------------------------------------------------------------
-- 3. The owner-only private price table.
--
-- One row per listing whose price is withheld. property_id is the primary key,
-- so a listing can have at most one private price. Both foreign keys cascade
-- on delete, so deleting a listing or deleting the realtor's auth user removes
-- the private row automatically — no orphans, no manual cleanup.
--
-- owner_id is stored on this table (rather than being joined through
-- properties) so the RLS policies below can check ownership with a simple
-- column comparison and no subquery against another RLS-protected table.
--
-- price repeats the same `>= 0` guard as the public column. Here it is NOT
-- NULL, because a row only exists when there is a figure to remember.
-- ----------------------------------------------------------------------------
create table if not exists public.property_private_price (
  property_id uuid primary key references public.properties (id) on delete cascade,
  owner_id    uuid not null references auth.users (id) on delete cascade,
  price       numeric not null check (price >= 0),
  updated_at  timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- 3a. Turn on row-level security for the new table.
--
-- This is the control that makes the feature real. With RLS enabled and only
-- the four owner-scoped policies below, a caller holding the anon public key
-- and no session matches no policy and therefore reads zero rows. A signed-in
-- realtor sees only rows where owner_id equals their own auth.uid().
--
-- Idempotent: enabling RLS on a table that already has it is a no-op.
-- ----------------------------------------------------------------------------
alter table public.property_private_price enable row level security;


-- ----------------------------------------------------------------------------
-- 3b. Exactly four owner-scoped policies: select, insert, update, delete.
--
-- There is deliberately NO public read policy on this table. That absence is
-- the whole feature. Adding a permissive policy — anything with a USING clause
-- of `true`, or any policy not keyed on auth.uid() = owner_id — would expose
-- every withheld price to anyone holding the anon key and defeat the purpose
-- of the migration entirely. Do not add one "for convenience" or to make a
-- query work; if a query needs broader access, fix the query.
--
-- Each policy is dropped first so this block can be re-run safely.
-- The names below are matched by the verification block in section 4.
-- ----------------------------------------------------------------------------

-- Read: a realtor can read back their own withheld prices (this is what lets
-- the My listings dashboard show the real figure, and what lets disclosure be
-- turned back on without retyping).
drop policy if exists "private price: owner can select" on public.property_private_price;
create policy "private price: owner can select"
  on public.property_private_price
  for select
  using (auth.uid() = owner_id);

-- Create: a realtor can only create a row that belongs to themselves. WITH
-- CHECK is evaluated against the NEW row, which stops a realtor from writing a
-- row under another user's owner_id.
drop policy if exists "private price: owner can insert" on public.property_private_price;
create policy "private price: owner can insert"
  on public.property_private_price
  for insert
  with check (auth.uid() = owner_id);

-- Update: USING decides which existing rows are visible to the update, and
-- WITH CHECK validates the result. Both are required — with USING alone a
-- realtor could reassign their own row to a different owner_id.
drop policy if exists "private price: owner can update" on public.property_private_price;
create policy "private price: owner can update"
  on public.property_private_price
  for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

-- Delete: a realtor can remove their own private price (for example when they
-- disclose the price again and the application chooses to discard the copy).
drop policy if exists "private price: owner can delete" on public.property_private_price;
create policy "private price: owner can delete"
  on public.property_private_price
  for delete
  using (auth.uid() = owner_id);


-- ----------------------------------------------------------------------------
-- 3c. Table privileges.
--
-- RLS filters WHICH ROWS a role can touch, but it does not grant the role
-- permission to touch the table at all. Those are two separate checks and both
-- must pass. Supabase normally configures default privileges on the public
-- schema so new tables are granted to anon/authenticated automatically, but
-- that is a project setting rather than a guarantee — and if it is not in
-- place, a signed-in realtor gets a bare "permission denied for table
-- property_private_price" instead of an RLS-filtered result.
--
-- So grant explicitly, and only to authenticated. The four policies above then
-- narrow that to the realtor's own rows.
--
-- anon is deliberately NOT granted. RLS already blocks it (no policy matches a
-- caller with no session), so this is defence in depth rather than the primary
-- control.
--
-- Idempotent: re-granting an existing privilege is a no-op.
-- ----------------------------------------------------------------------------
grant select, insert, update, delete
  on public.property_private_price
  to authenticated;

-- Optional hardening, left commented out because it is only worth running if
-- verification query 4.8 below shows anon holds privileges on this table.
-- Revoking is safe for this feature — the site never reads private prices
-- without a session — but revoke statements are worth a deliberate decision
-- rather than being buried in a migration.
-- revoke all on public.property_private_price from anon;


-- ============================================================================
-- 4. VERIFICATION — read-only. Run these after the migration and compare each
--    result against the expectation in its comment. Nothing here changes data.
--    They can be run as one paste; each returns its own result set.
-- ============================================================================

-- 4.1 properties.price must now be nullable.
--     EXPECT exactly one row: column_name = 'price', is_nullable = 'YES'.
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'properties'
  and column_name  = 'price';

-- 4.2 properties.show_price must exist, be boolean, be NOT NULL, default true.
--     EXPECT exactly one row: is_nullable = 'NO', column_default = 'true'.
--     Zero rows means step 2 did not run.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'properties'
  and column_name  = 'show_price';

-- 4.3 The private table must exist with its four expected columns.
--     EXPECT 4 rows: property_id (uuid, NO), owner_id (uuid, NO),
--                    price (numeric, NO), updated_at (timestamptz, NO).
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'property_private_price'
order by ordinal_position;

-- 4.4 Row-level security must be ENABLED on the private table.
--     EXPECT exactly one row with rls_enabled = true.
--     If this returns false, the table is readable by anyone with the anon key
--     and the migration must not be considered complete.
select c.relname as table_name,
       c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'property_private_price';

-- 4.5 Exactly the four owner-scoped policies must exist, and every one of them
--     must be keyed on auth.uid() = owner_id.
--     EXPECT exactly 4 rows, one each for SELECT, INSERT, UPDATE, DELETE:
--       "private price: owner can select"  cmd SELECT  qual mentions owner_id
--       "private price: owner can insert"  cmd INSERT  with_check mentions owner_id
--       "private price: owner can update"  cmd UPDATE  both mention owner_id
--       "private price: owner can delete"  cmd DELETE  qual mentions owner_id
--     More than 4 rows, or any row whose qual/with_check does not reference
--     owner_id, means something extra was added and must be reviewed.
select policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename  = 'property_private_price'
order by cmd, policyname;

-- 4.6 No policy may grant open access. This flags any policy on the private
--     table whose read condition or write condition is missing or is literally
--     true — i.e. a policy that would let the anon key through.
--     EXPECT 0 rows. Any row returned is a privacy hole: drop that policy.
select policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename  = 'property_private_price'
  and (
        (cmd in ('SELECT', 'DELETE') and (qual is null or btrim(qual) = 'true'))
     or (cmd = 'INSERT' and (with_check is null or btrim(with_check) = 'true'))
     or (cmd = 'UPDATE' and (qual is null or btrim(qual) = 'true'
                             or with_check is null or btrim(with_check) = 'true'))
     or (cmd = 'ALL')
      );

-- 4.8 Table privileges on the private table.
--     EXPECT at least the four rows for grantee = 'authenticated'
--     (SELECT, INSERT, UPDATE, DELETE).
--     If any row shows grantee = 'anon', RLS is still blocking that role, but
--     consider running the commented-out revoke in section 3c.
--     If NO rows show grantee = 'authenticated', the grant in 3c did not take
--     and signed-in realtors will get "permission denied" rather than an
--     empty result — re-run section 3c.
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name   = 'property_private_price'
  and grantee in ('anon', 'authenticated')
order by grantee, privilege_type;

-- 4.7 Optional end-to-end sanity check, read-only: existing listings are
--     untouched and still public.
--     EXPECT undisclosed_count = 0 immediately after the migration (no realtor
--     has withheld a price yet) and missing_price_count = 0 (no backfill was
--     needed because every existing listing already has a price).
select count(*)                                  as total_listings,
       count(*) filter (where show_price = false) as undisclosed_count,
       count(*) filter (where price is null)      as missing_price_count
from public.properties;


-- ============================================================================
-- 5. ROLLBACK — COMMENTED OUT ON PURPOSE. Do not run unless you intend to
--    remove the feature. Read both warnings first.
--
--    WARNING 1 — DATA LOSS. Dropping public.property_private_price destroys
--    every withheld price permanently. Those figures exist nowhere else: when
--    a realtor withholds a price, public.properties.price is NULL and this
--    table holds the only copy. There is no way to recover them afterwards
--    except from a database backup. If any listing has show_price = false,
--    export this table before dropping it.
--
--    WARNING 2 — THE NOT NULL RESTORE WILL FAIL while any listing has a null
--    price. ALTER COLUMN ... SET NOT NULL validates every existing row and
--    aborts with an error if even one price is NULL. Either give those
--    listings a price first, or delete them, before attempting it. Running
--    the statement and letting it fail is harmless — it changes nothing — but
--    it will not succeed on its own.
--
--    Suggested order if you do roll back:
--      a. export property_private_price if you want the withheld figures
--      b. restore a price for every listing with price is null
--      c. drop the policies and the table
--      d. drop the show_price column
--      e. restore not null on properties.price
--
--    Note that rolling back the database while the new index.html is still
--    deployed will break the disclosure feature in the site: saving a withheld
--    price will fail. Roll the site back too.
-- ============================================================================

-- -- a/b. (manual: export the withheld figures, then give every null-price
-- --       listing a real price. Do NOT substitute 0 — a 0 price reads to a
-- --       customer as a free property, sorts to the top of price-low-to-high,
-- --       and passes any maximum-price filter. Use the exported figure, or
-- --       delete the listing.)
-- -- select * from public.property_private_price;
-- -- update public.properties set price = <real figure> where id = '<listing id>';

-- -- c. drop the four policies and the private table
-- drop policy if exists "private price: owner can select" on public.property_private_price;
-- drop policy if exists "private price: owner can insert" on public.property_private_price;
-- drop policy if exists "private price: owner can update" on public.property_private_price;
-- drop policy if exists "private price: owner can delete" on public.property_private_price;
-- drop table if exists public.property_private_price;   -- DESTROYS WITHHELD PRICES

-- -- d. drop the disclosure flag
-- alter table public.properties drop column if exists show_price;

-- -- e. restore the original NOT NULL (fails if any price is null — see WARNING 2)
-- alter table public.properties alter column price set not null;

-- ============================================================================
-- End of migration.
-- ============================================================================
