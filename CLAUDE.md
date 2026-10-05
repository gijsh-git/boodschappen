# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"BonusBuddy" (folder and repo are still called `boodschappen`) is a shared grocery-list PWA for a household (two partners sharing one list). It is a static site with no build step, no package manager, no tests and no linter: plain HTML/CSS/JS talking directly to Supabase from the browser. All UI text, code comments, SQL policy names and CSS variable names are in Dutch; keep new ones in Dutch.

## Running

There is nothing to build. Serve the directory over HTTP (the service worker and Supabase auth redirect do not work from `file://`):

```sh
python3 -m http.server 8000
```

Before the app does anything useful:

1. Run `schema.sql` once in the Supabase SQL Editor of a fresh project. It is not idempotent (plain `create table` / `create policy`), so schema changes to an existing project need separate `alter` statements.
2. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `config.js`. While the URL still contains the `JOUW-PROJECT` placeholder, `init()` in `app.js` stops at the login view with a "fill in config.js" message.
3. The origin you serve from must be an allowed redirect URL in Supabase Auth, since invite and password-reset mails link back to `location.origin + location.pathname`.

The app is hosted on GitHub Pages from `main` (https://gijsh-git.github.io/boodschappen/), so pushing to `main` deploys.

## Architecture

**Load order matters.** `index.html` loads three classic scripts in order: supabase-js v2 from the jsDelivr CDN (global `supabase`), `config.js` (sets `window.CONFIG`), then `app.js`. There are no modules or imports.

**Views.** `index.html` holds four `<section id="view-…">` elements (`login`, `password`, `setup`, `list`); `show()` toggles their `hidden` attribute. Flow: `init()` → session check → `route()` looks up the user's first `list_members` row → either `setup` (create a list or join by invite code) or `openList()`. The client only ever opens one list per user (`.limit(1)`), although the schema allows membership of several.

**Auth is invite-only with passwords.** Signups are disabled in the Supabase dashboard; the owner adds people there with "Invite user". Login is `signInWithPassword`. Invite and "Wachtwoord vergeten?" mails land back on the app with `type=invite` / `type=recovery` in the URL hash, which `app.js` reads before creating the Supabase client (the client clears the hash). That sets `mustSetPassword`, which makes `route()` show the `password` view instead of the list until `updateUser({ password })` succeeds. Supabase's English auth errors are mapped to Dutch in `nl()`.

**Styling.** `styles.css` uses CSS variables with a dark-mode override, except the `.auth` screens (login, password), which pin the light values so they always look like the design. Fonts come from Google Fonts.

**State and sync.** `app.js` keeps a module-level `items` array as the single source of truth for rendering; `render()` rebuilds both `<ul>`s (open and checked) from it. Three things mutate it and must stay consistent:

- Local actions apply optimistically (toggle, remove, clear-done) and call `loadItems()` to resync if the Supabase write fails.
- A Supabase Realtime `postgres_changes` channel per list, filtered on `list_id`, applies INSERT/UPDATE/DELETE from the other user. Inserts are de-duplicated by `id` because your own insert arrives both from the `.insert().select()` response and from the realtime event.
- A `visibilitychange` handler refetches everything when the app returns to the foreground, since phones drop the realtime socket in standby.

**Security lives in the database, not the client.** The anon key is public by design. Every table has RLS enabled, and all policies go through `is_member(list_id)`. `lists` and `list_members` have select policies only: the client cannot insert into them directly. Creating and joining lists goes through the `security definer` RPCs `create_list` and `join_list`, which is why `app.js` uses `db.rpc(...)` for those and plain table queries only for `items`. A new table or a new client-side write needs a matching policy or RPC in `schema.sql`, and tables that should sync live must be added to the `supabase_realtime` publication.

**`items.normalized_name`** is a generated column (`lower(trim(name))`) that the client does not use yet; it exists as groundwork for later matching items against store discounts.

**Service worker.** `sw.js` is network-first with a cache fallback, same-origin GET only, so Supabase and CDN requests are never cached. When adding a new static file, add it to `ASSETS`; bump the `CACHE` name to evict old caches.

## Wensen

- Gedeelde boodschappenlijst voor mij en mijn vriendin, wijzigingen direct zichtbaar bij de ander
- Items toevoegen, afstrepen en verwijderen
- Later: zien wie een item heeft toegevoegd, en items groeperen per afdeling
- Op termijn: kortingen van supermarkten tonen bij items op de lijst

## Werkwijze

Leg bij elke wijziging kort uit wat je doet en waarom, in het Nederlands.
