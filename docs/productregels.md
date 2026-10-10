# Productregels

Dit bestand beschrijft op welk niveau BonusBuddy producten indeelt. Sinds 9 oktober 2026 heet dat niveau een producttype: een vaste lijst in de database, waar de AI artikelen, getypte termen en aankopen zelf aan koppelt. Waar hieronder "product" staat, is dat hetzelfde als een type, en "samenvoegen" betekent: het is hetzelfde type. De regels zijn de maatstaf voor wie de typelijst en de koppelingen nakijkt (Profiel > Koppelingen beheren); de kern ervan staat ook in de opdracht aan de AI in de Edge Functions `artikelen-classificeren` en `term-classificeren`. Wijzig je hier een regel, pas die opdrachten dan ook aan.

## Doel

Een product is het niveau waarop het aankoopprofiel rekent en waarop kortingen worden voorgesteld. Als iemand vaak een product koopt, moet elke aanbieding binnen dat product relevant zijn.

## Hoofdregel

Een product is het niveau waarop een koper wisselt bij een aanbieding.

Toets: zou je bij een aanbieding het ene voor het andere kopen? Zo ja, dan is het hetzelfde product. Zo nee, dan blijft het apart.

Bij twijfel: hetzelfde type. Te ruim kost hooguit een irrelevante aanbieding; te streng betekent dat relevante aanbiedingen worden gemist. Let op: twee types samenvoegen in het scherm is niet terug te draaien; een type weer splitsen betekent een nieuw type aanmaken en de artikelen opnieuw laten beoordelen.

## Wel samenvoegen

- Schrijfwijze en tikfouten: "kip-kerriesalade" en "kipkerriesalade".
- Enkelvoud en meervoud: "limoenen" en "limoen".
- Synoniemen: "wraps" en "tortilla's", "baguette" en "stokbrood", "fanta" en "sinas", "roerbakgroente" en "wokgroente".
- Merken van hetzelfde soort product: "dr. oetker pizza" onder "pizza", "lay's chips" onder "chips", "heineken bier" onder "bier".
- Smaken en soorten binnen hetzelfde product: pizza margherita onder "pizza", skyr aardbei onder "skyr", lipton raspberry ice tea onder "ice tea".
- Vorm en snit: penne en rigatoni onder "pasta", kipdijreepjes onder "kipdijfilet", kaas in plakken onder "kaas".
- Pijnstillers: paracetamol en ibuprofen samen onder "pijnstillers".
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
- Chorizo is een eigen product, apart van "salami": je bakt het ook in een gerecht. Fuet en andere gedroogde worst in plakken blijven bij "salami".
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

Alle yoghurt, ongeacht merk of vetgehalte. Griekse yoghurt, skyr en drinkyoghurt zijn aparte producten: wie Griekse yoghurt koopt wisselt bij een aanbieding niet naar gewone yoghurt.

### eiwitdrank

Alle kant-en-klare eiwitdranken en -shakes, ongeacht merk of smaak: hipro, xxl nutrition, melkunie protein.

### soep

Kant-en-klare soep in zak, blik of vers, ongeacht merk of smaak: tomatensoep, kippensoep, groentesoep, pompoensoep, gepureerde soep en oosterse soepen. Besluit (9 oktober 2026): tomatensoep en kippensoep zijn geen eigen product. Wie "tomatensoep" op de lijst zet, ziet daardoor ook een aanbieding op een andere soep, en wie "soep" opschrijft mist de tomatensoep niet. Erwtensoep is een maaltijd en blijft apart.

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

