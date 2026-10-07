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

### [ ] Stap 1 – Verkenning AH-aanbiedingen

Script dat met een anoniem AH-token één week bonusgroepen met hun artikelen ophaalt en als JSON opslaat. Draait lokaal, niet in de app.

- [ ] Bonusgroepen + artikelen van één week opgeslagen
- [ ] Naast de huidige productlijst gelegd: hoeveel aanbiedingen raken een product dat we kopen, via ID en via naam
- [ ] Besluit: klopt de opzet hieronder, of moet er iets anders

Klaar als: een kort overzicht met aantallen en voorbeelden van wat goed en fout gaat.

### [ ] Stap 2 – Artikel-ID bij aankopen

Huidige situatie: een bonregel is geen eigen tabel maar een rij in `purchases` met `receipt_id`, `receipt_name`, `price` en `discount`. De supermarkt staat al op de bon (`receipts.store`). `data/ah-bonnen.json` heeft per regel al een `product_id` van AH, maar `scripts/ah-importeren.py` gooit dat weg.

Besluit: het `product_id` van de bon wordt hoe dan ook opgeslagen, ook als het niet het webshop-ID van de bonusgroepen blijkt te zijn. Het is een vast ID voor hetzelfde artikel en daarmee de basis voor de persoonlijke laag (stap 7). De vertaling naar het webshop-ID komt in een aparte tabel, zodat deze stap niet afhangt van de vraag of het herleidbaar is en er bij aankopen later niets herschreven hoeft te worden.

- [ ] Migratie: kolom `receipt_article_id` op `purchases`, met een opmerking op de kolom dat dit het ID van de bon is en niet het webshop-ID. Geen kolom voor de supermarkt: die volgt uit de bon via `receipt_id`, en aankopen zonder bon hebben ook geen artikel-ID
- [ ] Migratie: vertaaltabel van bon-ID naar webshop-ID per supermarkt. Blijft leeg tot bekend is hoe de vertaling werkt (stap 1 en 5)
- [ ] `save_receipt` neemt het artikel-ID per regel aan en slaat het op, ook bij een regel die aan een bestaande aankoop of een item van de lijst wordt gekoppeld. `delete_receipt` maakt het weer leeg bij gekoppelde aankopen, net als de andere bonkolommen
- [ ] `scripts/ah-importeren.py` geeft het `product_id` mee en voegt regels alleen nog samen als naam én ID gelijk zijn. Dezelfde naam met verschillende ID's (bijvoorbeeld twee formaten met dezelfde bontekst) blijven aparte regels
- [ ] `save_receipt` daarop aanpassen: nu wordt een regel met exact dezelfde naam als een aankoop van die dag overgeslagen, waardoor de tweede van zulke regels zou wegvallen. "Een product telt één keer per dag" wordt: één keer per naam én artikel-ID
- [ ] Bestaande AH-aankopen aanvullen vanuit `data/ah-bonnen.json`, op bon (winkel, datum, totaal) en `receipt_name`. Eerst een proefronde zonder schrijven, zoals de import zonder `--echt`, met een telling: hoeveel aankopen krijgen een ID, hoeveel niet, en waarom niet
- [ ] Gescande bonnen ("Bon scannen") krijgen geen artikel-ID: op een foto staat het niet. Die aankopen matchen in stap 5 via de naam

Klaar als: een nieuw geïmporteerde AH-bon bij elke aankoop een artikel-ID heeft, twee regels met dezelfde naam maar een ander ID als twee aankopen zijn opgeslagen, en de telling van het aanvullen klopt met de database.

Volgorde: na stap 1. Het kan er los van, maar stap 1 laat zien hoe de AH-data eruitziet en dat helpt bij het beoordelen van deze stap.

### [ ] Stap 3 – Aanbiedingen ophalen (AH)

- [ ] Tabellen voor aanbiedingen en de artikelen per aanbieding, met geldigheid en kortingstype
- [ ] Wekelijks automatisch ophalen (anoniem token, geen account)
- [ ] Oude aanbiedingen opruimen

Klaar als: de bonus van deze week elke week vanzelf in de database staat.

### [ ] Stap 4 – Favorieten

Algemeen of merkspecifiek, per gebruiker. In deze stap alleen het vastleggen en beheren; de aanbieding bij een favoriet tonen hoort bij stap 5.

