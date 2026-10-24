-- Realtor Helper — Supabase schema
-- Setup order: first create a public Storage bucket named "property-photos",
-- then run this whole file in Supabase: SQL Editor > New query > paste > Run.
-- It creates the table AND the storage policies, so photo upload works out of the box.
-- The alter below is a real statement, not just a comment: on an existing
-- project CREATE TABLE IF NOT EXISTS is a no-op, so this adds the
-- type-specific details column to a table created before it existed.

create table if not exists public.properties (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users (id) on delete cascade,
  title text not null,
  price numeric not null check (price >= 0),
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
