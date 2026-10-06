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
- Verpakkingstekst van de supermarkt: "vers belegd broodje carpaccio" onder "broodje carpaccio".

## Apart houden

- Varianten waar je niet tussen wisselt: halfvolle, volle en gewone melk; cola en cola zero; chocolademelk en chocomel 0%.
- Alcoholvrij en gemengd tegenover gewoon: amstel 0.0, desperados en radler apart van "bier"; rosé apart van "witte wijn".
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

Gewoon bier, ongeacht merk. Niet: alcoholvrij, radler, desperados.

### witte wijn

Witte wijn, ongeacht druif of merk. Rosé is apart.

### melk

"melk" en "biologische melk" vormen één product. Halfvolle en volle melk zijn aparte producten.

## Nog open

- Belegde broodjes: carpaccio, caprese en kip pesto samen als "belegd broodje"?
- Hartige broodjes: frikandel-, kaas-, kaas-ui-, pizza-, saucijzen- en worstenbroodje samen of apart?
- Zoet brood: krenten-rozijnenbrood en rozijnenbol samen?

## Werkwijze

1. Een onbekende naam wordt eerst een eigen product.
2. De AI doet een voorstel op basis van dit bestand, met zekerheid en reden.
3. De beheerder keurt goed of af. Niets wordt automatisch samengevoegd.
4. Nieuwe beslissingen worden in dit bestand vastgelegd onder "Vastgestelde producten" of "Nog open".
