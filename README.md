# Realtor Helper — real backend version

What it does: many realtors sign up, each saves their own properties
(photos, address, price, beds/baths, sq ft, description, contact), and
each property gets a shareable page a customer can open from a text
or email with no account.

## 1. Try it today (demo mode, no account needed)

Open `index.html` in a browser. Sign up with any email, add a listing,
open it, and use Copy link / Share by email / Share by text.
Demo listings and accounts live only in that browser.

## 2. Turn on the real backend (about 15 minutes, free Supabase tier)

1. Create a free project at supabase.com.
2. In Storage, create a **public** bucket named `property-photos`.
3. In Supabase, open SQL Editor and run `supabase-schema.sql` from this folder.
   This creates the properties table AND the photo storage policies, so
   photo upload works out of the box — no separate storage-policy step.
4. In Supabase > Settings > API, copy the Project URL and the
   **anon public** key (never the service-role key).
5. In `index.html`, fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY`
   at the top of the script. The page then switches from demo mode
   to live mode automatically — same code, no rebuild.
6. In Supabase > Authentication, enable Email sign-in.

Security notes: the anon key is designed to be public in browser code;
row-level security in the schema is what protects listings — anyone
can read a listing (so share links work), only the owner can
create, edit or delete their own.

## 3. Publish it

Option A — GitHub Pages (free): push this folder to a public repo and
enable Pages from the main branch, root folder.
Option B — Netlify / Vercel: upload this folder as a static site.
The frontend talks directly to Supabase, so no server code is needed.

## What is still to decide later

- Custom domain, and whether realtors pay (not in this version).
- Photo moderation and listing expiry, if the site grows.
- A public “all realtors” directory page, separate from share links.
