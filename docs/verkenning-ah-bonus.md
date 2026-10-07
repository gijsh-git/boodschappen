# Verkenning AH-aanbiedingen (roadmap stap 1)

Gedraaid op 7 oktober 2026, bonusweek 5 t/m 11 oktober, naast 243 AH-bonnen van juli 2024 tot september 2026.

Opnieuw draaien:

```sh
cd scripts/ah-bonus && go run . ../../data/ah-bonus.json   # haalt de lopende bonusweek op
cd ../.. && python3 scripts/ah-bonus-vergelijken.py        # telt; --alles toont elke treffer
python3 scripts/ah-bonus-vergelijken.py --producten        # met de samengevoegde producten uit de database
```

De cijfers hieronder zijn zonder `--producten`: een product is daar de leesbare naam uit `data/ah-namen.json`, nog niet het samengevoegde product uit de database.

## Wat de AH-data is

- Ophalen werkt met een anoniem token, zonder account. Eén week is 25 verzoeken voor de categorieën en één per bonusgroep, samen ruim een minuut.
- 143 aanbiedingen: 118 groepen ("Alle Hak potten") en 25 losse artikelen. Samen 2423 artikelen, geen enkel artikel in twee aanbiedingen.
- Groepen zijn breed: de helft heeft meer dan 10 artikelen, de grootste 189 (Alle Verstegen).
- De korting komt als tekst ("1 + 1 GRATIS") én als label met een code en getallen. Negen codes deze week: X voor Y (38), percentage (35), vaste prijs (27), X+Y gratis (26), 2e halve prijs (7), bedrag korting (4), alleen "bonus" (3), staffel (2), per gewicht (2).
- Geldigheid staat per aanbieding en wijkt soms af van de week ("XL deals": 21 september t/m 18 oktober).
- Buiten beschouwing gelaten: Gall & Gall, Etos en "Online aanbiedingen".

## Het bon-ID is het hq_id

Elk artikel heeft twee ID's: `webshop_id` en `hq_id`. Het `product_id` op een kassabon is het `hq_id`. Van de 2423 artikelen heeft er één geen `hq_id`. De bonusdata geeft dus per artikel het paar bon-ID en webshop-ID, plus de volledige titel, het merk, de inhoud en de categorie.

Gevolg voor stap 2 en 3: er komt geen aparte vertaaltabel. Stap 2 slaat het bon-ID als `article_id` op bij de aankoop (een algemene naam, omdat `hq_id` alleen bij AH zo heet); de artikeltabel van stap 3 wordt elke week gevuld met de artikelen uit de bonus en is daarmee ook de vertaling van bon-ID naar artikel. Hij dekt alleen artikelen die ooit in de bonus zaten, maar voor het matchen van aanbiedingen is dat precies genoeg.

Bijvangst: het ID liet drie fouten in `data/ah-namen.json` zien, die daar verbeterd zijn. "AH SAKS" stond als saucijzenbroodjes en is Saksische smeerleverworst, "AH CLEMONT R" is rouge en geen rosé, "SUR EI SAL" is Surinaamse eiersalade en geen surimi. Aankopen die al met de oude naam zijn opgeslagen zijn niet aangepast.

## Hoeveel aanbiedingen raken iets wat we kopen

Vast product: minstens 3 aankoopdagen, de laatste binnen een jaar. Dat zijn er 107.

| | alles ooit gekocht | vaste producten |
|---|---|---|
| via ID (precies dat artikel) | 36 van 143 | 12 van 143 |
| via naam (naam staat in de titel) | 95 van 143 | 56 van 143 |
| alleen via ID | 2 | 1 |
| alleen via naam | 61 | 45 |

Van onze 634 bon-ID's zitten er deze week 56 in de bonus.

## Wat goed gaat

Via ID is elke treffer raak. Er zit geen enkele verkeerde koppeling tussen: courgette, broccoli, rundergehakt, zalmfilet, pistolets, Johma kip-kerrie, Doritos, Dr. Oetker Big Americans. Ook waar de bontekst niets zegt ("KIP KERRIE", "MAALTIJD", "SOURCY") weet het ID welk artikel het is.

## Wat fout gaat

**Via ID mis je het andere merk en het andere formaat.** Kwark kochten we 30 keer, onder zes ID's van AH en De Zaanse Hoeve. "Alle Campina kwark 500 gram 1+1 gratis" raakt geen van die zes. Hetzelfde bij Coca-Cola (wij kochten AH cola), broccoli 500 gram (wij kochten de losse), komkommer biologisch, aardappelen 3 kilo, Kadir frikandelbroodje. Volgens de productregel zijn dit juist de aanbiedingen die telt: het niveau waarop je wisselt. 106 van onze producten staan onder meer dan één bon-ID.

**Via naam is het grootste deel ruis.** Van de 85 treffers op vaste producten die alleen via de naam komen, zijn er ruwweg 15 terecht. De rest is een ingrediënt in iets anders: avocado in Nivea-douchegel, honing in thee en badschuim, paprika in chips, soep en crackers, cola in Haribo, komkommer in groentesap, limoen in allesreiniger. Ook varianten waar je niet tussen wisselt komen mee: plantaardige filet americain, Alpro-kwark, Hak spinazie uit pot naast verse.

**Brede groepen.** Wie één keer een potje Verstegen kocht, raakt "Alle Verstegen" (189 artikelen). Dat is geen kortingskans op iets wat we kopen. Een treffer zegt pas iets als het artikel in de groep bij een product hoort dat we vaak kopen.

## Wat dit zegt over de opzet

De opzet uit de roadmap klopt: aanbieding → artikel → product → profiel. De verkenning scherpt drie dingen aan.

1. **Het ID is de ruggengraat, het product is waar het om gaat.** Een aanbieding telt als een artikel erin bij een product hoort dat we kopen, niet alleen als we precies dat artikel kochten. Het bon-ID koppelt een artikel met zekerheid aan een product (wij kochten het, dus we weten de naam). Voor de andere artikelen is een koppeling artikel → product nodig.
2. **Die koppeling kan niet op de titel alleen.** De categorie van het artikel is het ontbrekende signaal: "kwark" in "Zuivel, eieren/Kwark" is kwark, "avocado" in "Drogisterij" niet. Het voorstel in stap 5 (AI volgens `docs/productregels.md`, beheerder keurt goed) moet de categorie meekrijgen, en de tabel met artikelen uit stap 3 moet titel, merk, inhoud en categorie bewaren.
3. **Niet alle 2400 artikelen per week hoeven een product.** Alleen de artikelen die kans maken bij een product dat iemand koopt of als favoriet heeft. Hoe die voorselectie gaat is een keuze voor stap 5.

Nog open: dezelfde telling met `--producten`, dus met de samengevoegde producten. Die zal via naam iets meer raken en verandert het beeld naar verwachting niet.
