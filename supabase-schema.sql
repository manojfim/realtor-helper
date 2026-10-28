-- Realtor Helper — Supabase schema (FRESH INSTALL)
-- Setup order: first create a public Storage bucket named "property-photos",
-- then run this whole file in Supabase: SQL Editor > New query > paste > Run.
-- It creates the tables AND the storage policies, so photo upload works out of the box.
-- The alters below are real statements, not just comments: on an existing
-- project CREATE TABLE IF NOT EXISTS is a no-op, so they add columns to a
-- table created before those columns existed.
--
-- ============================================================================
-- RELATIONSHIP TO THE MIGRATION FILE — keep these two in step
-- ============================================================================
-- This file describes the FINAL shape of the database, including per-listing
-- price disclosure. An ALREADY-PROVISIONED project must not be fixed up by
-- re-reading this file; it runs the standalone, idempotent migration instead:
--
--     migrations/2026-10-26-price-disclosure.sql
--     migrations/HANDOFF-INSTRUCTIONS.md      (operator checklist)
--
-- The three things that file adds, and that this file therefore already
-- contains, are:
--   1. public.properties.price            -> nullable (the `not null` dropped,
--                                            the `check (price >= 0)` KEPT)
--   2. public.properties.show_price       -> boolean not null default true
--   3. public.property_private_price      -> table + RLS + 4 owner policies
--                                            + grant to authenticated only
--
-- If either file changes, change BOTH. A fresh install that followed only this
-- file and an existing project that ran only the migration must end up with
-- the same schema.
--
-- ORDERING, which is strict and one-way: the migration is safe to run against
-- the CURRENTLY DEPLOYED page, but the new index.html is NOT safe against an
-- un-migrated database (it sends show_price on every payload and writes
-- property_private_price on every save, so every create and every edit would
-- fail; Publish/Unpublish and delete are unaffected). Migrate first, publish
-- second.
-- ============================================================================

create table if not exists public.properties (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users (id) on delete cascade,
  title text not null,
  -- NULLABLE on purpose. A null price means "the realtor has not disclosed this
  -- price to customers" (show_price = false) and the real figure lives in
  -- public.property_private_price below. The check constraint is deliberately
  -- kept as-is: in SQL a CHECK passes unless it evaluates to false, and
  -- `null >= 0` evaluates to null (unknown), so a null price is accepted while a
  -- negative price is still rejected.
  price numeric check (price >= 0),
  -- The realtor's disclosure choice. Public, which is fine: it reveals only that
  -- a price is withheld, which is exactly what the customer-facing
  -- "Price on request" treatment says anyway. Defaulting to true is what keeps
  -- existing rows and any insert that never mentions it reading as it does today.
  show_price boolean not null default true,
  status text not null default 'For sale',
  address text not null,
  city text not null,
  state text not null,
  zip text not null,
  type text not null default 'Single family',
  beds numeric not null default 0,
  baths numeric not null default 0,
  sqft integer,
  description text not null default '',
  photo text,
  details jsonb not null default '{}'::jsonb,
  agent text not null default '',
  phone text default '',
  agent_email text default '',
  created_at timestamptz not null default now()
);

alter table public.properties add column if not exists details jsonb not null default '{}'::jsonb;

-- The video tour (details.videoId) needs NO schema change: it is one key inside the
-- existing details jsonb, holding the bare validated 11-character YouTube id.

-- Price disclosure, for a project created before this file carried it. These two are
-- the same statements the migration runs, and both are no-ops once applied.
alter table public.properties add column if not exists show_price boolean not null default true;
alter table public.properties alter column price drop not null;

alter table public.properties enable row level security;

-- Anyone can read PUBLISHED listings: that is what makes a share link work
-- for a customer who has no account. Draft listings are visible only to
-- their owner — an anonymous API query must not return Draft rows.
drop policy if exists "Public read" on public.properties;
create policy "Public read" on public.properties
  for select using (status <> 'Draft' OR auth.uid() = owner_id);

