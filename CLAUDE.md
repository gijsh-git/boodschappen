# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It holds what every task needs; the details per domain are in `docs/systeem/` (see "Where the details are").

## What this is

"BonusBuddy" (folder and repo are still called `boodschappen`) is a shared grocery-list PWA for a household (two partners sharing one list). It is a static site with no build step, no package manager, no tests and no linter: plain HTML/CSS/JS talking directly to Supabase from the browser. All UI text, code comments, SQL policy names and CSS variable names are in Dutch; keep new ones in Dutch.

## Running

There is nothing to build. Serve the directory over HTTP (the service worker and Supabase auth redirect do not work from `file://`):

```sh
python3 -m http.server 8000
```

`config.js` needs `SUPABASE_URL` and `SUPABASE_ANON_KEY`; while the URL still contains `JOUW-PROJECT`, `init()` stops at the login view. The app is hosted on GitHub Pages from `main` (https://gijsh-git.github.io/boodschappen/), so pushing to `main` deploys. The Edge Functions in `supabase/functions/` are not part of that deploy: after changing one, deploy it again (`supabase functions deploy <naam> --no-verify-jwt`). A fresh database, the redirect URLs, every function with its secrets, the Vault entries and the Git hook: `docs/systeem/opzet.md`.

`docs/producttypes-export.csv` is a printout of the type list in the database, rewritten and added by the pre-commit hook on every commit. Never edit it by hand and never load types from it.

## Architecture

**Load order matters.** `index.html` loads five classic scripts in order: supabase-js v2 from the jsDelivr CDN (global `supabase`), `config.js` (sets `window.CONFIG`), `data.js` (global `Data`, all Supabase calls, see `ARCHITECTURE.md`; `app.js` calls `Data.init(url, key)`, which creates the client), `logica.js` (global `Logica`, state and rules without DOM; for now the favourites, Voor jou, the deals on the list and the screen "Koppelingen"), then `app.js`. There are no modules or imports. Every Supabase call lives in `data.js`: tables, RPCs, auth, the Edge Functions and the live channel (`Data.volgLijst()` / `Data.stopVolgen()`, which hands the Supabase messages to handlers in `subscribe()`). `app.js` contains no `db.`; where this file names a Supabase call (`db.rpc(...)`, `signInWithPassword`, `db.functions.invoke`), it is made by the matching function in `Data`. The rest of the logic still lives in `app.js` and moves to `logica.js` part by part (see `ARCHITECTURE.md`).

**Views.** `index.html` holds sixteen `<section id="view-…">` elements (`login`, `forgot`, `sent`, `password`, `naam`, `profiel`, `producten`, `voorjou`, `setup`, `nieuw`, `list`, `aankopen`, `foto`, `bon`, `bonnen`, `stapel`); `show()` toggles their `hidden` attribute. Flow: `init()` → session check → `route()` fetches the user's `profiles` row (none yet → `naam` view to enter a display name once; what the `profiel` view holds is under "Profile screen") → `loadLijsten()` fetches all the user's `list_members` rows into the module-level arrays `lijsten` (active) and `archief` (archived) → either `setup` (no lists yet) or `openList()` on the last opened list (id remembered in `localStorage` under `bonusbuddy-lijst`, falling back to the first list).

`route()` runs again on every auth event (e.g. when the app returns to the foreground), so screens that must stay put set a flag it checks first: `naamOpen`, `profielOpen`, `voorjouOpen`, `lijstenOpen`, `aankopenOpen`, `fotoOpen`, `bonOpen`.

**Tab bar and back.** `<nav id="tabbalk">` (Lijst, Voor jou, Profiel) is fixed at the bottom; `show()` only shows it on the views in `TABS` (`list`, `setup`, `voorjou`, `profiel`) and marks the current tab. "Lijst" (`naarLijst()`) opens the overview "Mijn lijsten"; only when you have exactly one list it goes straight to that list. Sub-screens (`aankopen`, `bonnen`, `stapel`, `producten`, `nieuw`) have a round back button top left and `data-terug="<id of that button>"` on the section: `maakTerugveegbaar()` lets you swipe the screen to the right, which clicks that button. `foto` and `bon` keep "Annuleren" at the bottom and cannot be swiped away, because leaving them discards work.

**State and sync.** `app.js` keeps a module-level `items` array as the single source of truth for rendering; `render()` rebuilds the `<ul id="items">` from it. Three things mutate it and must stay consistent:

- Local actions apply optimistically (`koop()`, `remove()`) and call `loadItems()` to resync if the Supabase write fails.
- A Supabase Realtime `postgres_changes` channel per list, filtered on `list_id`, applies INSERT/UPDATE/DELETE from the other user. Inserts are de-duplicated by `id` because your own insert arrives both from the `.insert().select()` response and from the realtime event.
- The same channel also listens to `list_members` (see "Members" in `docs/systeem/lijsten.md`).
- A DELETE on `items` and `purchases` only carries the `id` (default replica identity), so Realtime cannot filter it on `list_id` and would not send it at all. `Data.volgLijst()` therefore listens to those two DELETEs without a filter, and the handlers in `subscribe()` ignore ids that are not in the open list. Do not put a `list_id` filter back on them.
- A `visibilitychange` handler refetches everything when the app returns to the foreground, since phones drop the realtime socket in standby.

**Security lives in the database, not the client.** The anon key is public by design. Every table has RLS enabled, and all policies go through `is_member(list_id)`. `lists` and `list_members` have select policies only: the client cannot insert into them directly. Creating, joining, changing and archiving lists goes through the `security definer` RPCs `create_list`, `join_list`, `create_invite` (creator and managers), `set_list_profile`, `remove_member` and `set_member_manager` (both creator only) and `archive_list` and `delete_list` (both creator only; deleting cascades to items, purchases, receipts and memberships), which is why `app.js` uses `db.rpc(...)` for those and plain table queries only for `items`, `profiles` and reading or deleting `purchases`. `receipts` is select-only too; it is written by `save_receipt`. `profiles` (one row per user, `display_name`) is writable only for your own row and readable by yourself and by people you share a list with. A new table or a new client-side write needs a matching policy or RPC in a new migration, and tables that should sync live must be added to the `supabase_realtime` publication.

**Styling.** `styles.css` uses CSS variables with a dark-mode override, except the `.auth` screens (login, password), which pin the light values so they always look like the design. Fonts come from Google Fonts.

**Service worker.** `sw.js` is network-first with a cache fallback, same-origin GET only, so Supabase and CDN requests are never cached. When adding a new static file, add it to `ASSETS`. Bump the `CACHE` name in every commit that changes a client file (`index.html`, the scripts, `styles.css`), otherwise phones keep the old ones.

## Where the details are

Read the file for the domain you work in before changing it. A reference like (see "Offers") names a heading in one of these files.

| Werk je aan | Lees eerst | Kopjes |
|---|---|---|
| Lijsten, archiveren, leden, uitnodigingen, inloggen | `docs/systeem/lijsten.md` | Multiple lists, Archiving and deleting, Members, Invitations, Auth is invite-only with passwords |
| Items op de lijst, swipen, aankopen, foto naar items | `docs/systeem/items-en-aankopen.md` | Swipe, Purchases, Photo |
| Profielscherm, aankoopprofiel, favorieten, Voor jou | `docs/systeem/profiel-en-voorjou.md` | Profile screen, Purchase profile, Favourites, Voor jou |
| Aanbiedingen, Bonus-label, bonuspaneel, kiezen, wegklikken | `docs/systeem/aanbiedingen.md` (matching leunt op `producttypes.md`) | Offers, Bonus label, Matching offers, Variant, Choosing an offer, Dismissing an offer, Logging offer choices |
| Producttypes, termen matchen, scherm Koppelingen, classificeren | `docs/systeem/producttypes.md` | Product types, Matching list terms |
| Bonnen scannen, AH-import, de ophaalscripts van AH en PLUS | `docs/systeem/bonnen.md` | Receipts, Historic AH receipts, AH bonus exploration, Fetching PLUS offers |
| Edge Functions, secrets, een nieuwe omgeving | `docs/systeem/opzet.md` | |

Other documents: `ARCHITECTURE.md` (how the client code is layered), `ROADMAP.md` (steps, done and planned, and the original wishes), `IDEEEN.md`, `docs/productregels.md` (decisions on product types), `docs/migraties.md` (migration commands), and the check queries `docs/aankoopprofiel-controle.sql` and `docs/producttypes-controle.sql`.

## Werkwijze

Leg bij elke wijziging kort uit wat je doet en waarom, in het Nederlands.

De opbouw van de clientcode (lagen `data.js`, `logica.js`, `app.js`) en de stappen van het refactoren staan in `ARCHITECTURE.md`; houd je daar bij elke taak aan. Kern: de UI roept nooit `db.` aan, nieuwe Supabase-calls komen in `data.js`, nieuwe logica komt in `logica.js` en niet in `app.js`, en wie een onderdeel van `app.js` aanpast verhuist eerst de logica van dat onderdeel naar `logica.js` (eigen commit). Tijdens het refactoren stop je na elk domein voor een test en een commit.

Elke databasewijziging is een nieuw migratiebestand in `supabase/migrations/`, nooit meer losse SQL in het dashboard. Hoe de database er nu uitziet lees je uit die map. De commando's staan in `docs/migraties.md`.

Werk de beschrijving bij in dezelfde commit als de wijziging: het bestand in `docs/systeem/` van dat domein, en `CLAUDE.md` alleen als iets voor elke taak geldt. Schrijf op hoe het nu werkt, niet wat er veranderd is of wat er vroeger was; dat staat in Git en in `ROADMAP.md`.
