# Handoff: run one Supabase migration for "Realtor Helper"

You are being asked to apply a single database migration to a live Supabase
project. Everything you need is in this folder. There is one file to run and
one block of read-only queries to confirm it worked.

---

## 1. The project in four lines

- **Realtor Helper** is a website small independent realtors use to publish
  property listings and share each one as a public link.
- The entire site is a **single static `index.html`** served by **GitHub Pages**.
  No build step, no server-side code, no npm.
- The backend — database, auth, storage — is **Supabase on the free tier**.
- Listings live in a Postgres table `public.properties`, protected by
  row-level security. Published listings are readable by the public; drafts are
  readable only by their owner.

## 2. The Supabase project

| | |
|---|---|
| Project name | `realtor-helper` |
| Project ID | `hldupdnyighbqiczannf` |
| URL | `https://hldupdnyighbqiczannf.supabase.co` |
| Region | East US |
| Plan | Free |

**No credentials are included here, and none are needed to read this
document.** Use your own dashboard access to the project above.

Two standing rules on keys:

- Only the **anon public key** ever belongs in the site's code. It is in the
  page source by design, and the database's row-level security is what keeps
  data safe, not the secrecy of that key.
- The **service-role key must never be placed in site code**, committed, or
  pasted into the migration. It bypasses row-level security entirely.

Note also: free-tier Supabase projects pause after about a week of inactivity.
If the project is paused, resume it from the dashboard before running anything.

## 3. What this migration adds

A **price-disclosure** feature: a realtor decides, per listing, whether
customers see the price.

When a realtor withholds a price:

- `properties.price` is written as **NULL**, so the figure is genuinely absent
  from the publicly readable row.
- `properties.show_price` is set to **false**, recording the choice.
- The real figure is stored in a new table, **`property_private_price`**, which
  has row-level security on and only owner-scoped policies — so the realtor
  keeps their number and can turn disclosure back on later without retyping it.

Customers see a "Contact owner" affordance where the price would be.

**Why the private price needs its own protected table rather than being hidden
in the UI:** `properties` has a public read policy and the anon public key
ships in the page source. Anyone can query the REST endpoint directly, so a
price hidden only in the rendering layer is still returned by the API. It would
not be private at all. The privacy has to be enforced by the database.

So the migration makes three changes:

1. drops `not null` from `properties.price`
2. adds `properties.show_price boolean not null default true`
3. creates `property_private_price` with RLS enabled and exactly four
   owner-scoped policies (select / insert / update / delete), and deliberately
   **no public read policy**

## 4. What to run, and where

One file:

```
migrations/2026-10-26-price-disclosure.sql
```

Steps:

1. Open the Supabase dashboard for project `hldupdnyighbqiczannf`.
2. Go to **SQL Editor → New query**.
3. Paste the **entire** file. No editing is required — it runs top to bottom as
   a single paste.
4. Click **Run**.

It is **idempotent**: `if not exists` on the new column and table, and each
policy is dropped with `drop policy if exists` immediately before it is
created. Running it twice is safe.

Do not run the rollback section at the bottom — it is commented out on purpose.

## 5. How to verify it worked

Section 4 of the migration file is a **verification block** of read-only
`select` statements, each with its expected result stated in a comment above
it. Run it after the migration and compare. It confirms:

- `properties.price` is now nullable
- `properties.show_price` exists, is `not null`, and defaults to `true`
- `property_private_price` exists with its four columns
- row-level security is **enabled** on `property_private_price`
- exactly the four owner-scoped policies exist, each keyed on
  `auth.uid() = owner_id`
- **no** permissive/open policy exists on the private table (that query must
  return zero rows — any row it returns is a privacy hole)

The RLS check and the open-policy check are the two that matter most. If RLS is
not enabled, or an open policy exists, withheld prices are readable by anyone
with the anon key and the migration should not be treated as done.

## 6. Non-destructive, and no backfill

Nothing is deleted, rewritten, or moved. Every existing listing already has a
price, and `show_price` defaults to `true`, so every existing listing stays
public and reads exactly as it does today. There is no backfill step and
nothing to run afterwards.

One detail worth knowing rather than re-deriving: `properties.price` keeps its
existing `check (price >= 0)` unchanged. A SQL check constraint is satisfied
unless it evaluates to false, and `price >= 0` evaluates to NULL (unknown) when
price is NULL — so a null price passes the constraint as written, while a
negative price is still rejected.

## 7. Ordering against the site code

**The migration is backwards compatible with the currently deployed
`index.html`, so it is safe to run before the new site code is published.**
That is true of the SQL in this folder: the only change to an existing column
is relaxing a constraint (`drop not null`), which cannot break a client that
always sends a price; the new column has a default of `true`, so inserts that
never mention it behave exactly as before; and the new table is additive and
read by nothing today.

Recommended order: **run the migration first, publish the new `index.html`
after.** The reverse order is the one that breaks (see next section).

## 8. What breaks if it is NOT run

The new site code will load and browse normally, but a realtor who sets a
listing's price to undisclosed will hit a **not-null violation on
`properties.price`** and the save will fail. The site surfaces that as a
visible error rather than failing silently, so it is diagnosable — but the
feature does not work until this migration is applied.

## 9. Rollback, and what it costs

The migration file's section 5 contains a commented-out rollback. Two warnings
on it:

- **Dropping `property_private_price` permanently destroys every withheld
  price.** Those figures exist nowhere else — the public column is NULL for
  exactly those listings, and this table holds the only copy. Export the table
  first if any listing has `show_price = false`.
- **Restoring `not null` on `properties.price` will fail outright while any
  listing has a null price.** `set not null` validates every row and aborts.
  Give those listings a price, or remove them, first. (The failed statement
  itself changes nothing, so a failed attempt is harmless.)

If you roll the database back, roll the site code back too, or the disclosure
feature will error on save.

## 10. One note on freshness

A separate workflow is finishing the application code in this repository and
may refine the two files in this folder so they match the final code exactly.
**Re-read `migrations/2026-10-26-price-disclosure.sql` before you run it** and
check whether it has changed since you received this document.

A related file, `supabase-schema.sql` at the repository root, is the
**fresh-install** schema for standing up a brand-new project from scratch. Do
**not** run it against the existing database — use the migration file in this
folder for that.