-- Only the owner can create / change / delete their own listings.
drop policy if exists "Owner insert" on public.properties;
create policy "Owner insert" on public.properties for insert with check (auth.uid() = owner_id);

drop policy if exists "Owner update" on public.properties;
create policy "Owner update" on public.properties for update using (auth.uid() = owner_id);

drop policy if exists "Owner delete" on public.properties;
create policy "Owner delete" on public.properties for delete using (auth.uid() = owner_id);

-- ============================================================================
-- The owner-only private price table.
-- One row per listing whose price is withheld from customers. The public hide has
-- to happen in the DATABASE, not in the page: public.properties has a public read
-- policy and the anon public key ships in the site's source by design, so a price
-- hidden only in the UI would still be returned by the REST API and would not be
-- private at all.
--
-- owner_id is stored here (rather than joined through properties) so the policies
-- below can check ownership with a plain column comparison and no subquery against
-- another RLS-protected table. Both foreign keys cascade on delete, so removing a
-- listing or a realtor's auth user removes the private row automatically.
-- ============================================================================
create table if not exists public.property_private_price (
  property_id uuid primary key references public.properties (id) on delete cascade,
  owner_id    uuid not null references auth.users (id) on delete cascade,
  price       numeric not null check (price >= 0),
  updated_at  timestamptz not null default now()
);

alter table public.property_private_price enable row level security;

-- Exactly four owner-scoped policies: select, insert, update, delete.
-- There is deliberately NO public read policy, and that absence is the whole
-- feature. Adding anything with `using (true)`, or any policy not keyed on
-- auth.uid() = owner_id, would expose every withheld price to anyone holding the
-- anon key. Do not add one to make a query work; fix the query.
drop policy if exists "private price: owner can select" on public.property_private_price;
create policy "private price: owner can select" on public.property_private_price
  for select using (auth.uid() = owner_id);

drop policy if exists "private price: owner can insert" on public.property_private_price;
create policy "private price: owner can insert" on public.property_private_price
  for insert with check (auth.uid() = owner_id);

-- Both clauses are required on update: with USING alone a realtor could reassign
-- their own row to a different owner_id.
drop policy if exists "private price: owner can update" on public.property_private_price;
create policy "private price: owner can update" on public.property_private_price
  for update using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

drop policy if exists "private price: owner can delete" on public.property_private_price;
create policy "private price: owner can delete" on public.property_private_price
  for delete using (auth.uid() = owner_id);

-- Table privileges. RLS filters WHICH ROWS a role may touch; it does not grant the
-- role permission to touch the table at all. Those are two separate checks and both
-- must pass, so grant explicitly — and only to authenticated, which the four
-- policies above then narrow to the realtor's own rows. anon is deliberately NOT
-- granted: RLS already blocks it (no policy matches a caller with no session), so
-- this is defence in depth rather than the primary control.
grant select, insert, update, delete
  on public.property_private_price
  to authenticated;

-- Storage policies for the "property-photos" bucket.
-- Anyone can view a photo (that is what makes share links work for customers
-- with no account). Only a signed-in realtor can upload, change or delete
-- photos, and only inside their own user-id folder (the app uploads to
-- "<user-id>/<timestamp>-<filename>").
drop policy if exists "Public read photos" on storage.objects;
create policy "Public read photos" on storage.objects
  for select using (bucket_id = 'property-photos');

drop policy if exists "Owner upload photos" on storage.objects;
create policy "Owner upload photos" on storage.objects
  for insert with check (
    bucket_id = 'property-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Owner update photos" on storage.objects;
create policy "Owner update photos" on storage.objects
  for update using (
    bucket_id = 'property-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Owner delete photos" on storage.objects;
create policy "Owner delete photos" on storage.objects
  for delete using (
    bucket_id = 'property-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
