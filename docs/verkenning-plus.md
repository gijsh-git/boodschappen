# Verkenning PLUS-aanbiedingen (roadmap stap 9, deel 0)

Gedraaid op 10 oktober 2026, de week van woensdag 7 t/m dinsdag 13 oktober. Alleen gelezen: er is niets in de database gezet en de app is niet veranderd.

Opnieuw draaien:

```sh
cd scripts/plus-aanbiedingen
go run . ../../data/plus-aanbiedingen.json                 # de lopende week, ruim een minuut
go run . -volgende ../../data/plus-aanbiedingen.json       # de volgende week, als die al gepubliceerd is
go run . -producten 40 ../../data/plus-aanbiedingen.json   # ook de productpagina van de eerste 40 artikelen; -1 is alle
```

## Waar de data vandaan komt

plus.nl is een OutSystems-app. De pagina `/aanbiedingen` haalt haar gegevens met JSON-calls op `/screenservices/…`. Drie daarvan zijn genoeg, alle drie zonder account en zonder winkelkeuze:

| Call | Geeft | Verzoeken |
|---|---|---|
| `DataActionGetPromotionList` | alle aanbiedingen van een week, per categorie | 1 |
| `DataActionPromotionOfferDetail_Get` | de artikelen van één groep | 1 per groep (160) |
| `DataActionGetProductDetailsAndAgeInfo` | de productpagina: EAN, inhoud als getal, prijs per kilo, categoriepad | 1 per artikel |

Wat er kwetsbaar aan is:

