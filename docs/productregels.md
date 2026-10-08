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
- Synoniemen: "wraps" en "tortilla's", "baguette" en "stokbrood", "fanta" en "sinas", "roerbakgroente" en "wokgroente".
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
- Zero, light, suikervrij, 0%, decaf en alcoholvrij tegenover de gewone variant, bij elk soort product en elk merk: fanta zero apart van "sinas", slimpie (siroop 0% suiker) apart van "siroop", ketchup zero en ketchup "zero added sugar" apart van "ketchup", salsa "zero added sugar" apart van "salsa", decaf apart van koffie, radler 0.0 apart van "radler". Ook als het huishouden de variant zelf niet koopt: een ander huishouden doet dat misschien wel.
- Alcoholvrij en gemengd tegenover gewoon: amstel 0.0, desperados en radler apart van "bier"; rosé apart van "witte wijn".
- Pils tegenover speciaalbier: bokbier, tripel, IPA, witbier en witpils zijn "speciaalbier", apart van "bier".
- Producten voor een ander moment of gebruik: gesneden brood (ontbijt), stokbrood (maaltijd), afbakbroodjes, naanbrood; risottorijst apart van "rijst".
- Producten die alleen in je eigen apparaat of systeem werken: koffiebonen, koffiecapsules en koffiepads; systeemscheermesjes per systeem (Mach3, Fusion5, ProGlide, Labs, Venus) en wegwerpscheermesjes; Swiffer-doekjes en -dusters; een fust voor een eigen tap (Blade). Het apparaat zelf, een handvat of een starterset hoort bij geen enkel product.
- Vers tegenover gedroogd of uit pot of blik: "verse basilicum" apart van gedroogde "basilicum", Hak sperziebonen en spinazie uit de pot apart van verse "sperziebonen" en "spinazie". Een product zonder "vers" of "gedroogd" in de naam is vers, tenzij hieronder bij Vastgestelde producten anders staat.
- Andere vorm van hetzelfde doel: eiwitpoeder apart van "eiwitdrank".
- Sauzen met een eigen smaak of gebruik (knorr saus, maggi saus, groentesaus, woksaus) blijven apart. Hetzelfde geldt voor specerijmengsels met een eigen smaak (garam masala, za'atar, ras el hanout, world spice blends): die zijn geen "kruidenmix".
- Drop tegenover gums en winegums: zoute en zoete drop horen niet bij "snoep".
- Beleg is geen brood: "kip voor op brood" is beleg.
- Een losse merknaam zonder product ("zaanse hoeve", "melkunie", "sempio", "thai thai") wordt niet samengevoegd; die krijgt eerst een echte naam via data/ah-namen.json.
- Een productnaam is de soort, niet het merk: "handzeep", niet "palmolive handzeep"; "snoep", niet "haribo snoep"; "kruiden", niet "verstegen kruiden". Een merk in de productnaam trekt voorstellen naar dat merk in plaats van naar de soort. Zo'n product wordt hernoemd of samengevoegd met het product van de soort.

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

Pils, ongeacht merk of verpakking (blik, fles, krat). Niet: speciaalbier (ook sterk of zwaar bier als Grolsch Krachtig Kanon, en witpils), alcoholvrij, radler, desperados, en een fust dat alleen in een eigen tap past (Heineken Blade).

### radler

Radler met alcohol, ongeacht merk of smaak. Radler 0.0 is alcoholvrij en apart.

### speciaalbier

Bier dat geen pils is, ongeacht merk: blond, bokbier, dubbel, tripel, quadrupel, IPA, witbier, witpils, weizen en zwaar bier. Wie pils koopt wisselt daar bij een aanbieding niet naar. Als lijstnaam is de eerste naam "speciaalbier", daarna de soort ("bokbier", "tripel"); niet "bier". Alcoholvrij speciaalbier valt onder alcoholvrij, niet hieronder.

### sinas

Sinaasappelfrisdrank met suiker, ongeacht merk: fanta orange, sisi. Niet: fanta zero, en andere smaken als fanta exotic of pineapple grapefruit, ook al zet de supermarkt ze onder "Sinas".

### siroop

Limonadesiroop met suiker, ongeacht merk of smaak. Siroop 0% suiker (slimpie) is apart.

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

### snoep

Gums, winegums, schuimpjes, spekken en zure snoep in een zak, ongeacht merk: haribo, look-o-look, maoam. Niet: drop.

### scheermesjes

Wegwerpscheermesjes. Systeemmesjes en handvatten (Mach3, Fusion5, ProGlide, Labs, Venus) zijn apart, per systeem.

### doekjes

Vochtige schoonmaakdoekjes, ongeacht merk of geur: dettol, ajax, dubro. Niet: Swiffer-vloerdoekjes en -dusters (eigen systeem), zakdoekjes.

### basilicum en bieslook

Gedroogd, uit een potje of zakje. Verse basilicum is het aparte product "verse basilicum".

### kruiden en kruidenmix

Twee producten, beide zonder merk in de naam, zodat elk merk eronder valt (Verstegen, AH, Euroma, Jonnie Boer).

"kruidenmix": alle mixen voor een gerecht of een vleessoort, in een zakje of strooibus: bami, nasi, chili con carne, stamppot, pasta bolognese, en vlees-, vis-, aardappel- en Italiaanse kruiden (kip pittige knoflook, speklapjes, stoofvlees, gehakt). Niet: specerijmengsels met een eigen smaak (world spice blends, garam masala).

"kruiden": losse kruiden en specerijen: peperkorrels, paprikapoeder. Bestaat er voor een kruid een eigen product (oregano, basilicum, bieslook, nootmuskaat), dan hoort het artikel daar.

### halvarine

Halvarine, margarine en plantaardige smeersels voor op brood, ongeacht merk: blue band, bona. "smeerbare boter" is boter en apart.

### sperziebonen, spinazie en boerenkool

Vers. Groente uit een pot (Hak) hoort er niet bij.

## Artikelen koppelen

Een artikel van een supermarkt (uit de aanbiedingen) hoort bij hooguit één product. Dat is geen samenvoegen: er verandert niets aan de producten en hun namen.

Besluiten (7 oktober 2026):

1. Staat het artikelnummer op een eigen bon, dan zegt de bon bij welk product het hoort. Dat wint altijd: voor zo'n artikel wordt niets voorgesteld en een eerdere koppeling telt niet meer.
2. Voor de andere artikelen doet `scripts/artikel-voorstellen.py` een voorstel. Kandidaten zijn alle producten met minstens één aankoop of een item op een lijst, van alle huishoudens.
3. Vaste regel, vóór de AI: is de subcategorie van het artikel gelijk aan de naam van een product ("Pompoen" en "pompoen"), dan is dat het voorstel, met zekerheid hoog. De subcategorie is het deel na de "/" in de categorie, of de hele categorie als er geen "/" in staat. Uitzondering (8 oktober 2026): noemt de titel een variant waar je niet tussen wisselt (zero, light, 0.0, 0%, decaf, alcoholvrij, suikervrij) of is het een starterset, dan beslist de AI.
4. De rest beoordeelt de AI met dit bestand: een product of geen product, de zekerheid (hoog, middel, laag) en een korte reden. Dezelfde toets als bij samenvoegen: zou je bij een aanbieding dit artikel kopen in plaats van wat je gewoonlijk koopt?
5. Een woord uit de productnaam in de titel is geen bewijs. Pompoensoep en desembrood met pompoen horen niet bij "pompoen".
6. Niets wordt automatisch goedgekeurd, ook niet bij zekerheid hoog. De beheerder keurt goed of wijst af in het scherm Producten. Voorstellen met zekerheid laag staan apart als twijfelgevallen en vallen buiten "alles goedkeuren".
7. Een afwijzing geldt voor de combinatie van artikel en product. Die wordt nooit opnieuw voorgesteld; hetzelfde artikel mag later wel bij een ander product worden voorgesteld. Een goedgekeurde koppeling losmaken telt als afwijzen.
8. Een artikel met "geen product" wordt opnieuw beoordeeld als er sindsdien producten zijn bijgekomen, en dan alleen tegen die nieuwe producten.
9. Bij het samenvoegen van producten verhuizen de koppelingen, voorstellen en afwijzingen van de bron naar het doel. Losmaken zet terug wat van de bron kwam; wat daarna op het doel is goedgekeurd blijft bij het doel.

Besluiten (8 oktober 2026), na het nalezen van alle oordelen:

10. De categorie van de supermarkt helpt, maar is geen bewijs. AH zet multipacks speciaalbier soms onder "Pils blik" en fanta exotic onder "Sinas". Wat de titel zegt, gaat voor.
11. De meeste fouten zaten in voorstellen met zekerheid middel en in de vaste regel. Lees die na voordat je "alles goedkeuren" gebruikt.
12. De correcties van dit nalezen staan in scripts/koppelingen-corrigeren.py.

## Lijstnamen

Naast het voorstel legt het script bij elk artikel hooguit drie lijstnamen vast: de namen die iemand op een boodschappenlijst zou typen. Daarmee krijgt een item het Bonus-label ook als het product nog niet bestaat ("andijvie" voor het eerst op de lijst).

Besluiten (7 oktober 2026):

1. De eerste naam is het product volgens dit bestand, het niveau waarop je wisselt: "pizza" voor elke pizza, "kipfilet" voor kipfiletreepjes. Varianten waar je niet tussen wisselt krijgen hun eigen naam ("cola zero", "halfvolle melk").
2. Daarna hooguit twee specifiekere namen of een gangbaar synoniem, alleen als mensen dat ook zo opschrijven: "magere kwark", "baguette" naast "stokbrood".
3. In de vorm die mensen typen: kleine letters, meervoud waar dat gebruikelijk is ("eieren", "tomaten"), zonder merk, huismerk, inhoud of verpakking. Een merk alleen als mensen het product zo noemen ("nutella").
4. Een item krijgt het label als zijn naam na Nederlandse stamming gelijk is aan een lijstnaam van een artikel in een geldige aanbieding. Het gaat om de hele naam: "melk" raakt "halfvolle melk" niet. Sinds 8 oktober 2026 is dit laag 1 van "Matchen van lijsttermen" hieronder.
5. Hiervoor is geen goedkeuring nodig en er worden geen producten voor aangemaakt. Het geldt alleen voor het label op de lijst; Voor jou werkt alleen via de bon en de goedgekeurde koppelingen.
6. Bij een artikel waar de vaste regel aanslaat (subcategorie gelijk aan de productnaam) is de productnaam de enige lijstnaam.

## Matchen van lijsttermen

Wat iemand op de lijst typt is niet altijd de naam van een product of een lijstnaam: "proteine drank" met een spatie, "chocola", "tandenpasta", of een merk als "nivea". Voor het Bonus-label gaat een term daarom door vijf lagen; de eerste die iets oplevert telt.

Besluiten (8 oktober 2026):

1. Exact: gelijk aan een naam van een product, of gelijk aan een lijstnaam. Gelijk is: dezelfde letters en cijfers zonder spaties, koppeltekens en accenten ("proteine drank" is "proteinedrank"), of gelijk na stamming ("tomaat" is "tomaten").
2. Synoniem: de term staat voor een andere naam ("chocola" voor "chocolade"), vastgelegd in `term_synonyms` met de bron (`manual` of `ai`) en de datum. Het doel is een lijstnaam of een productnaam.
3. Merk: de term is het merk van een artikel ("nivea", "oral b").
4. Tolerant: de term lijkt genoeg op een lijstnaam of een merk. Alleen de best gelijkende telt, vanaf 55 procent gelijkenis (`fuzzy_min_similarity_pct` in `settings`) en vanaf 5 tekens.
5. Titel: alle woorden van de term staan in het merk en de titel van een artikel ("sensodyne tandpasta"). Dit is de minst precieze laag en komt daarom als laatste, en alleen bij een term van minstens twee woorden: een los woord in een titel zegt te weinig ("gember" raakte een groentesap, "boter" een smeerkaas, "suiker" pecannoten).
6. Een synoniem is geen samenvoeging. Samenvoegen zegt dat twee namen hetzelfde product zijn, ook in het aankoopprofiel, en doet alleen de beheerder. Een synoniem telt alleen voor het label: een fout kost hooguit een label bij iets wat je toch al wilde kopen. Spelfouten die ook gekocht worden, voeg je nog steeds samen.
7. De lagen 2 tot en met 5 gelden alleen voor het label op de lijst. Voor jou werkt alleen via de bon en de goedgekeurde koppelingen.
8. Een term die na alle lagen niets oplevert, komt in `unmatched_terms` (alleen de term, hoe vaak en wanneer; geen gebruiker of lijst). "Niets" gaat over alle artikelen die ooit in een aanbieding zaten: een bekende term zonder aanbieding deze week is niet onbekend.
9. Nog niet gebouwd: een AI-stap die de termen uit `unmatched_terms` aan een naam koppelt en dat als synoniem met bron `ai` opslaat.

Controleren kan met `docs/matching-controle.sql`.

## Aanbieding op de lijst

Wie op Voor jou een aanbieding op de lijst zet, krijgt de titel van die aanbieding als naam van het item ("AH Bakkersbrood tijgerbrood volkoren heel"), niet de naam van het product ("brood").

Besluiten (8 oktober 2026):

1. Het item onthoudt de aanbieding, het artikel (alleen als de aanbieding precies één artikel heeft) en het product uit de catalogus op dat moment. De naam verandert daarna niet meer mee met de titel of de productnaam.
2. De titel wordt een naam van het catalogusproduct, zodat het aankoopprofiel en het Bonus-label op dat product blijven werken. Dat gebeurt alleen als alle gekoppelde artikelen in de aanbieding bij hetzelfde product horen (via de bon of een goedgekeurde koppeling) en de titel nog geen naam van een product was.
3. Dit is de enige samenvoeging zonder de beheerder. Het doel komt uit koppelingen die al vaststaan, en ze staat tussen de samenvoegingen, dus losmaken kan.
4. Horen de artikelen bij geen of bij meerdere producten ("Alle AH Bakkersbrood" met brood en stokbrood), dan krijgt de titel een eigen product, zoals elke nieuwe naam.
5. Staat er al een item van hetzelfde product op de lijst, dan komt het nieuwe er los bij.

## Werkwijze

1. Een onbekende naam wordt eerst een eigen product.
2. De AI doet een voorstel op basis van dit bestand, met zekerheid en reden.
3. De beheerder keurt goed of af. Niets wordt automatisch samengevoegd, behalve de titel van een aanbieding die vanuit Voor jou op de lijst komt (zie "Aanbieding op de lijst").
4. Nieuwe beslissingen worden in dit bestand vastgelegd onder "Vastgestelde producten".