```
/plan
Wat: gebruikers kunnen favorieten aangeven: producten waarvan ze altijd willen weten of ze in de aanbieding zijn.
Waarom: een favoriet is een expliciet signaal en werkt vanaf dag één. Een nieuwe gebruiker heeft nog geen aankoopprofiel, maar krijgt via favorieten meteen relevante aanbiedingen.
Hoe het moet werken:
- Een favoriet hoort bij een gebruiker, niet bij een lijst.
- Twee niveaus:
  1. Algemeen: een product uit de productcatalogus, bijv. "pindakaas". Elke aanbieding binnen dat product telt, ongeacht merk of soort.
  2. Specifiek: hetzelfde product plus een verplicht merk of variant, bijv. "pindakaas" + "calvé". Alleen aanbiedingen die daaraan voldoen tellen.
- Het specifieke deel is vrije tekst die straks (stap 5) moet voorkomen in de naam of het merk van een artikel in de bonusgroep. Het product zelf blijft het product uit de catalogus, volgens docs/productregels.md.
- Toevoegen kan op twee plekken:
  - Op Mijn profiel, in een sectie "Mijn favorieten": product zoeken in de catalogus, optioneel een merk of variant invullen.
  - Via een ster bij een item op de lijst of bij een aankoop. Dat maakt een algemene favoriet van het product dat erbij hoort.
- Op Mijn profiel kan ik favorieten bekijken, het merk of de variant aanpassen en ze verwijderen.
- Valt een favoriet product later samen met een ander product (samenvoegen door de beheerder), dan schuift de favoriet mee.
Klaar als:
- ik "pindakaas" als algemene favoriet en "pindakaas" + "calvé" als specifieke favoriet kan toevoegen, aanpassen en verwijderen;
- Els mijn favorieten niet ziet en ik de hare niet;
- een favoriet blijft bestaan nadat het product is samengevoegd met een ander product.
Grenzen: nog geen koppeling met aanbiedingen (stap 5), geen AI. Nog geen meldingen of pushberichten. Elke databasewijziging is een nieuw migratiebestand in supabase/migrations/. Verander swipen, bonscannen en het aankoopprofiel niet.
```

### [ ] Stap 5 – Matchen en kortingskansen

- [ ] AH-artikel → product: eerst bekend artikel-ID, dan alias, dan AI-voorstel volgens `docs/productregels.md` (beheerder keurt goed)
- [ ] Aanbieding → product via de artikelen in de bonusgroep
- [ ] Kortingskansen tonen op basis van aankoopprofiel en favorieten
- [ ] Bij een favoriet die nu in de aanbieding is: de aanbieding tonen (supermarkt, korting, geldig tot), met één tik om het product op een lijst te zetten. Een specifieke favoriet ("pindakaas" + "calvé") toont alleen de aanbieding van dat merk.

Klaar als: een aanbieding op een product dat we vaak kopen of als favoriet hebben in de app verschijnt, en een aanbieding op iets wat we nooit kopen niet.

### [ ] Stap 6 – Automatische aankoopimport (alleen eigen accounts)

- [ ] Kassabonnen van Gijs (en eventueel Els) periodiek ophalen via de AH-API
- [ ] Dubbele-boncontrole blijft werken

Alleen voor de testfase. Niet uitbreiden naar andere gebruikers.

### [ ] Stap 7 – Persoonlijke laag

- [ ] Voorkeur per variant afleiden uit `name` en `receipt_name` (bijvoorbeeld altijd volkoren)
- [ ] "Niet voor mij" bij een aanbieding, en daarvan leren

Pas oppakken als stap 5 een paar weken draait.

### [ ] Stap 8 – Binnenkort weer nodig

Op basis van het aankoopinterval per product (mediaan) voorspellen wanneer iets weer nodig is, en dat combineren met aanbiedingen: "bijna op én deze week in de bonus".

- [ ] Verwachte volgende aankoop per product per lijst
- [ ] Tonen op de lijst of op Mijn profiel
- [ ] Combineren met kortingskansen uit stap 5

Uitwerken als er genoeg aankoopdata is.

---

## Publieke fase (voorbereiding)

Niet bouwen voordat de testfase goed werkt. Wel alvast vastleggen.

- Aankopen: afvinken op de lijst als basis, bonfoto (AI leest de regels, foto wordt niet bewaard) als aanvulling. Geen inloggen bij AH namens gebruikers.
- Aanbiedingen: duurzame bron kiezen. Opties: afspraak met een folder-aggregator, of de AH-bonusdata zonder login na juridisch advies. Daarna Jumbo en andere ketens.
- AVG: privacyverklaring, verwerkingsregister, bewaartermijnen, RLS controleren voor meerdere huishoudens.
- Kleine testgroep van buiten.

---

## Wat vervalt of verschuift

- Oude fase 4 "Slimmer matchen" (zoekwoorden, pg_trgm, aanbieding kiezen bij een item, leren van keuzes): vervangen door matchen op artikel-ID in stap 5. Het leren van afwijzingen komt terug als "Niet voor mij" in stap 7. Favorieten (oud 4d) is stap 4.
- Oude fase 5 "Echte aanbiedingen": wordt stap 1 en 3.
- Oude fase 6 "Advies": gesplitst. Kortingskansen (inclusief favorieten) zit in stap 5, "binnenkort weer nodig" is stap 8. "Product uit profiel halen" is al af (vlag "telt niet mee in profiel" uit 3b).

---

## Later te beslissen

- Ontwerp verfijnen in Claude Design
