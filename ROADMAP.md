# Bonusbuddy – Roadmap

Bouwplan voor de volgende fases. Werk van boven naar beneden; vink af wat klaar is.
Opdrachten tussen ``` zijn bedoeld om in Claude Code te plakken.

## Werkwijze per stap

1. `/clear`
2. Opdracht plakken (met `/plan` ervoor), plan lezen, vragen stellen
3. Claude laten bouwen (modus Manual)
4. Databasewijzigingen staan als nieuw migratiebestand in `supabase/migrations/`, nooit als losse SQL in het dashboard. SQL nalezen, dan `supabase db push --dry-run` en `supabase db push` (commando's in `docs/migraties.md`)
5. Een gewijzigde Edge Function opnieuw deployen
6. Testen op telefoon en laptop, liefst met z'n tweeën
7. Commit en push (push naar `main` zet de app live)

In de opdrachten van de afgeronde stappen staat nog "geef de SQL apart"; dat was de oude werkwijze.

Een stap is pas klaar als alle punten onder "Klaar als" kloppen.

---

## Oorspronkelijke wensen

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

---

## Fase 0 – Voorbereiding

- [ ] Back-up maken van de Supabase-database (vraag Claude hoe, of via Supabase > Database > Backups)
- [ ] AVG-inzageverzoek naar AH sturen voor alle aankoopgegevens (tot 27 maanden), in een machineleesbaar formaat

---

## Uitgangspunt aankoopprofiel (eenvoudig)

- Alles wat binnen een lijst gekocht of van een bon ingelezen wordt, hoort bij alle deelnemers van die lijst.
- Jouw aankoopprofiel = alle aankopen uit de lijsten waarvan je deelnemer bent en die meetellen voor het profiel.
- Persoonlijke dingen? Zet ze op een eigen lijst met alleen jezelf als deelnemer.
- Geen "voor wie" per aankoop.

---

## Fase 1 – Lijsten archiveren in plaats van verwijderen

### [x] 1 – Archiveren

```
/plan
Wat: een lijst archiveren in plaats van definitief verwijderen.
Waarom: nu wist het verwijderen van een lijst ook alle aankopen en bonnen (on delete cascade). Die zijn de basis van het aankoopprofiel en mogen niet verloren gaan.
Hoe het moet werken:
- De maker kan een lijst archiveren. Een gearchiveerde lijst verdwijnt uit het lijstoverzicht en je kunt er niets meer aan toevoegen.
- Aankopen en bonnen van een gearchiveerde lijst blijven bestaan en blijven meetellen voor het profiel van de deelnemers.
- Onderaan het lijstoverzicht een inklapbaar blok "Gearchiveerd" met de mogelijkheid om een lijst terug te zetten.
- Vervangt de huidige knop "Lijst verwijderen".
Klaar als: ik een testlijst met aankopen archiveer, die uit het overzicht verdwijnt, de aankopen nog in Supabase staan, en ik de lijst kan terugzetten.
Grenzen: geef de SQL apart. Verander swipen, aankopen en bonnen verder niet.
```

---

## Fase 2 – Historische gegevens

### [x] 2a – AH-bonnen ophalen via ah-mcp

```
/plan
Wat: mijn historische AH-kassabonnen ophalen en importeren als aankopen in onze gedeelde lijst.
Hoe het moet werken:
1. Controleer eerst de code van https://github.com/mrserzhan/ah-mcp op veiligheid: waar gaan mijn inloggegevens en aankoopdata naartoe, wordt er iets naar andere servers dan AH gestuurd? Rapporteer en wacht op mijn akkoord.
2. Installeer het daarna als MCP-server voor dit project en help me inloggen.
3. Haal alle beschikbare bonnen op met details en sla ze op in data/ah-bonnen.json. Zet data/ in .gitignore.
4. Maak een importscript dat de bonnen als bonnen en aankopen in een lijst die ik kies opslaat (bondatum, supermarkt AH, productnaam, aantal, prijs, korting), zonder dubbelingen bij opnieuw draaien en zonder bonnen die ik al gescand heb dubbel te tellen. Gebruik dezelfde opslag als het scannen van bonnen.
Klaar als: ik in de app bij "Gescande bonnen" mijn historische AH-bonnen zie, met het aantal en de periode.
Grenzen: alleen lezen uit mijn AH-account, niets wijzigen.
```

---

## Fase 3 – Inzicht

### [x] 3a – Producten

```
/plan
Wat: een gedeelde producttabel, zodat varianten van hetzelfde product ("halfvolle melk", "AH halfvolle melk 1L", "halfvolle mlek") als één product tellen.
Waarom: het aankoopprofiel (top 10, om de hoeveel dagen) en later het kortingsadvies kloppen alleen als een product één ding is. Nu is elke schrijfwijze een apart product.
Hoe het moet werken:
- Een tabel met producten (vaste id, naam) en een tabel met aliassen: elke genormaliseerde naam hoort bij precies één product.
- Koppelen gaat via de naam, niet via een keuze bij het invoeren: een item toevoegen blijft net zo snel als nu. Een naam die nog niet bekend is wordt vanzelf een eigen product.
- Regel voor samenvoegen: een product is het niveau waarop een koper wisselt bij een aanbieding. Merken van hetzelfde soort product worden samengevoegd; varianten waar je niet tussen wisselt (halfvolle/volle melk, cola/cola zero) blijven apart. De oorspronkelijke namen blijven bewaard voor merkinformatie later.
- Lijstitems, aankopen en bonregels komen zo bij hetzelfde product uit. De oorspronkelijke namen blijven staan.
- Alleen een beheerder (ik) kan samenvoegen, losmaken en hernoemen. Leg de beheerdersrol vast in de database en controleer die in de schrijffuncties, niet alleen in de interface.
- Sla elke samenvoeging op met wie, wanneer en welke aliassen er verhuisd zijn, zodat losmaken precies terugzet wat er was.
- Eerste vulling: elke naam die nu in aankopen en items voorkomt wordt een product. Doe daarna zelf een voorstel welke namen volgens de regel hierboven samen één product zijn en laat mij dat per groep goedkeuren voordat je iets samenvoegt.
- Een scherm "Producten", bereikbaar vanaf Mijn profiel en alleen zichtbaar voor de beheerder: zoeken, twee producten samenvoegen, een naam weer losmaken, een product hernoemen.
- Gewone gebruikers kunnen geen producten van anderen zien of doorzoeken. Een nieuwe naam is alleen zichtbaar voor de beheerder en voor leden van de lijst waarop de naam voorkomt.
Klaar als: ik als beheerder "halfvolle melk" en "AH halfvolle melk 1L" samenvoeg, mijn vriendin dat in haar aankoopprofiel terugziet, zij het scherm Producten niet ziet, een nieuw item "AH halfvolle melk 1L" bij hetzelfde product uitkomt, "melk" een apart product blijft, en ik de samenvoeging weer kan losmaken. Laat een telling zien: aantal namen voor en aantal producten na het samenvoegen.
Grenzen: geef de SQL apart. Verander de namen in aankopen en items niet. Samenvoegen per huishouden komt niet in deze fase. De koppeling van aanbiedingen aan producten komt in fase 4, de koppeling aan supermarktartikelen later. Het matchen van bonregels en aanbiedingen (pg_trgm) blijft zoals het is.
```

### [x] 3b – Aankoopprofiel op Mijn profiel

```
/plan
Wat: het aankoopprofiel van ons huishouden tonen op de pagina Mijn profiel.
Waarom: ik wil zien wat de app over ons koopgedrag weet en controleren of dat klopt; later de basis voor kortingsadvies.
Hoe het moet werken:
- Sectie "Aankoopprofiel" op Mijn profiel.
- Periode: laatste 4 weken, 3 maanden, 12 maanden, alles. Rollend vanaf vandaag (4 weken = vandaag min 28 dagen), niet per kalendermaand.
- Filter: alle lijsten, of één specifieke lijst.
- Een product is een product uit 3a: de naam van een aankoop wordt via product_aliases naar het product herleid. "heinz ketchup" en "ketchup" tellen dus als één.
- Een vlag "telt niet mee in profiel" per product, voor dingen als draagtas en plastic zak (zie docs/productregels.md). Alleen de beheerder zet hem, op het scherm Producten, via een databasefunctie met rolcontrole. Zulke producten tellen niet mee in het aantal aankopen, het aantal producten en de top 10, wel in uitgegeven en bespaard.
- Kerncijfers over de gekozen periode: aantal aankopen (rijen in purchases), aantal verschillende producten, uitgegeven en bespaard.
- Geld: de prijs van een aankoop is het bedrag van de hele regel vóór korting. Uitgegeven = prijs min korting, bespaard = korting, alleen over aankopen met een prijs. Toon erbij bij hoeveel procent van de aankopen de prijs bekend is.
- Top 10 producten over de gekozen periode, gesorteerd op aantal aankoopdagen (meerdere keren op één dag telt als één keer; stuks tellen kan niet, want de hoeveelheid is vrije tekst).
- Per product in de top 10: om de hoeveel dagen (de mediaan van de tussenpozen tussen aankoopdagen) en de datum van de laatste aankoop. Het interval wordt altijd over alle data berekend, los van de gekozen periode, en pas getoond vanaf 3 aankoopdagen; daaronder "te weinig data".
- Verdeling per supermarkt over de gekozen periode als staafjes op aantal aankopen, met het bedrag erachter. De supermarkt komt van de bon; aankopen zonder bon vallen onder "onbekend".
- Uitgaven per maand als staafjes: altijd de laatste 12 maanden, los van de gekozen periode. De lopende maand is gemarkeerd als onvolledig en een maand zonder prijsgegevens toont "geen prijsdata" in plaats van € 0.
- Alle dagen en maanden in Nederlandse tijd (Europe/Amsterdam).
- Kort uitlegtekstje per onderdeel. Daarin staat in elk geval: dit is het profiel van het huishouden (alle deelnemers, ook aankopen van vóór je toetreding), het interval kijkt naar alle data, en de bedragen zijn een ondergrens (alleen bonregels met een prijs, zonder statiegeld).
Klaar als: de cijfers kloppen met Supabase, filters en periodes werken, brood als één product in de top 10 staat en draagtas er met de vlag uit verdwijnt. Geef per kerncijfer een losse controlequery die ik in de SQL Editor naast de uitkomst kan leggen.
Grenzen: alleen aankopen uit lijsten waarvan ik deelnemer ben en die meetellen voor het profiel (ook gearchiveerde). Reken in de database: één functie die alles in één keer teruggeeft, de frontend toont alleen. Geen grafiekbibliotheek. Goed leesbaar op een telefoon. Geen seizoenspatronen, geen "samen gekocht" en geen voorspellingen.
```

### [x] 3c – Een bon haalt producten van de lijst

Regel: bij het opslaan van een bon wordt een item van de lijst gehaald en als aankoop vastgelegd als het hetzelfde product is als een bonregel én de bondatum op of na de dag van toevoegen ligt. Bij alleen een gelijkende naam gebeurt dit pas nadat je het aanvinkt in "Bon controleren".

- Hetzelfde product = dezelfde naam of hetzelfde product in de producttabel (3a). Een gelijkende naam (pg_trgm) is alleen een voorstel, want "melk" en "volle melk" zijn verschillende producten.
- De datum wordt per dag vergeleken (Europe/Amsterdam). Een item dat na de bondatum is toegevoegd blijft staan: dat is opnieuw nodig. Oude bonnen in bulk halen daardoor niets van de lijst.
- Een bonregel die al bij een aankoop van die dag hoort (item was al geswipet) haalt niets van de lijst.
- Het item wordt één aankoop met de bongegevens erbij, niet een aankoop naast een bonregel. De hoeveelheid op de lijst speelt geen rol.
- "Alles zonder bijzonderheden opslaan" haalt alleen hetzelfde product weg; een bon met een gelijkende naam blijft staan voor controle.
- Een bon verwijderen zet het item niet terug op de lijst; de aankoop blijft, zonder prijs.

Klaar als: "melk" op de lijst staat, ik een bon van vandaag met melk opsla en de melk bij mij en mijn vriendin van de lijst verdwijnt en één keer bij de aankopen staat met prijs; een item dat ik na de bondatum heb toegevoegd blijft staan; en bij "volle melk" op de bon en "melk" op de lijst gebeurt er niets tot ik het aanvink.

---

## Vanaf hier: aanbiedingen eerst

Vastgesteld op 7 oktober 2026. Vervangt de oude fases 4 "Slimmer matchen", 5 "Echte aanbiedingen" en 6 "Advies". Wat hierboven staat is af en blijft zo.

### Uitgangspunten

- Twee fases: een testfase (Gijs, Els, eventueel een kleine groep) en een publieke fase.
- De bron van aankopen en de bron van aanbiedingen zijn losse, verwisselbare onderdelen. In de testfase is dat de AH-API, in de publieke fase iets duurzamers.
- De matching (aanbieding → product → profiel) is in beide fases hetzelfde. Daar zit de waarde.
- Detail gaat nooit verloren: `name`, `receipt_name` en (straks) het artikel-ID blijven bij elke aankoop staan. Het product is een label erboven.
- Eerst AH, pas daarna Jumbo of folders.

---

## Testfase

### [x] Stap 1 – Verkenning AH-aanbiedingen

Script dat met een anoniem AH-token één week bonusgroepen met hun artikelen ophaalt en als JSON opslaat. Draait lokaal, niet in de app.

- [x] Bonusgroepen + artikelen van één week opgeslagen (`scripts/ah-bonus` → `data/ah-bonus.json`)
- [x] Naast de huidige productlijst gelegd: hoeveel aanbiedingen raken een product dat we kopen, via ID en via naam (`scripts/ah-bonus-vergelijken.py`)
- [x] Besluit: de opzet hieronder blijft staan, met de aanscherping voor stap 3 en 5 uit de uitkomst

Klaar als: een kort overzicht met aantallen en voorbeelden van wat goed en fout gaat.

Uitkomst (7 oktober 2026), volledig in `docs/verkenning-ah-bonus.md`:

- Het `product_id` op de bon is het `hq_id` dat bij elk bonusartikel naast het webshop-ID staat. De artikeltabel uit stap 3 kan dus elke week uit de bonus gevuld worden en dient ook als vertaling van bon-ID naar artikel.
- Via ID raken 12 van de 143 aanbiedingen een vast product, zonder fouten. Maar het mist het andere merk of formaat van hetzelfde product (kwark, cola), en dat zijn juist de aanbiedingen waar het om gaat.
- Via de naam in de titel raken er 56, waarvan het grootste deel ruis is (avocado in douchegel, paprika in chips). De categorie van het artikel is nodig om dat te scheiden.
- De opzet blijft staan. Aanscherping voor stap 3 en 5: bewaar per artikel titel, merk, inhoud en categorie, en geef de categorie mee bij het voorstel artikel → product.

### [x] Stap 2 – Artikel-ID bij aankopen

Huidige situatie: een bonregel is geen eigen tabel maar een rij in `purchases` met `receipt_id`, `receipt_name`, `price` en `discount`. De supermarkt staat al op de bon (`receipts.store`). `data/ah-bonnen.json` heeft per regel al een `product_id` van AH, maar `scripts/ah-importeren.py` gooit dat weg.

Besluit: het `product_id` van de bon wordt als `article_id` op `purchases` opgeslagen. De naam is bewust algemeen: het is het artikelnummer van de bon, in het systeem van de supermarkt op die bon. Voor AH is dat het `hq_id`; `hq_id` is een AH-naam en zou bij Jumbo misleidend zijn. De vertaling naar webshop-ID en de artikelgegevens komen uit de artikeltabel van stap 3.

- [x] Migratie: kolom `article_id` op `purchases`, met een opmerking op de kolom dat dit het artikelnummer van de bon is, in het systeem van de supermarkt op die bon (voor AH het `hq_id`, niet het webshop-ID). Geen kolom voor de supermarkt: die volgt uit de bon via `receipt_id`, en aankopen zonder bon hebben ook geen artikel-ID
- [x] `save_receipt` neemt het artikel-ID per regel aan en slaat het op, ook bij een regel die aan een bestaande aankoop of een item van de lijst wordt gekoppeld. `delete_receipt` maakt het weer leeg bij gekoppelde aankopen, net als de andere bonkolommen
- [x] `scripts/ah-importeren.py` geeft het `product_id` mee en voegt regels alleen nog samen als naam én ID gelijk zijn. Dezelfde naam met verschillende ID's (bijvoorbeeld twee formaten met dezelfde bontekst) blijven aparte regels
- [x] `save_receipt` daarop aanpassen: nu wordt een regel met exact dezelfde naam als een aankoop van die dag overgeslagen, waardoor de tweede van zulke regels zou wegvallen. "Een product telt één keer per dag" wordt: één keer per naam én artikel-ID. Ontbreekt het ID aan één van beide kanten (gescande bon, geswipet item), dan telt alleen de naam, zoals nu
- [x] Bestaande AH-aankopen aanvullen vanuit `data/ah-bonnen.json`, op bon (winkel, datum, totaal) en `receipt_name` (`scripts/ah-artikel-aanvullen.py`, schrijft via `fill_article_ids`). Aankopen waarin de oude import twee artikelen had samengevoegd krijgen geen ID. Eerst een proefronde zonder schrijven, zoals de import zonder `--echt`, met een telling: hoeveel aankopen krijgen een ID, hoeveel niet, en waarom niet
- [x] Gescande bonnen ("Bon scannen") krijgen geen artikel-ID: op een foto staat het niet. Die aankopen matchen in stap 5 via de naam

Klaar als: een nieuw geïmporteerde AH-bon bij elke aankoop een artikel-ID heeft, twee regels met dezelfde naam maar een ander ID als twee aankopen zijn opgeslagen, en de telling van het aanvullen klopt met de database.

Volgorde: na stap 1. Het kan er los van, maar stap 1 laat zien hoe de AH-data eruitziet en dat helpt bij het beoordelen van deze stap.

### [x] Stap 3 – Aanbiedingen ophalen (AH)

- [x] Tabellen voor aanbiedingen en de artikelen per aanbieding, met geldigheid en kortingstype
- [x] Artikelen en aanbiedingen krijgen een kolom `supermarket`. Een artikel is uniek op `supermarket` + `article_id`, niet op het ID alleen, zodat later andere supermarkten met eigen nummers erbij kunnen
- [x] Per artikel bewaren: `article_id` (dezelfde naam en betekenis als op `purchases`: het artikelnummer van de bon in het systeem van die supermarkt, voor AH het `hq_id`), `webshop_id`, titel, merk, inhoud, categorie
- [x] Per aanbieding bewaren: titel, kortingstekst, de labels met code en getallen, geldig van/tot, en welke artikelen erbij horen
- [x] De artikeltabel is ook de vertaling van bon-ID naar artikel; er komt geen aparte vertaaltabel
- [x] Wekelijks automatisch ophalen (anoniem token, geen account)
- [x] Oude aanbiedingen opruimen

Klaar als: de bonus van deze week elke week vanzelf in de database staat.

Gebouwd en doorgevoerd op 7 oktober 2026; de taak in GitHub Actions heeft die dag met de hand gedraaid en de week opgeslagen:

- Tabellen `articles`, `offers` en `offer_articles`, gevuld door de functie `save_offers` (migratie `aanbiedingen`). De oude tabel `deals` met testdata is in stap 5 vervallen.
- Ophalen draait in GitHub Actions (`.github/workflows/ah-bonus.yml`), maandag- en donderdagochtend: het bestaande `scripts/ah-bonus` en daarna `scripts/ah-bonus-opslaan.py`.
- De service role key staat niet in GitHub: de repo is openbaar en die sleutel geeft toegang tot alles. Het script stuurt de week naar de Edge Function `aanbiedingen-opslaan`, die een eigen sleutel (`AANBIEDINGEN_SLEUTEL`) controleert en alleen `save_offers` aanroept. Wie die sleutel heeft kan alleen aanbiedingen opslaan.
- Een aanbieding blijft tot 28 dagen na de laatste geldige dag staan; artikelen blijven altijd.
- Een artikel zonder `hq_id` (1 van de 2423) wordt overgeslagen.
- Bij een losse aanbieding geeft AH alleen de subcategorie ("Courgette"), bij een groep "hoofdcategorie/subcategorie". Voor het voorstel in stap 5 is dat bij losse artikelen dus mager.

Opnieuw opzetten (bijvoorbeeld bij een nieuw Supabase-project):

1. `supabase db push --dry-run` en `supabase db push`
2. Een sleutel maken: `openssl rand -hex 32`
3. In Supabase zetten: `supabase secrets set AANBIEDINGEN_SLEUTEL=<sleutel>`
4. De functie deployen: `supabase functions deploy aanbiedingen-opslaan --no-verify-jwt`
5. Dezelfde sleutel in `.env` zetten (`AANBIEDINGEN_SLEUTEL=`) en lokaal testen: `set -a; source .env; set +a` en `python3 scripts/ah-bonus-opslaan.py --echt`. Een tweede keer draaien meldt 0 nieuwe artikelen.
6. Dezelfde sleutel als secret `AANBIEDINGEN_SLEUTEL` in GitHub zetten (Settings > Secrets and variables > Actions)
7. Committen en pushen, en de taak één keer met de hand starten (Actions > "AH-bonus ophalen" > Run workflow)

### [x] Stap 4 – Favorieten

Definitie vastgesteld op 7 oktober 2026. Vervangt de eerdere opzet waarin een favoriet een product uit de catalogus was.

Een favoriet is een product waarvan de gebruiker wil weten dat het in de aanbieding is.

- Favorieten zijn per gebruiker, niet per lijst. Anderen zien ze niet, ook niet in hun "Voor jou".
- Een favoriet is een zoekterm (bijvoorbeeld "pindakaas"), een merk (bijvoorbeeld Calvé) of allebei. Minstens één van de twee is ingevuld; alleen een merk mag ("alles van Verstegen").
- Favorieten maak en beheer je op Mijn profiel, in een sectie "Mijn favorieten": toevoegen, aanpassen en verwijderen. Dat is de enige plek.
- Term en merk zijn vrij te typen, met suggesties uit de termen en merken die in de aanbiedingen voorkomen.
- Een favoriet heeft optioneel een categorie. Die wordt vanzelf gevuld als je een term uit de suggesties kiest; bij een zelf getypte term blijft hij leeg. De gebruiker vult hem niet met de hand in.
- De term matcht op hele woorden in de titel van een artikel: "pindakaas" matcht niet "pindakaashagelslag", "melk" niet "kokosmelk". Een term van meerdere woorden matcht als alle woorden voorkomen.
- Heeft de favoriet een categorie, dan tellen alleen artikelen in die categorie ("honing" matcht dan geen thee).
- Het merk matcht exact. "AH" matcht niet "AH Excellent" of "AH Terra"; die staan als losse merken in de suggesties.
- Zonder merk matcht elk merk. Met alleen een merk matcht elk artikel van dat merk.
- Matching negeert hoofdletters en accenten.
- Favorieten maken geen producten aan in de gedeelde catalogus.
- Matches verschijnen in "Voor jou". "Voor jou" = het aankoopprofiel van het huishouden plus je eigen favorieten. Hoe die twee tegen elkaar wegen wordt pas bepaald als er een rangorde in "Voor jou" is.
- Op de lijst zetten vanuit een favoriet zet de term op de lijst, met het merk ervoor als dat is ingesteld ("Calvé pindakaas"); bij alleen een merk de titel van het artikel.
- Matching gebeurt in de RPC van stap 5. Deze stap is alleen vastleggen en beheren.
- Geen ster bij een item of aankoop, voor nu.
- Later: wegklikken bij een match (stap 7), en een instelbare melding als een favoriet in de aanbieding is (vraagt push-notificaties).

Datamodel:

- Een favoriet loopt niet via `products` en `product_aliases`, maar rechtstreeks naar `articles` (`title`, `brand`, `category`) van de artikelen in een geldige aanbieding. Favorieten en aankoopprofiel zijn twee aparte routes naar dezelfde aanbiedingen.
- Nieuwe tabel `favorites` (`user_id`, `term`, `brand`, `category`, plus genormaliseerde kolommen voor term en merk). Term en merk mogen elk leeg zijn, niet allebei. Uniek per gebruiker op genormaliseerde term en merk. RLS op de eigen rijen, zoals `profiles`; schrijven kan dan rechtstreeks, zonder RPC.
- Accenten negeren gebruikt de extensie `unaccent`, aangezet in een losse migratie (`20261007140000_unaccent.sql`). `normalized_name` elders is alleen `lower(trim())`, dus favorieten krijgen een eigen normalisatie.
- Merken: `articles.brand` is bij alle 2423 artikelen van de testweek gevuld (133 merken). Suggesties komen daar rechtstreeks uit, huismerken inbegrepen ("AH", "AH Excellent", "AH Terra").
- Termen: er bestaat geen kolom met termen. Suggesties worden afgeleid uit `articles`: de subcategorie (het deel na de "/" in `articles.category`) en de woorden in `title`, elk met de categorie erbij die bij de favoriet wordt bewaard. Bron is alles wat ooit in de bonus zat, niet alleen de lopende week.
- De categorie bij een favoriet is de hoofdcategorie ("Koffie, thee"), het deel vóór de "/" in `articles.category`. De subcategorie is te smal: een favoriet "kaas" met "Geraspte kaas" zou plakken kaas missen.
- Niet elk artikel heeft een hoofdcategorie. Van de 2423 artikelen in de testweek hebben er 149 alleen een subcategorie ("Courgette", de losse aanbiedingen, vooral groente en fruit) en 125 geen categorie; via andere artikelen is de hoofdcategorie daar niet op te zoeken. Een suggestie uit zo'n artikel komt zonder categorie. Voor stap 5: de categorie van een favoriet kan zulke artikelen niet uitsluiten, dus daar beslist alleen het hele woord.
- Samenvoegen van producten raakt favorieten niet.
- Een favoriet op de lijst zetten maakt via `ensure_product()` wel een product aan, net als elk ander item. "Geen producten in de catalogus" geldt voor het vastleggen.

```
/plan
Wat: gebruikers kunnen favorieten vastleggen: een zoekterm, een merk of allebei, waarvan ze willen weten of het in de aanbieding is.
Waarom: een favoriet is een expliciet signaal en werkt vanaf dag één. Een nieuwe gebruiker heeft nog geen aankoopprofiel, maar krijgt via favorieten meteen relevante aanbiedingen.
Hoe het moet werken:
- Een favoriet hoort bij een gebruiker, niet bij een lijst, en bestaat uit een term ("pindakaas"), een merk ("Calvé") of allebei. Minstens één van de twee.
- Term en merk zijn vrije tekst. Tijdens het typen komen er suggesties: merken uit articles.brand, termen afgeleid uit articles (subcategorie en woorden uit de titel).
- Kies ik een term uit de suggesties, dan wordt de categorie van die suggestie bij de favoriet bewaard. Bij een zelf getypte term blijft de categorie leeg. Er is geen invoerveld voor de categorie; wel zie ik hem bij de favoriet staan.
- Hoofdletters en accenten maken niet uit: "calve" en "Calvé" zijn hetzelfde merk, en dezelfde term met hetzelfde merk kan maar één keer.
- Favorieten maken geen producten of aliassen aan.
- Op Mijn profiel een sectie "Mijn favorieten": toevoegen, term en merk aanpassen, verwijderen.
Klaar als:
- ik "pindakaas", "pindakaas" + "Calvé" en alleen "Verstegen" kan toevoegen, aanpassen en verwijderen;
- een favoriet zonder term en zonder merk wordt geweigerd, ook door de database;
- "Pindakaas" + "calve" daarna als dubbel wordt geweigerd;
- een term uit de suggesties een categorie krijgt en een zelf getypte niet;
- "AH" en "AH Excellent" als losse merken in de suggesties staan;
- Els mijn favorieten niet ziet en ik de hare niet;
- er na het toevoegen geen nieuw product in de catalogus staat.
Grenzen: nog geen koppeling met aanbiedingen en niets in "Voor jou" (stap 5), geen ster bij items of aankopen, geen AI, geen meldingen of pushberichten. De extensie unaccent staat al aan (eigen migratie). Supabase-calls in data.js, logica in logica.js (ARCHITECTURE.md). Elke databasewijziging is een nieuw migratiebestand in supabase/migrations/. Verander swipen, bonscannen en het aankoopprofiel niet.
```

Gebouwd op 7 oktober 2026:

- Migraties `unaccent` en `favorieten`: de tabel `favorites` met RLS op de eigen rijen, de functie `normalize_search` (kleine letters, zonder accenten) en de suggesties `suggest_favorite_terms` en `suggest_favorite_brands`. De app schrijft rechtstreeks in de tabel; er is geen RPC voor.
- De sectie "Mijn favorieten" op Mijn profiel. De regels (minstens één van de twee, dubbel, wanneer de categorie blijft staan) staan in het nieuwe `logica.js`.
- Suggesties voor de term komen uit de subcategorie (gesplitst op komma's) en uit de woorden in de titel, zonder de woorden van het merk. Ze laten per hoofdcategorie een eigen regel zien ("honing · Koffie, thee" naast "honing · Koek, snoep, chocolade").
- Nog niet: een favoriet doet nog niets. De aanbieding erbij tonen is stap 5.

### [x] Stap 5 – Matchen en kortingskansen

- [x] Koppeling artikel → product is gedeeld en gebeurt één keer per artikel, in drie niveaus:
  1. Zeker: het artikel-ID staat op een eigen bon. Het product is dan bekend; automatisch koppelen. Dit is geen samenvoegen van producten en valt dus niet onder de goedkeuring uit `docs/productregels.md`.
  2. Kandidaat: categorie en naam wijzen op een product dat iemand koopt. AI-voorstel volgens `docs/productregels.md`, met de categorie van het artikel erbij; de beheerder keurt goed.
  3. De rest: geen product. Komt het artikel later terug in de bonus, dan is het al bekend.
- [x] Voor het aankoopprofiel is naammatching nooit het eindoordeel, alleen een manier om kandidaten te vinden (zie `docs/verkenning-ah-bonus.md`: avocado in douchegel, honing in thee)
- [x] Een aanbieding telt voor iemand via het aankoopprofiel als een artikel erin bij een product hoort dat die persoon koopt, ongeacht merk of formaat
- [x] Een aanbieding telt voor iemand via een favoriet volgens de regels van stap 4: de term als hele woorden in de titel van een artikel erin, het merk exact, de hoofdcategorie als de favoriet die heeft (een artikel zonder hoofdcategorie wordt daar niet op uitgesloten), zonder hoofdletters en accenten (`normalize_search`). Rechtstreeks op `articles`, zonder product ertussen
- [x] "Voor jou" = het aankoopprofiel van het huishouden plus de eigen favorieten; een aanbieding die via beide binnenkomt staat er één keer. De rangorde tussen de twee wordt hier bepaald
- [x] Aanbieding → product via de artikelen in de bonusgroep
- [x] Kortingskansen tonen op basis van aankoopprofiel en favorieten
- [x] Bij een favoriet die nu in de aanbieding is: de aanbieding tonen (supermarkt, korting, geldig tot), met één tik om het op een lijst te zetten: de term, met het merk ervoor als dat is ingesteld. Een favoriet met merk ("pindakaas" + "Calvé") toont alleen de aanbieding van dat merk.

Klaar als: een aanbieding op een product dat we vaak kopen of als favoriet hebben in de app verschijnt, en een aanbieding op iets wat we nooit kopen niet.

Deel 1 gebouwd op 7 oktober 2026 (migraties `aanbiedingen_matchen` en `aanbieding_bij_item`):

- Niveau 1 (artikel-ID op een eigen bon) heeft geen tabel: `article_products()` leidt het af uit de aankopen. Na het aanvullen hebben 1241 van de 1272 aankopen een artikel-ID, goed voor 601 koppelingen artikel → product.
- De grens voor "koopt" staat in de tabel `settings`: minstens 3 aankoopdagen (`regular_min_days`), de laatste binnen 365 dagen (`regular_max_age_days`).
- `offers_for_me()` geeft de aanbiedingen voor "Voor jou": favorieten bovenaan, daarna het profiel op aantal aankoopdagen. In de testweek 2 via favorieten en 18 via het profiel, van de 143.
- Het Bonus-label op de lijst komt uit `offers_for_list()`: via het product van het item, of via de aanbieding waarmee het item vanuit "Voor jou" op de lijst is gezet (`items.offer_id`). Dat laatste geeft ook een favoriet op de lijst zijn label.
- Bijgesteld na de eerste test: "zet op lijst" bij een favoriet zet de aanbieding zelf op de lijst (de titel), niet de term. De term zegt niet wat er in de bonus is: de favoriet "banaan" raakte "AH Verse sappen en smoothies" en zette "Banaan" op de lijst. Bij een aanbieding via het profiel blijft het de productnaam.
- De groene balk in de kop van de lijst klapt uit en toont per item wat er precies in de aanbieding is (`offer_details_for_list()`, migratie `aanbiedingen_bij_lijst_tonen`).
- Nog open: niveau 2 (het voorstel voor artikelen van een ander merk of formaat, door een script buiten de app, goedkeuren in het scherm Producten). Uitgewerkt in deel 2 hieronder.
- De oude tabel `deals` en `deals_for_list` zijn vervallen (migratie `deals_vervalt`), nadat het nieuwe label getest was.

#### Deel 2 – Niveau 2: artikelen van een ander merk of formaat

Besluiten vastgesteld op 7 oktober 2026.

Aanleiding: "AH Biologisch oranje pompoen" is in de bonus en "pompoen" staat op de lijst, maar er komt geen Bonus-label. Wij kochten de gewone AH pompoen, een ander artikelnummer, en niveau 1 kent alleen artikelen die op een eigen bon staan.

- Kandidaat-producten: elk product met minstens één aankoop of een item op een lijst, van alle huishoudens. De grens voor een vast product geldt hier niet; die bepaalt alleen wat in "Voor jou" komt.
- Eén product per artikel. Staat het artikelnummer op een bon (niveau 1), dan wint de bon: voor zo'n artikel wordt niets voorgesteld en een eerdere koppeling van niveau 2 telt niet meer.
- De status wordt per artikel bewaard: voorstel, goedgekeurd of geen product. Een artikel zonder status is nog niet beoordeeld.
- Een afwijzing wordt bewaard per combinatie van artikel en product. Die combinatie wordt nooit opnieuw voorgesteld; hetzelfde artikel mag later wel bij een ander product worden voorgesteld.
- Een artikel met "geen product" wordt opnieuw beoordeeld als er producten zijn bijgekomen sinds het oordeel, en dan alleen tegen die nieuwe producten.
- Samenvoegen: `merge_products` verhuist de koppelingen, voorstellen en afwijzingen van de bron naar het doel; `undo_merge` zet terug wat van de bron kwam. Wat na het samenvoegen op het doel is goedgekeurd blijft bij het doel.
- Het script draait eerst met de hand, lokaal. Automatiseren (GitHub Actions) komt later, als de voorstellen goed blijken.
- Beoordelen in het scherm Producten: alleen voorstellen met een product, gegroepeerd per product, met "alles goedkeuren" per groep. Per voorstel staat de zekerheid van de AI (hoog, middel, laag) en de reden. Voorstellen met zekerheid laag zijn twijfelgevallen: die staan in een eigen blok en vallen buiten "alles goedkeuren".
- Is de subcategorie van het artikel exact gelijk aan de productnaam ("Pompoen" en "pompoen", via `normalize_search`), dan is de zekerheid hoog. Dat is een vaste regel in het script, geen oordeel van de AI. De subcategorie is het deel na de "/" in `articles.category`, of de hele categorie als er geen "/" in staat.
- Een artikel aan een product koppelen is geen samenvoegen van producten: er verandert niets aan `products` en `product_aliases`.

```
/plan
Wat: niveau 2 van de koppeling artikel → product. Een script buiten de app stelt per artikel uit de aanbiedingen voor bij welk bestaand product het hoort; ik keur de voorstellen goed in het scherm Producten.
Waarom: nu telt een aanbieding alleen als het artikelnummer op een eigen bon staat. Een ander merk of formaat van hetzelfde product wordt gemist (biologische pompoen bij "pompoen", Campina kwark bij "kwark"), en dat zijn juist de aanbiedingen waar het om gaat.
Hoe het moet werken:
- Opslag: per artikel (supermarkt + artikelnummer) een status: voorstel, goedgekeurd of geen product, met het product, de zekerheid (hoog, middel, laag), de reden van de AI en wanneer het beoordeeld is. Daarnaast de afwijzingen, per combinatie van artikel en product. Een artikel hoort bij hooguit één product.
- article_products() geeft naast niveau 1 ook de goedgekeurde koppelingen terug. Staat het artikelnummer op een bon, dan telt alleen de bon. Voor jou, het Bonus-label en de groene balk gebruiken die functie al en veranderen verder niet.
- Het script (Python, standaardbibliotheek, zoals scripts/ah-importeren.py) logt in als beheerder en leest en schrijft alleen via databasefuncties met rolcontrole. Zonder --echt is het een proefronde die alleen telt en voorbeelden laat zien.
- Het script beoordeelt: artikelen zonder status en zonder bon, en artikelen met "geen product" als er sindsdien producten zijn bijgekomen (alleen tegen die nieuwe producten). Kandidaten zijn alle producten met minstens één aankoop of een item op een lijst. Een afgewezen combinatie van artikel en product stelt het nooit opnieuw voor.
- De AI krijgt per artikel titel, merk, inhoud en categorie, plus de kandidaat-producten en docs/productregels.md, en geeft terug: een product of geen product, de zekerheid en een korte reden. Vaste uitvoer via een JSON-schema; het model is een constante. De Anthropic-sleutel staat alleen lokaal in .env.
- Vaste regel in het script, vóór de AI: is de subcategorie van het artikel exact gelijk aan de naam van een product (via normalize_search), dan is dat het voorstel, met zekerheid hoog.
- Scherm Producten, alleen voor de beheerder: een blok "Voorstellen" met alleen de voorstellen met een product, gegroepeerd per product. Per voorstel de titel, het merk, de inhoud en de categorie van het artikel, de zekerheid en de reden. Per voorstel goedkeuren of afwijzen, en per groep "alles goedkeuren". Voorstellen met zekerheid laag staan in een eigen blok "Twijfelgevallen" en vallen buiten "alles goedkeuren".
- Een goedgekeurde koppeling kan ik later weer losmaken; dat telt als een afwijzing van die combinatie.
- merge_products verhuist koppelingen, voorstellen en afwijzingen van de bron naar het doel. undo_merge zet terug wat van de bron kwam; wat daarna op het doel is goedgekeurd blijft bij het doel.
- Leg de besluiten vast in docs/productregels.md en werk CLAUDE.md bij.
Klaar als:
- de proefronde een telling geeft: hoeveel artikelen beoordeeld, hoeveel voorstellen per zekerheid, hoeveel "geen product", met voorbeelden van elk;
- "AH Biologisch oranje pompoen" na goedkeuren bij het product "pompoen" hoort en een item "pompoen" op de lijst het Bonus-label krijgt, bij mij en bij Els;
- een aanbieding op een ander merk van een vast product (bijvoorbeeld Campina kwark) na goedkeuren in "Voor jou" staat;
- pompoensoep en het desembrood met pompoen niet bij "pompoen" worden voorgesteld;
- een afgewezen voorstel na opnieuw draaien niet terugkomt, en opnieuw draaien zonder nieuwe artikelen of producten niets nieuws oplevert;
- een artikel dat al op een eigen bon staat niet wordt voorgesteld;
- na het samenvoegen van twee producten de koppelingen bij het doel staan, en na het losmaken weer bij de bron;
- Els het blok "Voorstellen" niet ziet en de schrijffuncties haar weigeren.
Grenzen: geen AI-aanroep vanuit de app en geen naammatching in de database: de naam is alleen een manier om kandidaten te vinden. Niveau 1 en de favorieten veranderen niet. Geen automatische goedkeuring, ook niet bij zekerheid hoog. Nog niet automatisch draaien. Alleen productnamen en artikelgegevens gaan naar de AI, geen aankopen of gebruikers. Supabase-calls in data.js, logica in logica.js (ARCHITECTURE.md). Elke databasewijziging is een nieuw migratiebestand in supabase/migrations/.
```

Gebouwd op 7 oktober 2026 (migratie `artikel_koppelingen`):

- De tabellen `article_links` (status per artikel) en `article_link_rejections` (afgewezen combinaties), alleen bereikbaar via functies met rolcontrole. `article_products()` geeft de goedgekeurde koppelingen mee terug; staat het artikel op een bon, dan telt alleen de bon.
- `scripts/artikel-voorstellen.py`: eerst de vaste regel op subcategorie, de rest in porties van 40 naar de AI. Ook de proefronde roept de AI aan (anders valt er niets te tellen); `--max N` houdt een eerste proef klein.
- Het scherm Producten heeft de blokken "Voorstellen" en "Twijfelgevallen"; een goedgekeurd artikel staat in het opengeklapte product met "Losmaken".
- Afwijzen en losmaken halen de status van het artikel weg en bewaren alleen de afgewezen combinatie, zodat het script het artikel later bij een ander product mag voorstellen.
- "Bijgekomen sinds het oordeel" gaat op de aanmaakdatum van het product. Een oud product dat pas later weer een item of aankoop krijgt telt dus niet als nieuw.
- Bijgesteld na de eerste proefronde (migratie `artikel_lijstnamen`): een product dat nog niet bestaat kreeg geen label, ook niet als het in de bonus was ("andijvie" voor het eerst op de lijst). Het script legt daarom bij elk artikel hooguit drie lijstnamen vast, de namen die iemand op een lijst zou typen. Een item krijgt het Bonus-label als zijn naam na Nederlandse stamming gelijk is aan zo'n naam, zonder goedkeuring en zonder dat er een product voor wordt aangemaakt. Dit is een bewuste uitzondering op "geen naammatching in de database": alleen gelijkheid van de hele naam, en alleen voor het label op de lijst. Voor jou blijft werken via de bon en de goedgekeurde koppelingen.
- De opdracht aan de AI is aangescherpt: zekerheid laag is alleen voor echte twijfel over een variant. Wat alleen in de buurt komt krijgt geen product. In de eerste proef waren 248 van de 989 voorstellen "laag".
- Eerste echte ronde op 7 oktober 2026: 2422 artikelen kregen lijstnamen, ongeveer 800 voorstellen (96 via de vaste regel), de rest "geen product". De AI koos het product eerst als nummer uit de lijst en pakte dan geregeld het product ernaast ("spekreepjes" werd "sperziebonen"); nu kiest hij de naam uit een vaste lijst in het uitvoerschema. Getest in de app: goedkeuren, afwijzen, losmaken en het label via de lijstnaam werken.
- Nog open: het script draait met de hand. Automatisch draaien na elke bonusronde komt later.

#### Deel 3 – Gelaagd matchen van lijsttermen

Aanleiding (8 oktober 2026): het label kwam alleen bij exacte gelijkheid. "proteinedrank", "chocolade", "tandpasta" en "shampoo" werkten; "proteine drank" (de stemmer werkt per woord, dus een spatie geeft een ander resultaat), "proteinedrink", "chocola", "tandenpasta" en de merken "nivea", "parodontax" en "sensodyne" (lijstnamen zijn merkloos, en geen route keek naar `articles.brand`) niet.

Gebouwd en doorgevoerd op 8 oktober 2026 (migraties `gelaagd_matchen` en `matchen_bijgesteld`):

- [x] Eén functie `term_articles()` die zegt voor welke artikelen een term staat, in vijf lagen: exact (product, of lijstnaam zonder spaties en leestekens of na stamming), synoniem, merk, tolerant (pg_trgm, grens in `settings`), titel. `offers_for_list()` en `offer_details_for_list()` gebruiken die functie; hun signatuur en de app veranderen niet.
- [x] `term_synonyms`: term → naam, met bron (`manual` of `ai`) en datum. Beheer voorlopig in de SQL Editor.
- [x] `unmatched_terms`: termen die bij het toevoegen nergens op matchten, bijgehouden door `handle_unmatched_term()` vanuit een trigger op `items`.
- [x] Nagelopen met `docs/matching-controle.sql` op alle 605 ooit getypte namen: 539 exact, 7 via het merk, 7 tolerant (chocola, tandenpasta, kokoswatet, margaringe, paradontax; twijfelachtig: "kruiden" bij kipkruiden en kruidenmix), 1 via de titel, 51 zonder treffer. Bijgesteld na die proef: de sleutelvorm geldt ook voor productnamen ("proteine drank" is "proteinedrank", een naam van eiwitdrank), en de titellaag geldt alleen vanaf twee woorden.
- [ ] In de app een paar weken volgen; de grens voor tolerant bijstellen als er verkeerde labels komen. ("margerine" en "adnijvie" zijn intussen namen van een type.)
- [x] AI-stap: gebouwd in deel 4, fase 5, als Edge Function `term-classificeren` in plaats van een script; de uitkomst is een naam van een type met bron `ai`.
- [x] Een blok voor de termen: het blok "Termen" in het scherm Koppelingen (deel 4, fase 6).

Besluiten staan in `docs/productregels.md` onder "Matchen van lijsttermen". Niet gedaan: `items.normalized_name` gelijktrekken met de nieuwe sleutelvorm (raakt de sleutel van `product_aliases`), en Voor jou.

#### Deel 4 – Producttypes in plaats van samenvoegen

Aanleiding (8 oktober 2026): de catalogus groeit met elke nieuwe naam en elke bonusweek levert een wachtrij aan voorstellen op. Daarvoor in de plaats komt een vaste lijst producttypes (het wisselniveau uit `docs/productregels.md`, met de hoofdcategorie van AH als hoofdgroep) waar artikelen, getypte termen en aankopen automatisch aan gekoppeld worden. Beheer wordt achteraf controleren en corrigeren.

Besluiten: een type is het wisselniveau, niet fijner ("brood", niet "volkorenbrood"); een AI-koppeling telt direct voor label, profiel en Voor jou; een favoriet is een type, een merk plus type, of alleen een merk.

- [x] Fase 1 (de scripts van fase 1 en 3 waren eenmalig en zijn op 9 oktober 2026 verwijderd; ze staan in de git-historie): tabel `product_types`, `scripts/producttypes-voorstellen.py` (voorstel naar `docs/producttypes.csv`) en `scripts/producttypes-laden.py`.
- [x] Gijs leest de typelijst na en laadt hem (8 oktober 2026: 606 types). "sap", "papier" en "deeg" zitten bewust in geen enkel type: te vaag om te kiezen.
- [x] Fase 2: `article_types` en de Edge Function `artikelen-classificeren`: nieuwe artikelen krijgen bij het ophalen van de bonus in één ronde een type (titel, merk en categorie als invoer). Eerste ronde over alle artikelen.
- [x] Fase 3: `scripts/naar-producttypes.py` koppelt de namen van catalogusproducten, de lijstnamen en de artikelen uit de oude catalogus aan een type; `term_synonyms` wordt de ene tabel naam → type. Gedaan op 9 oktober 2026: 2402 van de 2422 artikelen hebben een type, 939 namen zijn gekoppeld (929 uit de catalogus en de lijstnamen, 10 via de AI) en 1274 van de 1281 aankopen hebben een type; "papier", "sap" en "deeg" bewust niet. Tomatensoep en kippensoep zijn opgegaan in soep. Lijstitems en favorieten hoeven niet omgezet: er zijn 4 items (hun type volgt uit de naam) en nog geen favorieten.
- [x] Fase 4: `purchase_profile`, `regular_products`, `offers_for_me`, `term_articles`, `match_receipt_items` en `add_offer_item` rekenen op types; zelfde signatuur, de app verandert niet. Doorgevoerd op 9 oktober 2026. Vergeleken op alle 623 namen uit de catalogus: 357 hebben deze week een label (was 304); 17 raakten het kwijt, bijna allemaal terecht (een zero-variant of groente uit pot gaf eerder een label bij het gewone product). In Voor jou 55 aanbiedingen (was 45), geen enkele weg. Voor het label gaat een merk vóór een naam: "nivea" is alles van Nivea, "nivea shampoo" alleen de shampoo. Nog te doen: testen in de app met twee browsers.
- [x] Fase 5: Edge Function `term-classificeren`, aangeroepen vanuit `handle_unmatched_term()` via `pg_net`: een term zonder treffer krijgt direct een type, opgeslagen als synoniem met bron `ai` en datum. Het label verschijnt zonder goedkeuring. Gebouwd op 9 oktober 2026 en getest via het afhandelpunt: "wc eend" werd toiletreiniger, "bananenn" bananen en "afwasborstel" kreeg geen type, binnen 8 seconden. Ook een aankoop met een onbekende naam gaat langs dit punt. Nog te doen: in de app zien dat het label bij beide deelnemers verschijnt.
- [x] Fase 6: het scherm Producten wordt een overzicht van de AI-koppelingen om te controleren en te corrigeren; samenvoegen vervalt.
- [x] Fase 7: favorieten op type, of merk plus type. Doorgevoerd op 9 oktober 2026, alleen in de database: `offers_for_me()` bepaalt bij het zoeken waar de term van een favoriet voor staat, en de suggesties komen uit de typelijst. Getest met proef-favorieten die zijn teruggedraaid: "tandpasta" raakt drie aanbiedingen (ook Sensodyne), "shampoo" van Nivea alleen de twee shampoos, "Lindt" alles van het merk, "tomatensoep" alle soep, en een term die nergens voor staat ("glutenvrij") zoekt nog op woorden in de titel. Nog te doen: een echte favoriet toevoegen in de app.
- [x] Fase 8: opruimen. Gedaan op 9 oktober 2026, eerder dan gepland omdat Gijs dat wilde: `products`, `product_aliases`, `product_merges`, `article_links`, `article_link_rejections` en `article_names` zijn weg, met hun functies, de trigger `ensure_product()`, de kolommen `items.product_id` en `term_synonyms.target` en de scripts eromheen. De inhoud van de tabellen staat in `data/backup/20261009-oude-catalogus.json` (niet in git). Terug naar het oude model kan niet meer met een migratie. Wat hierboven over de catalogus, samenvoegen, voorstellen en lijstnamen staat (stap 3a, stap 5 deel 1 tot en met 3) beschrijft hoe het was.

Vervangt de open punten van deel 3 (de AI-stap en het blok in het scherm Producten).

##### Fase 6 uitgewerkt: het scherm Koppelingen

Uitgeschreven op 9 oktober 2026, nog niet gebouwd.

Doel: de beheerder ziet wat de AI heeft gekoppeld, corrigeert wat fout is en ziet welke types ontbreken. Niets wacht op goedkeuring: alles telt al mee, het scherm is er om achteraf bij te sturen.

Uitgangspunt in cijfers (9 oktober 2026): 1716 artikelen met een oordeel van de AI dat nog niet is nagekeken (1563 zekerheid hoog, 131 middel, 2 laag, 20 zonder type), en 19 termen via de AI (10 zonder type). Alles nakijken is geen werk voor een telefoon, dus het scherm vraagt alleen aandacht voor wat twijfelachtig is. Zekerheid hoog is wel in te zien, maar staat niet als taak klaar.

Het scherm (zelfde plek: Profiel > "Koppelingen beheren", view `producten`, alleen voor de beheerder), van boven naar beneden:

1. **Termen** (`<details>`, open als er iets in staat): wat mensen typten en de AI beoordeelde, nieuwste eerst. Per rij de term, het type of "geen type", het merk als dat erbij hoort, de zekerheid, de reden en de datum. Knoppen: "Klopt", "Ander type", en bij een type ook "Geen type".
2. **Artikelen om na te kijken**: de oordelen met zekerheid middel en laag, gegroepeerd per type. Per groep "Alles klopt"; per artikel de titel, het merk, de categorie, de reden, en "Ander type" of "Geen type".
3. **Geen type**: artikelen waar de AI niets bij vond, gegroepeerd op het type dat volgens de AI ontbreekt, met het aantal artikelen. Per groep "Type aanmaken" (naam, hoofdgroep en afbakening invullen; de artikelen worden daarna opnieuw beoordeeld) of "Geen boodschap" (blijft zonder type en verdwijnt uit de lijst). Per artikel ook "Ander type".
4. **Types**: zoekveld en de lijst van alle types met het aantal artikelen, namen en aankopen. Een type openklappen toont de afbakening, de schakelaar "telt niet mee in profiel", en zijn namen en artikelen (ook die met zekerheid hoog), elk met "Ander type". Hernoemen en de afbakening wijzigen kan hier ook.

"Ander type" opent één keuzelijst met een zoekveld over alle types, gegroepeerd per hoofdgroep; die wordt overal hergebruikt.

Wat verdwijnt: de samenvoegbalk, de blokken "Voorstellen" en "Twijfelgevallen", de oude productlijst, en in de code alles rond `product_overview`, `merge_products`, `undo_merge`, `article_link_overview`, `approve_article_links` en `reject_article_link`. De databasefuncties zelf blijven tot fase 8.

Database (één migratie, alles alleen voor de beheerder):

- `type_link_overview()`: in één keer de termen, de artikelen om na te kijken, de artikelen zonder type en de types met hun tellingen.
- `type_details(p_type)`: de namen en artikelen van één type, pas bij openklappen.
- `mark_links_reviewed(p_terms, p_articles)`: "Klopt" en "Alles klopt"; zet alleen `reviewed_at`.
- Bestaand en hergebruikt: `save_term_types(…, 'manual')` en `set_article_types(…, 'manual')` voor "Ander type" en "Geen type", `save_product_types()` voor een nieuw of gewijzigd type, `reset_untyped_articles()` daarna.
- Nieuw voor termen: de AI onthoudt bij "geen type" welk type ontbreekt (`term_synonyms.suggested_type`, zoals bij artikelen), zodat "afwasborstel" in blok 3 terechtkomt naast de artikelen.
- Hernoemen van een type: `rename_product_type(p_type, p_name)`; de oude naam blijft werken als naam van het type.

Client, volgens `ARCHITECTURE.md`: de calls in `data.js`, state en regels in `logica.js` (vervangen het deel "Producten"), `app.js` rendert alleen. De logica van dit scherm staat al in `logica.js`, dus er is geen aparte verhuiscommit nodig.

Volgorde, elk een eigen commit met een test:

1. Migratie met de leesfuncties en `mark_links_reviewed`; nalopen in de SQL Editor. (Gedaan op 9 oktober 2026, samen met de export en de functies om een type aan te maken en te wijzigen.)
2. Het scherm alleen-lezen: de vier blokken en de typelijst. (Gebouwd op 9 oktober 2026, samen met stap 3 en 4; nog te testen in de browser.)
3. De acties: "Klopt", "Ander type", "Geen type", met de keuzelijst. (Gebouwd, nog te testen.)
4. "Type aanmaken", hernoemen, samenvoegen en de schakelaar. (Gebouwd, nog te testen.)
5. Opruimen van de oude code in de client, `CACHE` bumpen, `CLAUDE.md` bijwerken.

Open keuzes:

- **De typelijst heeft één bron: de database** (besluit 9 oktober 2026). `docs/producttypes-export.csv` is alleen een afdruk, die `scripts/producttypes-exporteren.py` bij elke commit ververst via de git-hook in `.githooks/`. Types toevoegen aan een bestand en opnieuw laden bestaat niet meer; de scripts daarvoor zijn verwijderd. Een type aanmaken, wijzigen of samenvoegen doe je in het scherm Koppelingen.
- **Merk bij een term corrigeren** ("sensodyne tandpasta" kreeg het verkeerde merk): later, niet in de eerste versie; "Ander type" laat het merk staan, "Geen type" haalt het weg.
- **Een term die als "geen type" is beoordeeld opnieuw laten beoordelen** na een nieuw type: gebeurt automatisch voor termen waarvan het voorgestelde type gelijk is aan het nieuwe type, anders met de hand.

### [–] Stap 6 – Automatische aankoopimport (vervallen)

Vervallen op 9 oktober 2026. De historie is één keer opgehaald (stap 2a); daarna komen bonnen binnen via "Bon scannen". Een periodieke koppeling met de AH-API is kwetsbaar, vraagt opgeslagen inloggegevens en is in de publieke fase niet bruikbaar. Een geswipet item is ook een aankoop (`buy_item`), dus stap 8 heeft ook zonder bon data.

### [x] Stap 7 – Aanbiedingen kiezen en wegklikken

Vastgesteld op 9 oktober 2026. Vervangt de oude stap 7 "Persoonlijke laag". "Voorkeur per variant" vervalt: merkfavorieten dekken dat grotendeels. "Niet voor mij" komt terug als wegklikken (deel 3).

Waar: het bonuspaneel van de lijst (`bonus-paneel`), waar per item de aanbiedingen staan ("Voor tomatensoep").

Uitgangspunten:

- De matching blijft op type (het wisselniveau, `docs/productregels.md`). Dat bij "tomatensoep" ook Conimex laksa verschijnt is een gevolg van die keuze, geen fout. Het type wordt niet smaller gemaakt; binnen het type wordt gerangschikt (deel 1).
- Wegklikken is voor wat je deze week niet wilt, niet om slechte matching op te vangen.
- Toevoegen en wegklikken bij een item gelden voor de hele lijst. Wegklikken in "Voor jou" geldt per persoon.

#### Deel 1 – Volgorde binnen het type

- [x] Plat kenmerk `variant` naast het type, bijvoorbeeld "tomaat", "kip", "groente". Geen tweede laag onder de types en geen beheer.
- [x] De AI vult het in bij dezelfde aanroep die nu het type bepaalt: bij artikelen in `artikelen-classificeren`, bij termen in `term-classificeren`.
- [x] Bij een item eerst de aanbiedingen met een artikel met dezelfde variant als de term, daarna de rest. De variant bepaalt alleen de volgorde en sluit nooit iets uit; een fout kost een lagere plek, geen gemiste aanbieding.
- [x] Binnen een aanbieding staan de artikelen met dezelfde variant bovenaan en zijn ze gemarkeerd.
- Gebouwd op 9 oktober 2026 (migratie `variant`). De variant is vrije tekst van één woord en wordt vergeleken op de Nederlandse stam ("tomaat" is "tomaten"). Bestaande artikelen en namen zijn aangevuld met `scripts/ah-bonus-opslaan.py --types`; de wekelijkse ronde vult nieuwe aan. In het paneel staan de aanbiedingen nu per item bij elkaar.
- Waarom niet op woorden in de titel: "tomatensoep" vindt "AH Verse soep Chinese tomaat" dan niet (samengesteld woord, andere spelling).

#### Deel 2 – Een aanbieding kiezen

- [x] Per aanbieding een knop om hem te kiezen. Die opent de artikelen van de aanbieding; artikelen met dezelfde variant als de oorspronkelijke term staan al aangevinkt. Je kunt er één of meer bij of af klikken. Niets aangevinkt is de aanbieding als geheel. Bij een grote aanbieding ("Alle Conimex") staan eerst alleen de artikelen waar de term voor staat, en nooit meer dan vijf; de rest achter "Toon ook de n andere artikelen".
- [x] De keuze vervangt het item op de lijst. Dit wijkt bewust af van "Voor jou", waar `add_offer_item` altijd een aparte rij naast het bestaande item maakt.
- [x] De oorspronkelijke invoer blijft bewaard in een eigen veld op het item (bijvoorbeeld `items.original_name`), niet alleen in de weergave.
- [x] Elk aangevinkt artikel is een eigen item (besluit 9 oktober 2026, na de eerste test; eerst was het één item met de varianten eronder, dat gaf een te volle rij op de telefoon). Het item zelf wordt het eerste artikel, voor elk volgend artikel komt er een rij bij. Swipen is dus per artikel één aankoop.
- [x] Weergave, even compact als een gewoon item: de naam van het artikel, eronder "voor tomatensoep · door Gijs · vandaag", en rechts in het oranje label de korting zelf ("2 voor 5.99") met "t/m zo".
- [–] Een aparte hint "2 nodig voor de korting" is vervallen: het label zegt het al. De hoeveelheid wordt niet automatisch aangepast.
- [x] Verloopt de aanbieding terwijl het item nog op de lijst staat, dan valt het item terug naar de oorspronkelijke invoer; aanbieding en varianten gaan eraf. Van meerdere items uit één keuze blijft er één over. Let op: `offer_id` wordt nu pas na 28 dagen leeggemaakt (`save_offers`), dus het terugvallen op `valid_to` is nieuw.
- [x] Geldt voor de hele lijst en is via Realtime direct zichtbaar voor alle leden.
- Gebouwd op 9 oktober 2026 (migraties `aanbieding_kiezen` en `keuze_losse_items`). Het veld is `items.original_name`, de keuze zelf staat als momentopname in `items.offer_choice`, en `items.choice_group` houdt de items uit één keuze bij elkaar. Erbij gekomen: "Keuze wissen" in het paneel (er blijft één item over met wat er stond) en ongedaan maken na swipen zet het item met zijn keuze terug. Een item dat vanuit "Voor jou" op de lijst staat heeft ook "Kiezen" (migratie `keuze_vanuit_voorjou`): je zet de aanbieding met de plus op de lijst en kiest daar de artikelen; "Keuze wissen" maakt er weer de aanbieding van.

#### Deel 3 – Wegklikken

- [x] Per aanbieding bij een item "Niet deze week". Geldt voor de hele lijst, tot de aanbieding verloopt. Komt dezelfde actie later terug, dan is hij weer zichtbaar.
- [x] Er staat bij wie het wegklikte ("weggeklikt door Els"), en onderaan het paneel staat een ingeklapt blok "Weggeklikt (n)" om het terug te halen.
- [x] In "Voor jou" kun je een aanbieding ook wegklikken, daar per persoon en ook tot de aanbieding verloopt.
- Gebouwd op 9 oktober 2026 (migratie `aanbieding_wegklikken`, tabel `offer_dismissals`). Wegklikken geldt per item: "Alle Conimex" wegklikken bij tomatensoep laat hem bij kroepoek staan. Zijn alle aanbiedingen van een item weggeklikt, dan is het Bonus-label weg en zegt de groene balk "n aanbiedingen weggeklikt". In "Voor jou" is een weggeklikte aanbieding niet terug te halen; hij komt terug als de actie opnieuw loopt.

#### Deel 4 – Keuzes vastleggen

- [x] Elke keuze wordt opgeslagen: lijst, wie, oorspronkelijke term, type, variant, aanbieding, gekozen artikelen, actie (gekozen, weggeklikt, teruggehaald) en tijdstip.
- [x] Niets leest deze data nog. Hij is bedoeld om later de matching en de volgorde te verbeteren (welke overstappen maken mensen echt) en vervangt de oude persoonlijke laag.
- [ ] Voor de publieke fase: bewaartermijn vastleggen (AVG).
- Gebouwd op 9 oktober 2026 (migratie `keuzes_vastleggen`, tabel `offer_actions`). Er is een vierde actie bij: "gewist" (keuze wissen). De aanbieding staat er als momentopname in, omdat aanbiedingen na 28 dagen worden opgeruimd. Terugvallen na afloop wordt niet vastgelegd. De rijen verdwijnen nu alleen met de lijst.

Besloten op 9 oktober 2026:

- Variant: vrije tekst, vergeleken op de Nederlandse stam (`list_stem`). Geen vaste lijst, geen tweede AI-aanroep.
- Het Bonus-label verdwijnt als alle aanbiedingen van een item zijn weggeklikt. De balk blijft zolang er iets is weggeklikt, zodat het terug te halen is.
- Een item valt terug bij het laden van de lijst (een RPC zet verlopen keuzes van die lijst terug), niet door een geplande taak.

Klaar als:

- bij "tomatensoep" de aanbiedingen met tomatensoep bovenaan staan en Conimex laksa lager, maar zichtbaar;
- Unox kiezen "tomatensoep" vervangt door "Unox Chinese tomatensoep" met "voor tomatensoep" eronder en "2 voor 5.99 · t/m zo" in het label, en Els dat meteen ziet;
- het item na de looptijd weer "tomatensoep" heet;
- Conimex wegklikken het voor ons allebei verbergt, met "weggeklikt door Gijs", en het terug te halen is;
- elke keuze in de nieuwe tabel staat.

```
/plan
Wat: in het bonuspaneel van de lijst kan ik per item een aanbieding kiezen (die vervangt het item) of een aanbieding wegklikken voor deze week. Daarnaast komen de aanbiedingen in een betere volgorde. Lees eerst stap 7 in ROADMAP.md; daar staan de keuzes.
Waarom: bij een item als "tomatensoep" staan nu veel soepaanbiedingen door elkaar. Ik wil de aanbieding die ik ga kopen op de lijst kunnen zetten zonder te vergeten wat ik zocht, en de rest kunnen opruimen.
Hoe het moet werken: zoals beschreven in de delen 1 tot en met 4 van stap 7. Doe de delen in die volgorde en stop na elk deel voor een test en een commit.
Grenzen: de matching op type blijft zoals hij is; de variant bepaalt alleen de volgorde. "Voor jou" blijft werken zoals nu, op het wegklikken na. Supabase-calls in data.js, logica in logica.js (ARCHITECTURE.md). Elke databasewijziging is een nieuw migratiebestand in supabase/migrations/. Gewijzigde Edge Functions opnieuw deployen. Leg de open punten uit stap 7 aan mij voor in het plan.
```

### [x] Compacte lijst

Ontwerp in `compacte-lijst.md` (9 oktober 2026): op een telefoon pasten er 3 items op het scherm, het doel was 8 tot 10.

- [x] Kop ongeveer de helft lager; de groene banner is een chip op één regel ("3 in de bonus bij AH").
- [x] Camera-icoon in het invoerveld; de regel "Foto toevoegen" is weg en het aantal-veld is smaller.
- [x] Items als rijen met een lijn in plaats van kaarten: aantal in oranje vóór de titel (alleen boven 1, of met eenheid), titel hooguit twee regels, één metaregel ("voor soep · t/m zo"), kleinere pill.
- [x] Geen kruisje meer; verwijderen is naar links vegen.
- Gebouwd op 9 oktober 2026. De open punten zijn zo beslist: de lijstnaam opent een lijstmenu (Mijn lijsten, Deelnemers, Iemand uitnodigen); een tik op een item klapt "toegevoegd door Els · vandaag" uit; de initiaal van een ander staat onder het bonuslabel; de kop klapt niet in bij scrollen. De hint "2 nodig voor de korting", bij stap 7 vervallen, staat nu in de metaregel. Bij een item met alleen het label "Bonus" staat de supermarkt niet meer op de rij, wel in de chip.

### [ ] Stap 8 – Binnenkort weer nodig

Op basis van het aankoopinterval per product (mediaan) voorspellen wanneer iets weer nodig is, en dat combineren met aanbiedingen: "bijna op én deze week in de bonus".

- [ ] Verwachte volgende aankoop per product per lijst
- [ ] Tonen op de lijst of op Mijn profiel
- [ ] Combineren met kortingskansen uit stap 5

Uitwerken als er genoeg aankoopdata is.

### [ ] Stap 9 – Meerdere supermarkten

Pas oppakken als er een tweede bron van aanbiedingen is.

- [ ] Tweede supermarkt als extra bron van artikelen en aanbiedingen; matching en profiel blijven gelijk
- [ ] Aanbiedingen vergelijken op prijs per kilo of liter, ook tussen kortingsvormen (1+1 gratis tegen 25% korting)
- [ ] Per gebruiker of huishouden vastleggen welke winkels ze bezoeken, of dat afleiden uit de bonnen
- [ ] Volgorde van opties: prijs, eigen winkel, merkvoorkeur uit de persoonlijke laag

Klaar als: iemand die kwark op de lijst zet zowel een AH- als een Jumbo-aanbieding op kwark ziet, met de beste voor die persoon bovenaan.

---

## Publieke fase (voorbereiding)

Niet bouwen voordat de testfase goed werkt. Wel alvast vastleggen.

- Aankopen: afvinken op de lijst als basis, bonfoto (AI leest de regels, foto wordt niet bewaard) als aanvulling. Geen inloggen bij AH namens gebruikers.
- Aanbiedingen: duurzame bron kiezen. Opties: afspraak met een folder-aggregator, of de AH-bonusdata zonder login na juridisch advies. Daarna Jumbo en andere ketens.
- AVG: privacyverklaring, verwerkingsregister, bewaartermijnen, RLS controleren voor meerdere huishoudens.
- Kleine testgroep van buiten.

---

## Wat vervalt of verschuift

- Oude fase 4 "Slimmer matchen" (zoekwoorden, pg_trgm, aanbieding kiezen bij een item, leren van keuzes): vervangen door matchen op artikel-ID in stap 5. Het leren van afwijzingen komt terug als wegklikken in stap 7. Favorieten (oud 4d) is stap 4.
- Oude fase 5 "Echte aanbiedingen": wordt stap 1 en 3.
- Oude fase 6 "Advies": gesplitst. Kortingskansen (inclusief favorieten) zit in stap 5, "binnenkort weer nodig" is stap 8. "Product uit profiel halen" is al af (vlag "telt niet mee in profiel" uit 3b).

---

## Later te beslissen

- Ontwerp verfijnen in Claude Design
