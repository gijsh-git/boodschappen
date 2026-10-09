# Opzet en deploy

> Deel van de systeembeschrijving; de index staat in `CLAUDE.md`. Een verwijzing als (see "Offers") gaat naar een kopje in dit bestand of in een ander bestand in `docs/systeem/`; de index zegt welk. Werk dit bestand bij in dezelfde commit als de wijziging die het gedrag verandert.

There is nothing to build. Serve the directory over HTTP (the service worker and Supabase auth redirect do not work from `file://`):

```sh
python3 -m http.server 8000
```

Before the app does anything useful:

1. The database is defined by the migrations in `supabase/migrations/`. For a fresh project: `supabase link --project-ref <ref>` and `supabase db push`. The first migration is a baseline dumped from the live database.
2. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `config.js`. While the URL still contains the `JOUW-PROJECT` placeholder, `init()` in `app.js` stops at the login view with a "fill in config.js" message.
3. The origin you serve from must be an allowed redirect URL in Supabase Auth, since invite and password-reset mails link back to `location.origin + location.pathname`.
4. For "Foto toevoegen": deploy `supabase/functions/foto-naar-items/index.ts` as Edge Function `foto-naar-items` with "Verify JWT" off (dashboard editor, or `supabase functions deploy foto-naar-items --no-verify-jwt`) and set the secret `ANTHROPIC_API_KEY`. "Bon scannen" needs `supabase/functions/bon-uploaden/index.ts` deployed the same way as Edge Function `bon-uploaden`; it uses the same secret. The weekly offers need `supabase/functions/aanbiedingen-opslaan/index.ts` as Edge Function `aanbiedingen-opslaan`, also with "Verify JWT" off, and the secret `AANBIEDINGEN_SLEUTEL` (a long random value, e.g. `openssl rand -hex 32`; the same value is a repository secret in GitHub, see "Offers" in `aanbiedingen.md`); `supabase/functions/artikelen-classificeren/index.ts` and `supabase/functions/term-classificeren/index.ts` are deployed the same way under those names and use both that secret and `ANTHROPIC_API_KEY`. For the second one the database needs the address and the key in Vault, once, in the SQL Editor: `select vault.create_secret('https://<ref>.supabase.co/functions/v1/term-classificeren', 'term_classificeren_url');` and `select vault.create_secret('<value of AANBIEDINGEN_SLEUTEL>', 'aanbiedingen_sleutel');`. The functions are not part of the GitHub Pages deploy: after changing one, deploy it again.

The app is hosted on GitHub Pages from `main` (https://gijsh-git.github.io/boodschappen/), so pushing to `main` deploys.
