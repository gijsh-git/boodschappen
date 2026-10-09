# Compacte lijst

Functioneel ontwerp, vastgesteld op 9 oktober 2026. Deel 5 (bonuspaneel) toegevoegd op dezelfde dag.

Probleem: op een telefoon passen nu 3 items op het scherm. De header neemt een kwart van het scherm in en elk item is een kaart van vier tot vijf regels. Doel: 8 tot 10 items zichtbaar, zonder dat het aantal minder opvalt. Het bonuspaneel heeft hetzelfde probleem.

Waar: het tabblad Lijst en het bonuspaneel ("Nu in de bonus").

## Uitgangspunten

- De lijst is voor gebruik in de winkel: vaak met één hand, en snel scannen.
- Op een item staat alleen wat je in de winkel nodig hebt: wat, hoeveel, waarvoor en tot wanneer de aanbieding loopt.
- Het aantal is het belangrijkste na de titel en moet beter opvallen dan nu.
- Geen informatie dubbel tonen.
- Varianten van één aanbieding blijven aparte items, zoals bewust is gekozen. Dat valt buiten dit ontwerp.

## Deel 1 – Header

- Ongeveer de helft lager dan nu. Lijstnaam ("Gijs & Els") in een kleiner corps, de avatars blijven.
- De uitnodigknop gaat naar het lijstmenu achter de pijl naast de lijstnaam.
- De groene banner wordt een smalle chip op één regel: "3 in de bonus bij AH". Tikken doet hetzelfde als nu.
- Geldt ook voor het bonuspaneel.

## Deel 2 – Invoer

- Het camera-icoon komt in het invoerveld zelf, rechts. De aparte regel "Foto toevoegen" vervalt.
- Het aantal-veld wordt smaller.

## Deel 3 – Item

Opbouw:

```
○ 2× Johma 100% plantaardige           2 voor 3,99
     kip-kerriesalade
     voor kipkerrie · t/m zo

○ 3× Hagelslag                                 (E)
```

- Geen losse kaarten meer, maar rijen met een scheidingslijn. Minder padding.
- Titel maximaal 2 regels in een kleiner corps, daarna afgekapt.

Aantal:

- Vóór de titel, in de oranje accentkleur en iets zwaarder dan de titel.
- Alleen getoond als het meer dan 1 is.
- Met eenheid op dezelfde manier: "500 g Gehakt", "2 pak Melk".
- De titel springt in onder het aantal, zodat de aantallen links in één kolom staan.

Metaregel:

- Eén regel: oorspronkelijke term en looptijd, bijvoorbeeld "voor soep · t/m zo".
- "door Gijs H · vandaag" vervalt.
- Geen term en geen aanbieding: geen metaregel. Het item is dan één regel hoog.
- Bij een "2 voor"-, "2e halve prijs"- of "1+1 gratis"-aanbieding met een aantal onder het benodigde komt de hint uit stap 7 in de metaregel: "voor soep · t/m zo · 2 nodig voor de korting".

Bonuslabel:

- Kleinere pill rechts, bijvoorbeeld "2 voor 7,00".
- "t/m zo" staat niet meer onder het label maar in de metaregel.

Wie het toevoegde:

- Zelf toegevoegd: niets.
- Door een ander lid toegevoegd: klein rondje met diens initiaal rechts, op de plek van het bonuslabel als er geen aanbieding is, anders eronder.

## Deel 4 – Afvinken en verwijderen

- Het bolletje blijft, kleiner (22 à 24 pt zichtbaar) met een groter tikvlak.
- Het kruisje vervalt.
- Swipe naar links verwijdert. Daarna een balk "Verwijderd · Ongedaan maken" van een paar seconden.
- Swipe naar rechts vinkt af, net als tikken op het bolletje.

## Deel 5 – Bonuspaneel

Aanbieding (ingeklapt):

```
Alle Johma 175 gram                    2 voor 3,99
voor kipkerrie · t/m zo
```

- Rijen met een scheidingslijn in plaats van kaarten, net als in de lijst.
- Het label staat rechts naast de titel, in dezelfde pill als in de lijst, niet op een eigen regel.
- Metaregel: oorspronkelijke term en looptijd. "Albert Heijn" vervalt, dat staat al in de chip.

Gekozen aanbieding:

```
Alle Johma 175 gram                    2 voor 3,99
voor kipkerrie · t/m zo
✓ Johma 100% plantaardige kip-…            Wissen
```

- De keuze op één regel met een vinkje, afgekapt als hij te lang is.
- "Wissen" als klein linkje rechts op dezelfde regel. De aparte regel "Keuze wissen" vervalt.

Aanbieding uitgeklapt (kiezen):

```
Alle Palmolive en Unicura handzeep     2 + 3 gratis
voor zeep · t/m zo
☐ Palmolive Naturals zeeptablet original
☐ Palmolive Naturals zeeptablet sensitive
☐ Unicura Balance tabletzeep
+ 19 andere artikelen
Niets aangevinkt = hele aanbieding
[Zet op de lijst (2)]  Annuleren
```

- De artikelen staan alleen als vinkjes, niet ook nog in de metaregel.
- Lagere vinkrijen.
- "Toon ook de 19 andere artikelen" wordt "+ 19 andere artikelen".
- De uitleg wordt één regel: "Niets aangevinkt = hele aanbieding".
- De knop toont het aantal aangevinkte artikelen: "Zet op de lijst (2)". Niets aangevinkt: "Zet op de lijst".

## Open voor het plan

- Wat doet tikken op het item zelf nu, en kan daar "toegevoegd door ... · vandaag" bij?
- Waar komt de initiaal precies als een item van een ander ook een bonuslabel heeft: onder het label of naast het aantal?
- Klapt de header in bij scrollen, of is de halve hoogte genoeg?
- Exacte maten (corps, padding) bepalen op een kleine iPhone (SE, mini) en op een grote.

## Klaar als

- op een iPhone van standaardformaat minstens 8 items van één à twee regels zichtbaar zijn met het toetsenbord dicht;
- "Johma kip-kerriesalade" met aantal 2 laat zien: "2×" in oranje vóór de titel, "voor kipkerrie · t/m zo" eronder en "2 voor 3,99" rechts;
- een item met aantal 1 geen aantal toont;
- een item dat Els toevoegde een "E" toont, en een item van mij niets;
- een item zonder term en aanbieding één regel hoog is;
- er geen kruisje meer is, swipen naar links verwijdert met "Ongedaan maken", en swipen naar rechts afvinkt;
- de regel "Foto toevoegen" weg is en het camera-icoon in het invoerveld zit;
- de bonusbanner één regel hoog is;
- in het bonuspaneel een ingeklapte aanbieding twee regels hoog is, met het label rechts naast de titel en zonder "Albert Heijn";
- een gekozen aanbieding de keuze en "Wissen" op één regel toont;
- bij een uitgeklapte aanbieding de artikelen niet ook in de metaregel staan, en de knop "Zet op de lijst (2)" toont bij twee vinkjes.
