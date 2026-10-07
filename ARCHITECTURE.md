# ARCHITECTURE.md

Dit document zegt hoe de code **hoort** te zijn opgebouwd. Hoe het systeem nu werkt (views, tabellen, RPC's, flows) staat in `CLAUDE.md`; dat wordt hier niet herhaald.

## Huidig

Alle Supabase-calls staan in `data.js`; `app.js` (ruim 2500 regels) bevat geen `db.` meer. State, logica en rendering lopen in `app.js` nog door elkaar. `logica.js` bestaat sinds de favorieten en bevat alleen die; de rest van de logica staat nog in `app.js`. Rekenwerk en beveiliging zitten in de database (RPC's, RLS), en dat blijft zo.

## Gewenst: drie lagen

Klassieke scripts, geen modules en geen build. Laadvolgorde in `index.html`: supabase-js, `config.js`, `data.js`, `logica.js`, `app.js`. Elke laag hangt zijn functies aan een eigen globaal object (`Data`, `Logica`).

| Laag | Bestand | Doet | Mag niet |
|---|---|---|---|
| Datatoegang | `data.js` | Alle Supabase-calls: tabellen, RPC's, auth, edge functions, realtime-kanalen. Geeft gewone data of een fout terug. | DOM aanraken, state bijhouden, beslissen wat er getoond wordt. |
| Logica | `logica.js` | State (`items`, `leden`, `bonStapel`, ...), optimistische updates, controles (`bonTwijfels()`), regels voor Voor jou. Roept alleen `Data` aan. | DOM aanraken, `db.` aanroepen. |
| UI | `app.js` | Views, `render…()`, events, swipen, navigatie. Roept `Logica` aan, en `Data` alleen voor pure leesacties zonder state. | `db.` aanroepen. |

## Regels

1. Buiten `data.js` komt geen `db.` voor. Controle: `grep -n "db\." app.js logica.js` geeft niets.
2. Een nieuwe call komt altijd in `data.js`, ook voor een nieuwe RPC of tabel.
3. Rekenwerk en matching horen in Postgres (RPC), niet in JS. `logica.js` is dunne glue eromheen.
4. Een nieuw statisch bestand gaat in `ASSETS` in `sw.js`. `CACHE` wordt bij elk gerefactord domein gebumpt (zie Werkwijze).
5. Wijzig bij een verhuizing het gedrag niet. Verhuizen en veranderen gebeuren nooit in dezelfde commit.
6. Werk `CLAUDE.md` bij zodra een beschrijving daar niet meer klopt (bijvoorbeeld de laadvolgorde).
7. Nieuwe logica komt in `logica.js`, nooit in `app.js`. Dat geldt ook voor de glue rond een nieuwe RPC.
8. Pas je een onderdeel van `app.js` aan, verhuis dan eerst de logica van dat onderdeel naar `logica.js` (state, optimistische updates, controles; alles wat de DOM niet aanraakt). Volgens regel 5 is dat een eigen commit, vóór de wijziging zelf. Een onderdeel is wat bij één scherm of flow hoort, bijvoorbeeld de bonstapel of Voor jou; de rest van `app.js` blijft liggen.

## Werkwijze bij het refactoren

Er zijn geen tests, dus de stappen zijn klein.

1. Verhuis de Supabase-calls per domein naar `data.js`, in deze volgorde: lijsten en leden; items en aankopen; bonnen; producten, profiel en aanbiedingen; auth en edge functions. (Gedaan.)
2. Na elk domein: `CACHE` in `sw.js` bumpen (bij elk domein, niet alleen het eerste, zodat telefoons de gewijzigde scripts niet uit de oude cache laden), de app handmatig testen (realtime en optimistische updates met twee browsers), één commit, **stoppen**. Het volgende domein begint pas na een expliciete "ga door" van de gebruiker.
3. De logica wordt niet in één keer uit `app.js` gehaald: zonder tests is dat veel risico voor weinig winst. Ze verhuist per onderdeel, op het moment dat dat onderdeel toch wordt aangepast (regel 7 en 8). `logica.js` is aangemaakt bij de favorieten (roadmap-stap 4), het eerste nieuwe onderdeel.
4. "Favorieten" is gedefinieerd, op de roadmap gezet en gebouwd (roadmap-stap 4). (Gedaan.)
5. Daarna volgt de kortingsmatching (roadmap-stap 5): het zoeken als RPC in Postgres, de call in `data.js`, en de glue vanaf het begin in `logica.js`, niet in `app.js`. De bestaande aanbiedingen-logica (`loadDeals()`, `deals`, `dealWinkels()`) verhuist dan eerst mee.
