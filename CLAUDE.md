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
4. For "Foto toevoegen": deploy `supabase/functions/foto-naar-items/index.ts` as Edge Function `foto-naar-items` with "Verify JWT" off (dashboard editor, or `supabase functions deploy foto-naar-items --no-verify-jwt`) and set the secret `ANTHROPIC_API_KEY`. The function is not part of the GitHub Pages deploy: after changing it, deploy it again.

The app is hosted on GitHub Pages from `main` (https://gijsh-git.github.io/boodschappen/), so pushing to `main` deploys.

## Architecture

**Load order matters.** `index.html` loads three classic scripts in order: supabase-js v2 from the jsDelivr CDN (global `supabase`), `config.js` (sets `window.CONFIG`), then `app.js`. There are no modules or imports.

**Views.** `index.html` holds eleven `<section id="view-…">` elements (`login`, `forgot`, `sent`, `password`, `naam`, `profiel`, `setup`, `nieuw`, `list`, `aankopen`, `foto`); `show()` toggles their `hidden` attribute. Flow: `init()` → session check → `route()` fetches the user's `profiles` row (none yet → `naam` view to enter a display name once; it can be changed later via the profile button top right in the list view and in the overview, which opens `profiel`: the name with a pencil button behind it to edit, and "Uitloggen". "Terug" returns to the overview when `lijstenOpen` is set, otherwise to the list) → `loadLijsten()` fetches all the user's `list_members` rows into the module-level `lijsten` array → either `setup` (no lists yet) or `openList()` on the last opened list (id remembered in `localStorage` under `bonusbuddy-lijst`, falling back to the first list).

**Multiple lists.** The `setup` view is the overview "Mijn lijsten": it lists your lists (tap to switch) and is reachable from the list view via the list button top right. Its plus button opens the `nieuw` view, which holds the forms to create a list or join by invite code. Each row has a switch "Meetellen voor aankoopprofiel", stored in `lists.counts_for_profile` (default true) through the `set_list_profile` RPC. The setting belongs to the list, so it is shared by all members; `buy_item` reads it to decide whether a purchase is stored (see "Purchases"). `route()` runs again on every auth event (e.g. when the app returns to the foreground), so screens that must stay put set a flag it checks first: `naamOpen`, `profielOpen`, `lijstenOpen`, `aankopenOpen`, `fotoOpen`.

**Auth is invite-only with passwords.** Signups are disabled in the Supabase dashboard; the owner adds people there with "Invite user". Login is `signInWithPassword`. "Wachtwoord vergeten?" goes `login` → `forgot` (request the mail) → `sent` (confirmation, with resend). Invite and reset mails land back on the app with `type=invite` / `type=recovery` in the URL hash, which `app.js` reads before creating the Supabase client (the client clears the hash). That sets `mustSetPassword`, which makes `route()` show the `password` view instead of the list until `updateUser({ password })` succeeds. Supabase's English auth errors are mapped to Dutch in `nl()`.

**Styling.** `styles.css` uses CSS variables with a dark-mode override, except the `.auth` screens (login, password), which pin the light values so they always look like the design. Fonts come from Google Fonts.

**State and sync.** `app.js` keeps a module-level `items` array as the single source of truth for rendering; `render()` rebuilds the `<ul id="items">` from it. Three things mutate it and must stay consistent:

- Local actions apply optimistically (`koop()`, `remove()`) and call `loadItems()` to resync if the Supabase write fails.
- A Supabase Realtime `postgres_changes` channel per list, filtered on `list_id`, applies INSERT/UPDATE/DELETE from the other user. Inserts are de-duplicated by `id` because your own insert arrives both from the `.insert().select()` response and from the realtime event.
- The same channel also listens to `list_members` (see "Members" below).
- A `visibilitychange` handler refetches everything when the app returns to the foreground, since phones drop the realtime socket in standby.

**Swipe.** There is no checking off any more: an item is either on the list or gone. Each row (`itemRow()`) is a coloured background layer plus a foreground layer that `maakSwipebaar()` drags with pointer events (`touch-action: pan-y` keeps vertical scrolling). Right past the threshold calls `koop()` (bought), left calls `remove()` (deleted, no purchase); the ✓ and × buttons on the row do the same without swiping and are hidden on touch screens (`@media (hover: none) and (pointer: coarse)`). While a row is being dragged `render()` is postponed (`slepen` / `renderWacht`), otherwise a realtime event would rebuild the row under your finger. After either action `toonOngedaan()` shows an undo bar for 5 seconds. The hint about swiping above the list can be dismissed; that is remembered per device in `localStorage` under `bonusbuddy-veeguitleg`.

**Purchases.** `purchases` holds what was actually bought (`list_id`, `name`, `normalized_name`, `quantity`, `bought_by`, `bought_at`, plus `item_id`, `added_by`, `item_created_at` so undo can restore the item exactly). Members can select and delete (the × per row in the `aankopen` view, `verwijderAankoop()`); inserting goes only through two `security definer` RPCs. `buy_item(p_item)` deletes the item and, only when `lists.counts_for_profile` is true, inserts the purchase in the same transaction; it returns the purchase id or null. `undo_purchase(p_purchase)` deletes the purchase and re-inserts the item. Undo without a purchase (deleted item, or a list that does not count) re-inserts the item from the client with its original id. `bought_by` is null for purchases migrated from old checked-off items. The `aankopen` view, opened with the button next to "Deelnemers", lists the purchases of the current list (`loadAankopen()`, newest first, max 200) and is kept live by the same realtime channel; a DELETE event only carries the `id`.

**Members.** The list view has a collapsible `<details class="leden">` block above the add form showing who is in the list, rendered by `renderLeden()` from the module-level `leden` array (names come from `namen`). `loadLeden()` runs alongside `loadItems()`, and the realtime channel refetches on a `list_members` INSERT and drops the row on DELETE. Only the creator sees "Verwijderen" per member; that calls the `remove_member` RPC, which also issues a new `invite_code` so the removed person cannot rejoin with the old one. When your own membership disappears (removed by the creator, or the list was deleted), `verlaatLijst()` closes the list and returns to the overview. The DELETE handler checks `list_id` itself rather than trusting the channel filter.

**Security lives in the database, not the client.** The anon key is public by design. Every table has RLS enabled, and all policies go through `is_member(list_id)`. `lists` and `list_members` have select policies only: the client cannot insert into them directly. Creating, joining, changing and deleting lists goes through the `security definer` RPCs `create_list`, `join_list`, `set_list_profile`, `remove_member` (creator only) and `delete_list` (creator only; items, purchases and memberships cascade), which is why `app.js` uses `db.rpc(...)` for those and plain table queries only for `items`, `profiles` and reading or deleting `purchases`. `profiles` (one row per user, `display_name`) is writable only for your own row and readable by yourself and by people you share a list with. A new table or a new client-side write needs a matching policy or RPC in `schema.sql`, and tables that should sync live must be added to the `supabase_realtime` publication.

**Deals.** `deals` holds supermarket offers (`supermarkt` AH/PLUS, `productnaam`, `omschrijving`, `prijs`, `geldig_van`, `geldig_tot`). For now it is filled by hand with test data from `seed_deals.sql` (which empties the table first); fetching real offers comes later and writes with the service role. Authenticated users can only select; there are no write policies or grants. The client never reads `deals` directly: `loadDeals()` calls the `security invoker` RPC `deals_for_list(p_list)`, which matches each item's `normalized_name` (generated column, `lower(trim(name))`) against currently valid deals with pg_trgm's `strict_word_similarity` and returns `(item_id, supermarkt, aantal)`. The threshold (`0.5`) is the single sensitivity knob and lives in that function. `loadDeals()` runs after `loadItems()`, after your own insert and on a realtime item INSERT; `itemRow()` shows the label ("Bonus: AH 2, PLUS 1").

**Photo.** "Foto toevoegen" under the add form opens a file input (`accept="image/*"`, no `capture`, so the phone offers camera or library). `leesFoto()` shrinks the image on a canvas (`verkleinFoto()`, longest side `FOTO_MAX`, JPEG) and calls the Edge Function `foto-naar-items` through `db.functions.invoke`. The function checks the session itself with `auth.getUser` (it is deployed without JWT verification), sends the image to the Claude API with a JSON schema as output format and returns `{ producten: [{ naam, hoeveelheid }] }`, or `{ fout }` with a Dutch message. The rules for turning recipe ingredients into groceries (no cooking measures, skip `IN_HUIS`) live in `INSTRUCTIES` in the function; the model is the constant `MODEL`. The function writes nothing: the `foto` view lets you untick and edit the products, and the client then inserts them into `items` in one call under the normal RLS policy. `route()` checks `fotoOpen` a second time after `loadLijsten()`, because returning from the camera fires an auth event just before the chosen photo arrives. `fotoVraag` makes a late answer after cancelling harmless. The Anthropic key exists only as a Supabase secret.

**Service worker.** `sw.js` is network-first with a cache fallback, same-origin GET only, so Supabase and CDN requests are never cached. When adding a new static file, add it to `ASSETS`; bump the `CACHE` name to evict old caches.

## Wensen

In bouwvolgorde:

1. Gedeelde boodschappenlijst voor mij en mijn vriendin, wijzigingen direct zichtbaar bij de ander
2. Items toevoegen, afstrepen en verwijderen
3. Zien wie een item heeft toegevoegd
4. Kortingen van supermarkten tonen bij items op de lijst
5. Items naar rechts swipen = gekocht (met datum en wie), naar links = verwijderd. Ook bruikbaar zonder swipen.
6. Een tabel met aankopen als basis voor het aankoopprofiel, alleen voor lijsten die meetellen voor het profiel
7. Alle onderdelen (lijstitems, aankopen, bonregels, aanbiedingen) koppelen aan hetzelfde product via zoekwoorden
8. Items groeperen per afdeling
9. Een lijst vullen vanuit een foto of screenshot (bijv. ingrediënten van een recept)
10. Kassabonnen scannen om aankopen toe te voegen, ook historische bonnen in bulk
11. Op basis van patronen gericht kortingsadvies geven

## Werkwijze

Leg bij elke wijziging kort uit wat je doet en waarom, in het Nederlands.