- Elke call vraagt twee versienummers: één van de hele site en één van de call zelf. Beide veranderen bij een nieuwe versie van de site. Het script leest ze daarom bij elke ronde uit de scripts van de site en heeft ze niet vast in de code staan.
- Een call stuurt de toestand van het scherm mee (een twintigtal velden zoals `IsDesktop` en `StoreNumber`). Verandert PLUS het scherm, dan verandert die lijst.
- De site zit achter Imperva. Vanaf de laptop kwam alles door met alleen de naam van een gewone browser. Vanaf GitHub ook: de taak "PLUS verkennen" gaf op 10 oktober dezelfde telling (206 aanbiedingen, 1498 artikelen, 20 productpagina's zonder fouten) in ruim twee minuten. Dat is één ronde; de beveiliging kan later strenger worden.
- Het antwoord is altijd met Brotli ingepakt, ook als je om gzip vraagt. Daarom is het script in Go met één bibliotheek erbij; Python zonder extra pakket kan het niet lezen.
- De week kies je met `PromotionPeriodId`: 1 is de lopende week, 2 de volgende. De schakelaar `IsNextWeekPromotions` doet op zichzelf niets. Met 0, wat de site zelf stuurt, kwam op zaterdag de volgende week terug.

## Wat er in een week zit

- **206 aanbiedingen**: 160 groepen en 46 losse artikelen. Daarnaast 8 keer "Gratis bezorging bij € 10 aan …"; dat is geen korting op een artikel en het script slaat ze over.
- **1498 artikelen**, geen enkel artikel in twee aanbiedingen.
- Groepen zijn kleiner dan bij AH: de helft heeft 5 artikelen of minder, 38 hebben er meer dan 10, 3 meer dan 50. De grootste is "PLUS Kies & Mix Tapas" (83).
- Eén groep heeft bij PLUS zelf geen pagina met artikelen (een tweede "Kies & Mix Tapas", nummer 4446-199). Die staat in het bestand met `mislukt` en zonder artikelen.
- De volgende week (14 t/m 20 oktober) stond er op zaterdag al: 197 aanbiedingen, zonder de 5 keer gratis bezorging. Volgens de site is die officieel zichtbaar vanaf maandag 12 oktober.

## Looptijd

De week loopt van **woensdag tot en met dinsdag**, niet van zondag tot en met zaterdag zoals in de roadmap stond. De looptijd staat per aanbieding en wijkt vaak af:

| Looptijd | Aantal | Wat |
|---|---|---|
| 7 t/m 13 oktober (de week) | 149 | |
| 7 t/m 20 oktober (twee weken) | 25 | sterke drank |
| 30 september t/m 24 november (acht weken) | 19 | "Kies & Mix" |
| één dag (11, 12 of 13 oktober) | 9 | dagaanbiedingen, drie per dag |
| 1 t/m 31 oktober | 2 | wijn van de maand |
| overig | 2 | |

Een aanbieding hoort bij een actie met een eigen nummer (4450 is deze week, 4486 de sterke drank, 4449 Kies & Mix). Het nummer van een groep is "actie-volgnummer", bijvoorbeeld `4450-135`. Een losse aanbieding heeft geen eigen nummer: daar is de slug van het artikel het nummer.

## Kortingsteksten

De korting komt alleen als tekst, in hoofdletters, zonder code of losse getallen zoals bij AH. Alle teksten van deze week vallen in zeven vaste vormen:

| Vorm | Voorbeeld | Deze week | Volgende week |
|---|---|---|---|
| alleen een actieprijs, geen tekst | (leeg), actieprijs 1.49, "Per pak" | 123 | 51 |
| X voor prijs | `2 VOOR 3.99` | 41 | 30 |
| percentage | `25 % KORTING` | 17 | 37 |
| bedrag korting | `4.00 KORTING` | 9 | 9 |
| per gewicht | `500 GRAM 1.00` | 8 | 6 |
| X+Y gratis | `1+1 GRATIS`, `2+3 GRATIS` | 6 | 63 |
| per kilo | `2.49 PER KILO` | 1 | 0 |
| 2e halve prijs | `2E HALVE PRIJS` | 1 | 1 |

- De verhouding verschilt sterk per week: deze week 6 keer "X+Y gratis", volgende week 63.
- Bij ruim de helft is er geen tekst, alleen een actieprijs met erbij waarvoor die geldt ("Per pak", "Per fles", "Per kilo"; bij 32 ook dat niet). Op de rij van een item toont de app nu de kortingstekst, en "Bonus" als die leeg is. Voor PLUS moet deel 1 zelf een tekst maken uit de actieprijs, anders staat er bij de helft alleen "Bonus".
- `nodigVoorKorting()` in `logica.js` begrijpt de vormen "2 VOOR 3.99", "1+1 GRATIS" en "2E HALVE PRIJS" al zoals PLUS ze schrijft.
- Er is een tweede label: "OP=OP" (13) en "VOORDEELVERPAKKING" (2). Bij 9 aanbiedingen krijg je extra spaarzegels.
- Het aantal stuks staat soms ook in de verpakking ("3 pakken", "2 flessen").

## Nummers

- **Webshopnummer** (`SKU`, zes cijfers): bij elk artikel. Dit wordt `article_id`.
- **EAN**: staat niet bij de aanbieding (het veld bestaat, maar is leeg), wel op de productpagina. Van de 40 geprobeerde artikelen hadden alle 40 een EAN van 13 cijfers. Het kost één verzoek per artikel: bij 1500 artikelen ongeveer tien minuten, daarna alleen voor artikelen die nieuw zijn.
- Bij een groep staat in de lijst ook een `Product_SKU`, maar dat nummer hoort er niet bij (hetzelfde nummer komt terug bij aanbiedingen die niets met elkaar te maken hebben). Het script gebruikt het alleen bij een losse aanbieding, waar het wel klopt.
- Een bon van PLUS komt binnen via een foto en heeft geen artikelnummer. Een koppeling tussen een AH-artikel en een PLUS-artikel is er nu niet: de AH-data heeft geen EAN.

## Artikelgegevens

- **Prijs**: elk van de 1498 artikelen heeft een gewone prijs. 982 hebben ook een actieprijs per stuk, en die is altijd lager. Bij "X voor prijs" en "X+Y gratis" is er geen actieprijs per stuk.
- **Merk**: bij elk artikel, 172 merken. Het huismerk bestaat uit meer merken: "PLUS" (351 artikelen), "PLUS Korenlanders" (58), "PLUS Boerentrots" (28), "PLUS Puur van smaak" (13), "PLUS Klaverland" (9), "Biologisch PLUS" (6). Een merkfavoriet "PLUS" raakt dus niet vanzelf het brood van PLUS Korenlanders.
- Het merk van een **aanbieding** is geen merk maar het begin van de titel: "Alle Licor 43, Tia Maria en" + "Disaronno". De titel van een aanbieding is daarom merk en naam achter elkaar; alleen het merk van een artikel is bruikbaar.
- **Inhoud**: goed leesbaar. 1455 van de 1498 als getal met eenheid ("500 g", "1000 ml", "16 st"); de andere 43 voluit ("500 gram", "kilo"), bij vers per gewicht. Een meerpak staat als totaal ("1800 ml"), nooit als "6 x 300 ml". Bij een losse aanbieding staat de inhoud alleen in de slug (`plus-spruiten-zak-750-g-188088`); dat lukte bij alle 46.
- De productpagina geeft de inhoud ook als los getal en eenheid (750, g), met de gewone prijs per kilo, liter of stuk. Dat is wat deel 4 nodig heeft.

## Categorieën

- Een aanbieding staat in één van 17 hoofdcategorieën ("Zuivel, eieren, boter"). De indeling lijkt op die van AH, maar is niet dezelfde. Soms is het een thema in plaats van een productgroep: "Gratis bezorging", en volgende week "Inslaan!" en "Bewuste voeding".
- Een artikel in een groep heeft alleen de diepste categorie ("Zuiveldranken", "Toiletpapier"): 199 verschillende. Een los artikel heeft alleen de hoofdcategorie van de aanbieding.
- De productpagina geeft het hele pad ("Aardappelen, groente, fruit/Groente/Broccoli, spruiten, koolsoorten"). Bij een deel van de artikelen staan daar seizoenspaden achter ("…/Kerstassortiment/Kerstontbijt…"). Alleen de eerste drie niveaus zijn de vaste indeling.
- Voor de AI die een type kiest is de diepste categorie plus de hoofdcategorie van de aanbieding genoeg.

## Lokale aanbiedingen en winkels

- Zonder winkelkeuze komen er geen lokale aanbiedingen mee: de lijst met winkels is bij elke aanbieding leeg en geen enkel artikel is gemerkt als lokaal. De bron vraagt dus niet om een winkel; er hoeft er geen gekozen te worden.
- "Alleen in de winkel" is er wel: 4 aanbiedingen en 82 artikelen, allemaal sterke drank die PLUS niet bezorgt. Dat is `store_only`.
- Niet uitgezocht: wat er verandert als je wel een winkel meegeeft.

## Bonnen: wat er in `receipts.store` staat

In de back-up van 7 oktober 2026 staan 240 bonnen, alle 240 met `AH`. Er is nog geen PLUS-bon en er is geen andere schrijfwijze die rechtgezet moet worden. `bon-uploaden` geeft "AH" en "PLUS" als code, en de matching vergelijkt met `upper(btrim(store))`, dus "Plus" of " PLUS" zou ook goed gaan. De stand van nu controleer je in de SQL-editor met:

```sql
select store, count(*) from receipts group by store order by 2 desc;
```

## Wat dit zegt over de opzet

De opzet van stap 9 klopt. De verkenning scherpt deze dingen aan:

1. **De week is woensdag t/m dinsdag.** De taak voor PLUS draait dus op woensdagochtend, met een tweede ronde later in de week. De volgende week is er al een paar dagen eerder.
2. **De productpagina is de bron voor EAN en hoeveelheid.** De aanbieding zelf geeft genoeg voor matchen en classificeren (titel, merk, inhoud als tekst, categorie, prijs). EAN en de inhoud als getal kosten één verzoek per artikel. Het opslagscript weet niet welke artikelen nieuw zijn, dus dat vraagt in deel 1 een keuze: elke week alle 1500, of eerst vragen welke de database al kent.
3. **PLUS heeft geen labels met getallen.** De korting in één vorm (deel 4) komt bij PLUS uit de tekst. Dat kan: zeven vaste vormen.
4. **Een lege kortingstekst is bij PLUS de gewone gang van zaken.** Deel 1 maakt er een tekst van ("1.49" of "voor 1.49").
5. **Dagaanbiedingen bestaan.** De looptijd staat al per aanbieding, dus dat werkt; ze zijn alleen zichtbaar op die ene dag.
6. **Het huismerk is een familie van merken**, zie hierboven.

## Besloten na de verkenning

- De PLUS-week komt binnen via GitHub Actions, net als AH: de proef vanaf GitHub slaagde.
- De korting in één vorm komt pas in deel 4. De teksten zijn regelmatig, `nodigVoorKorting()` leest ze al, en omdat de tekst wordt opgeslagen kan het omzetten later zonder opnieuw op te halen.
- De productpagina wordt alleen opgehaald voor artikelen die de database nog niet kent.