"specerijmengsel": specerijmengsels met een eigen smaak, zoals de world spice blends (garam masala, za'atar, ras el hanout, cajun, furikake). Besluit (9 oktober 2026): dit blijft een eigen product naast "kruidenmix", ook al zet de supermarkt ze vaak in dezelfde categorie.

"sausmix": heet het product een saus, dan is het geen kruidenmix maar "sausmix": mix voor macaronisaus, roomsaus, lasagnesaus, kaassaus (mac & cheese). Besluit (10 oktober 2026): de naam van het product beslist, niet het schap. Een mix voor een gerecht of een vleessoort blijft "kruidenmix".

"kruiden": losse kruiden en specerijen: peperkorrels, paprikapoeder. Bestaat er voor een kruid een eigen product (oregano, basilicum, bieslook, nootmuskaat), dan hoort het artikel daar.

### halvarine

Halvarine, margarine en plantaardige smeersels voor op brood, ongeacht merk: blue band, bona. "smeerbare boter" is boter en apart.

### soepmix

Droge mix in een zakje om zelf soep van te koken. Besluit (10 oktober 2026): "soepbasis" en "soepmix" zijn hetzelfde type en heten "soepmix".

### frituursnacks

Diepvriessnacks voor de frituur of airfryer, ongeacht merk: viandel, bamischijf, kipkorn, snackhamburger, kipburger en mixpacks. Besluit (10 oktober 2026): dit is een eigen type, niet "borrelhapjes" en niet "hamburgers". Frikandellen, kroketten, bitterballen en kaassoufflés houden hun eigen type.

### tapas

Gekoelde hapjes uit het tapasschap: gehaktballetjes, gemarineerde garnalen, gekookte worst als borrelhapje, gevulde pepers. Besluit (10 oktober 2026): het schap en het gebruik beslissen, niet het vlees of de vis erin. Diepvries borrelhapjes voor de oven blijven "borrelhapjes".

### pap

Kant-en-klare pap uit de koeling: rijstepap, griesmeelpap, havermoutpap, gortepap. Besluit (10 oktober 2026): een eigen type, niet "pudding". Havermout om zelf te koken en babypap zijn andere types.

### pudding

Puddingen en kant-en-klare toetjes in bakjes. Besluit (10 oktober 2026): hoekjesyoghurt (Almhof Hoekje en vergelijkbaar) is een toetje en hoort hier, niet bij "yoghurt".

### fruitbiscuit

Biscuits met een fruitvulling, ongeacht merk of smaak. Besluit (10 oktober 2026): een eigen type, niet "koekjes".

### babyhapjes en knijpfruit

Twee types. Besluit (10 oktober 2026): de verpakking beslist. Babyvoeding in een potje is "babyhapjes", ook als het fruit is; alleen knijpzakjes zijn "knijpfruit".

### fruitdrank

Frisse fruitdranken met suiker, ongeacht merk. Besluit (10 oktober 2026): het type heette "dubbelfrisss" en heet nu naar de soort; "dubbelfrisss" blijft een naam van het type. De variant zonder suiker of met 1 kcal is apart.

### sperziebonen, spinazie en boerenkool

Vers. Groente uit een pot (Hak) hoort er niet bij.

## Artikelen en types

Een artikel van een supermarkt (uit de aanbiedingen) hoort bij hooguit één type. De AI beoordeelt elk nieuw artikel bij het ophalen van de bonus, met titel, merk, inhoud en de categorie van de supermarkt, en kiest een type uit de lijst of "geen type". Er is geen goedkeuring vooraf: het oordeel telt meteen voor het label, het profiel en Voor jou, en de beheerder kijkt achteraf na wat twijfelachtig is.

Besluiten die zijn gebleven uit de tijd van de voorstellen (7 en 8 oktober 2026):

1. Dezelfde toets als overal: zou je bij een aanbieding dit artikel kopen in plaats van wat je gewoonlijk koopt?
2. Een woord uit de typenaam in de titel is geen bewijs. Pompoensoep en desembrood met pompoen horen niet bij "pompoen".
3. De categorie van de supermarkt helpt, maar is geen bewijs. AH zet multipacks speciaalbier soms onder "Pils blik" en fanta exotic onder "Sinas". Wat de titel zegt, gaat voor.
4. Een variant waar je niet tussen wisselt (zero, light, 0.0, decaf, alcoholvrij) krijgt zijn eigen type. Bestaat dat type niet, dan is het "geen type", niet de gewone variant. Bevestigd op 10 oktober 2026: dit blijft streng en geldt ook voor suikervrij en "zonder toegevoegde suiker" (Cruesli Zero Sugar is geen "granola", ontbijtkoek zonder toegevoegde suiker geen "ontbijtkoek").
5. Een apparaat, handvat, starterset of cadeaupakket hoort bij geen enkel type.

Besluiten (9 oktober 2026):

6. Vindt de AI geen type, dan noemt hij welk type ontbreekt. De beheerder maakt dat type aan in het scherm Koppelingen, kiest een bestaand type, of laat het zonder.
7. Een oordeel dat de beheerder heeft gezet of nagekeken vervangt de AI niet meer.
8. De oordelen met zekerheid hoog worden niet stuk voor stuk nagekeken: dat zijn er te veel. Ze zijn in te zien bij het type. De meeste fouten zaten eerder in zekerheid middel.
9. De database is de bron van de typelijst. `docs/producttypes-export.csv` is een afdruk die bij elke commit wordt ververst; pas dat bestand nooit met de hand aan.

## Matchen van lijsttermen

Wat iemand op de lijst typt is niet altijd de naam van een product of een lijstnaam: "proteine drank" met een spatie, "chocola", "tandenpasta", of een merk als "nivea". Voor het Bonus-label gaat een term daarom door vijf lagen; de eerste die iets oplevert telt.

Besluiten (9 oktober 2026), bij de overstap naar producttypes. Ze vervangen de lagen van 8 oktober (exact, synoniem, merk, tolerant, titel):

10. Een term staat voor een type, een merk, of allebei. De volgorde: de naam van een type, een merk, een naam van een type (`term_synonyms`), hetzelfde na stamming, een merk met een soort erbij, en als laatste tolerant.
11. Een merk gaat vóór een naam. Wie precies "nivea" typt krijgt het label bij elk artikel van Nivea, ook al hangt de naam "nivea" voor het profiel aan één type. De naam van een type gaat wel vóór een merk ("maggi").
12. Een merk met een soort erbij, in beide volgordes ("nivea shampoo", "tandpasta oral b"), staat voor de artikelen van dat merk binnen dat type. Heeft het merk daar geen artikelen, dan telt het hele type.
13. Voor het profiel en de bon geldt de merkregel niet: een aankoop "fanta" telt als sinas.
14. De titellaag is vervallen. Een term die nergens voor staat komt in `unmatched_terms`; de AI beoordeelt hem direct en slaat de uitkomst op als naam met bron `ai` en de datum. Daar is geen goedkeuring voor nodig: het label verschijnt meteen, en de beheerder corrigeert achteraf. De AI gokt niet: een te vage term of een losse merknaam krijgt geen type.
15. Een naam die beoordeeld is zonder type ("papier", "sap", "deeg") is bekend en krijgt geen label. Hij wordt niet opnieuw beoordeeld.

## Aanbieding op de lijst

Wie op Voor jou een aanbieding op de lijst zet, krijgt de titel van die aanbieding als naam van het item ("AH Bakkersbrood tijgerbrood volkoren heel"), niet de naam van het type ("brood").

1. Het item onthoudt de aanbieding, het artikel (alleen als de aanbieding precies één artikel heeft) en het type. De naam verandert daarna niet meer mee.
2. Hebben alle artikelen in de aanbieding hetzelfde type en stond de titel nog nergens voor, dan wordt de titel een naam van dat type. Zo telt de aankoop later in het profiel onder het type.
3. Horen de artikelen bij meerdere types ("Alle AH Bakkersbrood" met brood en stokbrood), dan krijgt het item geen type; het label blijft werken via de aanbieding zelf.
4. Staat er al een item van hetzelfde type op de lijst, dan komt het nieuwe er los bij.

## Correcties van 10 oktober 2026

Na de eerste week van PLUS stonden er 376 artikelen met zekerheid middel of laag om na te kijken. De besluiten van die dag staan hierboven bij de types. Ze zijn doorgevoerd met het eenmalige script `scripts/koppelingen-correcties`, dat dezelfde functies aanroept als het scherm Koppelingen: tien nieuwe types (frituursnacks, pap, fruitbiscuit, hondenvoer, kattensnacks, harissa, pijnboompitten, truffelolie, tropische frisdrank, zaden en pitten), soepbasis in soepmix, dubbelfrisss hernoemd tot fruitdrank, de afbakening van twaalf bestaande types bijgewerkt, 49 artikelen naar een ander type en de overige 333 als nagekeken gemarkeerd. Hondenvoer en kattensnacks staan in een nieuwe hoofdgroep "Huisdier". In een tweede ronde (`-ronde 2`) zijn dertien fruitpotjes van Olvarit van knijpfruit naar babyhapjes gegaan en hoort de naam "sesamzaad" bij zaden en pitten in plaats van bij kruiden.

## Werkwijze

1. De AI koppelt elk nieuw artikel en elke onbekende term zelf aan een type. Niets wacht op goedkeuring.
2. De beheerder kijkt in het scherm Koppelingen na wat de AI niet zeker wist en wat geen type kreeg, en zet recht wat fout is.
3. Een nieuw type, een andere naam of afbakening, en samenvoegen gebeuren in dat scherm, nooit in een bestand.
4. Nieuwe beslissingen over het niveau worden in dit bestand vastgelegd onder "Vastgestelde producten", en in de afbakening van het type zelf.
