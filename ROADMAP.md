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

### [ ] 3 – Aankoopprofiel op Mijn profiel

```
/plan
Wat: mijn aankoopprofiel tonen op de pagina Mijn profiel.
Waarom: ik wil zien wat de app over mijn koopgedrag weet en controleren of dat klopt; later de basis voor kortingsadvies.
Hoe het moet werken:
- Sectie "Mijn aankoopprofiel" op Mijn profiel.
- Periode: laatste 4 weken, 3 maanden, 12 maanden, alles.
- Filter: alle lijsten, of één specifieke lijst.
- Kerncijfers: aantal aankopen, aantal verschillende producten, totaal uitgegeven en bespaard (waar prijzen bekend zijn).
- Top 10 producten met hoe vaak en gemiddeld om de hoeveel dagen.
- Verdeling per supermarkt en uitgaven per maand als eenvoudige staafjes.
- Kort uitlegtekstje per onderdeel.
Klaar als: de cijfers kloppen met Supabase en filters en periodes werken.
Grenzen: alleen aankopen uit lijsten waarvan ik deelnemer ben en die meetellen voor het profiel (ook gearchiveerde). Reken in de database. Geen grafiekbibliotheek. Goed leesbaar op een telefoon.
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
- [ ] Profiel corrigeren: product uit profiel halen, producten samenvoegen

---

## Later te beslissen

- App ook voor anderen? Dan: AH-voorwaarden, AVG (verwerking aankoopgegevens), API-kosten per gebruiker
- Ontwerp verfijnen in Claude Design
