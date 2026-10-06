# Bonusbuddy – Roadmap

Bouwplan voor de volgende fases. Werk van boven naar beneden; vink af wat klaar is.
Opdrachten tussen ``` zijn bedoeld om in Claude Code te plakken.

## Werkwijze per stap

1. `/clear`
2. Opdracht plakken (met `/plan` ervoor), plan lezen, vragen stellen
3. Claude laten bouwen (modus Manual)
4. SQL zelf uitvoeren in Supabase (SQL Editor)
5. Testen op telefoon en laptop, liefst met z'n tweeën
6. Commit en push

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

### [ ] 3a – Producten

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

### [ ] 3b – Aankoopprofiel op Mijn profiel

```
/plan
Wat: het aankoopprofiel van ons huishouden tonen op de pagina Mijn profiel.
Waarom: ik wil zien wat de app over ons koopgedrag weet en controleren of dat klopt; later de basis voor kortingsadvies.
Hoe het moet werken:
- Sectie "Aankoopprofiel" op Mijn profiel.
- Periode: laatste 4 weken, 3 maanden, 12 maanden, alles. Rollend vanaf vandaag (4 weken = vandaag min 28 dagen), niet per kalendermaand.
- Filter: alle lijsten, of één specifieke lijst.
- Kerncijfers over de gekozen periode: aantal aankopen (rijen in purchases), aantal verschillende producten (uit 3a), uitgegeven en bespaard.
- Geld: de prijs van een aankoop is het bedrag van de hele regel vóór korting. Uitgegeven = prijs min korting, bespaard = korting, alleen over aankopen met een prijs. Toon erbij bij hoeveel procent van de aankopen de prijs bekend is.
- Top 10 producten over de gekozen periode, gesorteerd op aantal aankoopdagen (meerdere keren op één dag telt als één keer; stuks tellen kan niet, want de hoeveelheid is vrije tekst).
- Per product in de top 10: om de hoeveel dagen (de mediaan van de tussenpozen tussen aankoopdagen) en de datum van de laatste aankoop. Het interval wordt altijd over alle data berekend, los van de gekozen periode, en pas getoond vanaf 3 aankoopdagen; daaronder "te weinig data".
- Verdeling per supermarkt over de gekozen periode als staafjes op aantal aankopen, met het bedrag erachter. De supermarkt komt van de bon; aankopen zonder bon vallen onder "onbekend".
- Uitgaven per maand als staafjes: altijd de laatste 12 maanden, los van de gekozen periode. De lopende maand is gemarkeerd als onvolledig en een maand zonder prijsgegevens toont "geen prijsdata" in plaats van € 0.
- Alle dagen en maanden in Nederlandse tijd (Europe/Amsterdam).
- Kort uitlegtekstje per onderdeel. Daarin staat in elk geval: dit is het profiel van het huishouden (alle deelnemers, ook aankopen van vóór je toetreding), het interval kijkt naar alle data, en de bedragen zijn een ondergrens (alleen bonregels met een prijs, zonder statiegeld).
Klaar als: de cijfers kloppen met Supabase en filters en periodes werken. Geef per kerncijfer een losse controlequery die ik in de SQL Editor naast de uitkomst kan leggen.
Grenzen: alleen aankopen uit lijsten waarvan ik deelnemer ben en die meetellen voor het profiel (ook gearchiveerde). Reken in de database: één functie die alles in één keer teruggeeft, de frontend toont alleen. Geen grafiekbibliotheek. Goed leesbaar op een telefoon. Geen seizoenspatronen, geen "samen gekocht" en geen voorspellingen.
```

---

## Fase 4 – Slimmer matchen

### [ ] 4a – Zoekwoorden op aanbiedingen

```
/plan
Wat: aanbiedingen matchen op zoekwoorden in plaats van op de productnaam.
Waarom: zoeken op lettercombinaties mist samengestelde woorden (tijgerbrood, scharreleieren) en enkelvoud/meervoud (banaan/bananen), en geeft foute matches (brood in "Aroma Rood").
Hoe het moet werken:
- Geef deals een kolom met zoekwoorden (gewone Nederlandse woorden, enkelvoud én meervoud).
- Vul de zoekwoorden voor de testaanbiedingen in seed_deals.sql zelf in.
- Match eerst op exacte zoekwoorden; de trigram-zoekfunctie alleen als vangnet voor typfouten, met een strenge drempel.
Klaar als: "brood", "eieren", "banaan" en "bananen" een label geven en "brood" niet meer matcht met koffie. Laat een tabel met resultaten zien.
Grenzen: nog geen AI-koppeling. Geef de SQL apart.
```

### [ ] 4b – Aanbieding kiezen bij een item

```
/plan
Wat: op het bonuslabel tikken om de gevonden aanbiedingen te zien en er eventueel één te kiezen.
Hoe het moet werken:
- Tik op het label: lijstje met aanbiedingen (supermarkt, product, korting, geldig tot).
- Eén kiezen koppelt die aan het item; "geen van deze" laat het label verdwijnen voor dat item.
- Sla de keuze op voor later leren.
Klaar als: ik bij "kaas" een aanbieding kies en mijn vriendin dezelfde keuze ziet.
Grenzen: eenvoudig en geschikt voor een telefoon.
```

### [ ] 4c – Leren van keuzes

```
/plan
Wat: de app leert per gebruiker van keuzes bij aanbiedingen.
Hoe het moet werken:
- Aanbiedingen die lijken op eerdere keuzes voor die itemnaam komen bovenaan; eerder afgewezen matches worden niet meer getoond.
- Herken een gekozen product ook in volgende weken (op productnaam/zoekwoorden, niet op id).
- Gebruik ook het aankoopprofiel: producten die we vaak kopen wegen zwaarder.
Klaar als: na twee keer dezelfde soort kaas kiezen staat die bovenaan, en een afgewezen match komt niet terug.
Grenzen: uitlegbaar, geen ingewikkeld model.
```

---

## Fase 5 – Echte aanbiedingen

### [ ] 5 – Automatisch ophalen + AI-zoekwoorden

```
/plan
Wat: aanbiedingen van AH en PLUS automatisch ophalen, met AI-zoekwoorden, en onbekende itemnamen vertalen.
Hoe het moet werken:
- Onderzoek eerst de opties (onofficiële AH-koppeling, Apify, anders) met voor- en nadelen (betrouwbaarheid, kosten, onderhoud, voorwaarden) en laat mij kiezen.
- Een Edge Function haalt dagelijks vroeg de aanbiedingen op, verwijdert verlopen deals en voegt nieuwe toe.
- Een klein Claude-model bepaalt zoekwoorden per nieuwe aanbieding, in batches.
- Een itemnaam zonder match: één keer zoekwoorden opvragen bij de API en bewaren in een tabel synoniemen.
Klaar als: deals bevat de echte aanbiedingen van deze week, de labels kloppen, en "wc-papier" vindt toiletpapier (tweede keer zonder API-aanroep).
Grenzen: alleen privégebruik, alleen nodige velden opslaan, sleutels in Supabase secrets. Toon een kostenschatting per week.
```

---

## Fase 6 – Advies (uitwerken als er een paar weken data is)

- [ ] Binnenkort weer nodig: vaste producten waarvan het gebruikelijke interval bijna voorbij is, met één tik op de lijst
- [ ] Kortingskansen: welke van mijn vaste producten nu in de bonus zijn
- [ ] Profiel corrigeren: product uit profiel halen (samenvoegen zit in stap 3a)

---

## Later te beslissen

- App ook voor anderen? Dan: AH-voorwaarden, AVG (verwerking aankoopgegevens), API-kosten per gebruiker
- Ontwerp verfijnen in Claude Design
