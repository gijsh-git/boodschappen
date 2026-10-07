# Productregels

Dit bestand beschrijft hoe productnamen in BonusBuddy aan producten worden gekoppeld. Het wordt gebruikt als instructie voor de automatische herkenning (AI-voorstellen) en voor voorstellen tot samenvoegen.

## Doel

Een product is het niveau waarop het aankoopprofiel rekent en waarop kortingen worden voorgesteld. Als iemand vaak een product koopt, moet elke aanbieding binnen dat product relevant zijn.

## Hoofdregel

Een product is het niveau waarop een koper wisselt bij een aanbieding.

Toets: zou je bij een aanbieding het ene voor het andere kopen? Zo ja, dan is het hetzelfde product. Zo nee, dan blijft het apart.

Bij twijfel: samenvoegen. Te ruim samenvoegen kost hooguit een irrelevante aanbieding; te streng betekent dat relevante aanbiedingen worden gemist. Samenvoegen is altijd terug te draaien.

## Wel samenvoegen

- Schrijfwijze en tikfouten: "kip-kerriesalade" en "kipkerriesalade".
- Enkelvoud en meervoud: "limoenen" en "limoen".
- Synoniemen: "wraps" en "tortilla's", "baguette" en "stokbrood", "fanta" en "sinas".
- Merken van hetzelfde soort product: "dr. oetker pizza" onder "pizza", "lay's chips" onder "chips", "heineken bier" onder "bier".
- Smaken en soorten binnen hetzelfde product: pizza margherita onder "pizza", skyr aardbei onder "skyr", lipton raspberry ice tea onder "ice tea".
- Vorm en snit: penne en rigatoni onder "pasta", kipdijreepjes onder "kipdijfilet", kaas in plakken onder "kaas".
- Rassen en variëteiten: elstar en pink lady onder "appels", trostomaten onder "tomaten", basmati onder "rijst".
- Biologisch en gewoon: biologische komkommer onder "komkommer".
- Huismerken van supermarkten (AH, Jumbo, Plus, g'woon): worden al bij normalisatie weggehaald.
- Verpakking, formaat en "wit" bij brood: "mayonaise knijpfles" onder "mayonaise", "petit stokbrood wit" onder "stokbrood".
- Verpakkingstekst van de supermarkt: "vers belegd broodje carpaccio" onder "belegd broodje".

## Apart houden

- Varianten waar je niet tussen wisselt: halfvolle, volle en gewone melk; cola en cola zero; chocolademelk en chocomel 0%.
- Alcoholvrij en gemengd tegenover gewoon: amstel 0.0, desperados en radler apart van "bier"; rosé apart van "witte wijn".
- Pils tegenover speciaalbier: bokbier, tripel, IPA en witbier zijn "speciaalbier", apart van "bier".
- Producten voor een ander moment of gebruik: gesneden brood (ontbijt), stokbrood (maaltijd), afbakbroodjes, naanbrood; risottorijst apart van "rijst".
- Producten die alleen in je eigen apparaat werken: koffiebonen, koffiecapsules en koffiepads.
- Andere vorm van hetzelfde doel: eiwitpoeder apart van "eiwitdrank".
- Sauzen met een eigen smaak of gebruik (knorr saus, maggi saus, groentesaus, woksaus) blijven apart.
- Beleg is geen brood: "kip voor op brood" is beleg.
- Een losse merknaam zonder product ("zaanse hoeve", "melkunie", "sempio", "thai thai") wordt niet samengevoegd; die krijgt eerst een echte naam via data/ah-namen.json.

## Geen boodschappen

Producten als draagtas, plastic zak, kleding, sportartikelen, wenskaarten en toilettassen krijgen de vlag "telt niet mee in profiel". Ze tellen wel mee in totaal uitgegeven.

## Vastgestelde producten

### brood

Alle gesneden broden voor ontbijt of lunch, ongeacht soort, kleur of merk: tijger-, vloer-, volkoren-, waldkorn-, schnitt- en zaans brood, en bakkersbroden als batard, boulogne, bastille, fourchette, matisse, triomphe, robuust en steenoven spelt. Niet: stokbrood, afbakbroodjes, belegde broodjes, hartige broodjes, zoet brood, naanbrood.

### stokbrood

Stokbrood en baguette in elk formaat en elke kleur.

### afbakbroodjes

Pistolets (wit, bruin, volkoren), kaiserbroodjes en kampioentjes.

### pizza

Alle pizza's, ongeacht merk of smaak. Mini pizza's, pizza kit en pizza donut zijn (nog) apart.

### kwark

Alle kwark, ongeacht merk, vetgehalte of smaak: danio, lindahls, optimel, magere kwark.

### yoghurt

Alle yoghurt, ongeacht merk of vetgehalte. Skyr en drinkyoghurt zijn aparte producten.

### eiwitdrank

Alle kant-en-klare eiwitdranken en -shakes, ongeacht merk of smaak: hipro, xxl nutrition, melkunie protein.

### bier

Pils, ongeacht merk of verpakking (blik, fles, krat, fust). Niet: speciaalbier, alcoholvrij, radler, desperados.

### speciaalbier

Bier dat geen pils is, ongeacht merk: blond, bokbier, dubbel, tripel, quadrupel, IPA, witbier, weizen en zwaar bier. Wie pils koopt wisselt daar bij een aanbieding niet naar. Als lijstnaam is de eerste naam "speciaalbier", daarna de soort ("bokbier", "tripel"); niet "bier". Alcoholvrij speciaalbier valt onder alcoholvrij, niet hieronder.

### witte wijn

Witte wijn, ongeacht druif of merk. Rosé is apart.

### melk

"melk" en "biologische melk" vormen één product. Halfvolle en volle melk zijn aparte producten.

### pasta

Alle gedroogde pasta, ongeacht vorm, merk of biologisch: penne, rigatoni, schelpenpasta. Ravioli is apart.

### rijst

Rijst, pandan rijst en basmatirijst. Risottorijst is apart.

### tomaten

Tomaten, trostomaten en vleestomaten. Cherrytomaten (met romaatjes) zijn een apart product, net als tomatenblokjes en passata.

### kaas

Kaas aan het stuk of in plakken, ongeacht merk of leeftijd: goudse plakken, old amsterdam, tostikaas. Geraspte kaas (met pizzakaas) is apart.

### skyr

Alle skyr, ongeacht merk of smaak.

### chips

Alle chips, ongeacht merk of soort: lay's, chio. Ribbelchips, doritos, pringles en cheetos zijn (nog) apart.

### ice tea

Alle ice tea, ongeacht merk of smaak: lipton, fuze tea.

### water

Water zonder koolzuur, ongeacht merk. Koolzuurhoudend water is apart.

### appels

Alle appels, ongeacht ras: elstar, granny smith, pink lady.

### eieren

Eieren en scharreleieren.

### kipfilet en kipdijfilet

Twee producten. Onder "kipfilet": biologische kipfilet, blokjes en haasjes. Onder "kipdijfilet": kipdijreepjes.

### belegd broodje

Kant-en-klare belegde broodjes, ongeacht beleg: carpaccio, caprese, kip pesto.

### hartig broodje

Warme hartige broodjes uit de bakkerij: frikandel-, kaas-, kaas-ui-, pizza-, saucijzen- en worstenbroodje.

### zoet brood

Krenten-rozijnenbrood, rozijnenbol en rozijnen-krentenbol.

## Artikelen koppelen

Een artikel van een supermarkt (uit de aanbiedingen) hoort bij hooguit één product. Dat is geen samenvoegen: er verandert niets aan de producten en hun namen.

Besluiten (7 oktober 2026):

1. Staat het artikelnummer op een eigen bon, dan zegt de bon bij welk product het hoort. Dat wint altijd: voor zo'n artikel wordt niets voorgesteld en een eerdere koppeling telt niet meer.
2. Voor de andere artikelen doet `scripts/artikel-voorstellen.py` een voorstel. Kandidaten zijn alle producten met minstens één aankoop of een item op een lijst, van alle huishoudens.
3. Vaste regel, vóór de AI: is de subcategorie van het artikel gelijk aan de naam van een product ("Pompoen" en "pompoen"), dan is dat het voorstel, met zekerheid hoog. De subcategorie is het deel na de "/" in de categorie, of de hele categorie als er geen "/" in staat.
4. De rest beoordeelt de AI met dit bestand: een product of geen product, de zekerheid (hoog, middel, laag) en een korte reden. Dezelfde toets als bij samenvoegen: zou je bij een aanbieding dit artikel kopen in plaats van wat je gewoonlijk koopt?
5. Een woord uit de productnaam in de titel is geen bewijs. Pompoensoep en desembrood met pompoen horen niet bij "pompoen".
6. Niets wordt automatisch goedgekeurd, ook niet bij zekerheid hoog. De beheerder keurt goed of wijst af in het scherm Producten. Voorstellen met zekerheid laag staan apart als twijfelgevallen en vallen buiten "alles goedkeuren".
7. Een afwijzing geldt voor de combinatie van artikel en product. Die wordt nooit opnieuw voorgesteld; hetzelfde artikel mag later wel bij een ander product worden voorgesteld. Een goedgekeurde koppeling losmaken telt als afwijzen.
8. Een artikel met "geen product" wordt opnieuw beoordeeld als er sindsdien producten zijn bijgekomen, en dan alleen tegen die nieuwe producten.
9. Bij het samenvoegen van producten verhuizen de koppelingen, voorstellen en afwijzingen van de bron naar het doel. Losmaken zet terug wat van de bron kwam; wat daarna op het doel is goedgekeurd blijft bij het doel.

## Lijstnamen

Naast het voorstel legt het script bij elk artikel hooguit drie lijstnamen vast: de namen die iemand op een boodschappenlijst zou typen. Daarmee krijgt een item het Bonus-label ook als het product nog niet bestaat ("andijvie" voor het eerst op de lijst).

Besluiten (7 oktober 2026):

1. De eerste naam is het product volgens dit bestand, het niveau waarop je wisselt: "pizza" voor elke pizza, "kipfilet" voor kipfiletreepjes. Varianten waar je niet tussen wisselt krijgen hun eigen naam ("cola zero", "halfvolle melk").
2. Daarna hooguit twee specifiekere namen of een gangbaar synoniem, alleen als mensen dat ook zo opschrijven: "magere kwark", "baguette" naast "stokbrood".
3. In de vorm die mensen typen: kleine letters, meervoud waar dat gebruikelijk is ("eieren", "tomaten"), zonder merk, huismerk, inhoud of verpakking. Een merk alleen als mensen het product zo noemen ("nutella").
4. Een item krijgt het label als zijn naam na Nederlandse stamming gelijk is aan een lijstnaam van een artikel in een geldige aanbieding. Het gaat om de hele naam: "melk" raakt "halfvolle melk" niet.
5. Hiervoor is geen goedkeuring nodig en er worden geen producten voor aangemaakt. Het geldt alleen voor het label op de lijst; Voor jou werkt alleen via de bon en de goedgekeurde koppelingen.
6. Bij een artikel waar de vaste regel aanslaat (subcategorie gelijk aan de productnaam) is de productnaam de enige lijstnaam.

## Werkwijze

1. Een onbekende naam wordt eerst een eigen product.
2. De AI doet een voorstel op basis van dit bestand, met zekerheid en reden.
3. De beheerder keurt goed of af. Niets wordt automatisch samengevoegd.
4. Nieuwe beslissingen worden in dit bestand vastgelegd onder "Vastgestelde producten".
