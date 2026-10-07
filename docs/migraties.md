# Databasemigraties

De map `supabase/migrations/` is de bron van waarheid voor de database. Elke wijziging (tabel, kolom, functie, trigger, policy, index) is een nieuw bestand in die map. Draai geen SQL meer los in het dashboard die iets aan de structuur verandert: dan klopt Git niet meer met de database.

## Een wijziging maken en doorvoeren

Eerst het databasewachtwoord uit `.env` laden (één keer per terminalvenster):

```sh
set -a; source .env; set +a
```

Daarna:

```sh
supabase migration new korte_naam    # maakt supabase/migrations/<tijdstempel>_korte_naam.sql
# zet de SQL in dat bestand
supabase db push --dry-run           # laat zien welke migraties gaan draaien, voert niets uit
supabase db push                     # voert ze uit op de echte database
```

Commit het bestand daarna, zodat Git en de database gelijk blijven.

## Controleren

```sh
supabase migration list
```

Elke regel hoort onder Local én Remote te staan. Staat een migratie alleen onder Local, dan is hij nog niet doorgevoerd.

## Goed om te weten

- Een migratie die is doorgevoerd pas je niet meer aan. Iets herstellen doe je met een nieuwe migratie.
- Er is geen lokale testdatabase (dat zou Docker vragen). `db push` gaat dus direct naar de echte database; lees de SQL na en gebruik `--dry-run`.
- De eerste migratie, de baseline, is de stand van de database op het moment dat de migraties zijn ingevoerd. Hij is in Supabase gemarkeerd als uitgevoerd en draait daar niet opnieuw.
- Migraties bevatten alleen structuur, geen gegevens.
- De Edge Functions in `supabase/functions/` vallen hier buiten; die deploy je apart.
- Eenmalig per computer: `brew install supabase/tap/supabase`, `supabase login`, `.env` aanmaken uit `.env.example` en `supabase link --project-ref lswyhupnhkxrfjgalluk`.
