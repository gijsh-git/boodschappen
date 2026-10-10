// Eenmalig: de correcties van 10 oktober 2026 op de producttypes, na de eerste PLUS-week (docs/productregels.md,
// de besluiten van die dag). Nieuwe types, een hernoemd type, een samenvoeging, bijgewerkte afbakeningen,
// artikelen en termen naar het goede type, en de rest van "Artikelen om na te kijken" als nagekeken.
//
// Het script roept dezelfde functies aan als het scherm Koppelingen (create_product_type, update_product_type,
// merge_product_types, set_article_types, save_term_types, mark_links_reviewed), zodat elk oordeel geldt als
// gezet door de beheerder en de AI het niet meer vervangt. Die functies vragen een ingelogde beheerder; het
// script verbindt rechtstreeks met de database en zet binnen één transactie de beheerder uit de tabel admins
// als gebruiker. Geen migratie: het zijn gegevens, geen structuur, en een migratie kent geen proefronde.
//
// Zonder -echt is het een proef: alles wordt uitgevoerd en daarna teruggedraaid, zodat de tellingen kloppen
// en er niets verandert. Gaat er iets mis, dan verandert er ook met -echt niets.
//
// Gebruik, vanuit de hoofdmap, met het databasewachtwoord uit .env geladen (set -a; source .env; set +a):
//
//	cd scripts/koppelingen-correcties && go run . ../../supabase/.temp/pooler-url
//	cd scripts/koppelingen-correcties && go run . -echt ../../supabase/.temp/pooler-url
//
// Ronde 1 is doorgevoerd op 10 oktober 2026. Ronde 2 (-ronde 2, dezelfde dag) is wat daarna nog bleek: de
// fruitpotjes van Olvarit die met zekerheid hoog bij knijpfruit stonden, en de naam "sesamzaad". Een ronde
// die al is doorgevoerd stopt bij het eerste artikel, omdat het oude type niet meer klopt.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/jackc/pgx/v5"
)

type soort struct {
	Naam, Hoofdgroep, Eronder, Niet string
	// Het voorstel van de AI waar dit type voor komt: wat zonder type op dat voorstel wacht hoort er meteen bij
	Voorstel string
}

var nieuweTypes = []soort{
	{"frituursnacks", "Diepvries", "Diepvriessnacks voor de frituur of airfryer, ongeacht merk: viandel, bamischijf, nasischijf, kipkorn, snackhamburger, kipburger en mixpacks.", "Frikandellen (frikandellen), kroketten (kroketten), bitterballen (bitterballen), kaassoufflés (kaassoufflés), kipnuggets (kipnuggets), borrelhapjes voor de oven (borrelhapjes).", ""},
	{"pap", "Zuivel, eieren", "Kant-en-klare pap uit de koeling, ongeacht merk: rijstepap, griesmeelpap, havermoutpap en gortepap.", "Pudding en toetjes in bakjes (pudding), havermout om zelf te koken (havermout), babypap (babypap).", ""},
	{"fruitbiscuit", "Tussendoortjes", "Biscuits met een fruitvulling, ongeacht merk of smaak: fruitbiscuit naturel, appel, bosvruchten en yoghurt.", "Andere koekjes en biscuits (koekjes).", ""},
	{"hondenvoer", "Huisdier", "Voer voor honden, nat of droog: brokken, paté en kuipjes.", "Snacks en kauwstaven voor honden.", "hondenvoer"},
	{"kattensnacks", "Huisdier", "Snacks en kauwsticks voor katten.", "Kattenvoer: brokken en natvoer.", "kattensnacks"},
	{"harissa", "Soepen, sauzen, kruiden, olie", "Harissa: pittige peperpasta of -saus uit een pot of tube.", "Harissa als droog kruidenmengsel (specerijmengsel).", "harissa"},
	{"pijnboompitten", "Borrel, chips, snacks", "Pijnboompitten, geroosterd of ongeroosterd.", "Andere zaden en pitten (zaden en pitten).", "pijnboompitten"},
	{"truffelolie", "Soepen, sauzen, kruiden, olie", "Olie met truffelsmaak.", "Olijfolie zonder smaak (olijfolie).", "truffelolie"},
	{"tropische frisdrank", "Frisdrank, sappen, water", "Frisdrank met tropische fruitsmaak en suiker, ongeacht merk, zoals Hawai Tropical.", "Sinas (sinas) en de varianten zonder suiker.", "tropische frisdrank"},
	{"zaden en pitten", "Borrel, chips, snacks", "Losse zaden en pitten om te strooien of mee te bakken: sesamzaad, zonnebloempitten, pompoenpitten, lijnzaad en chiazaad.", "Pijnboompitten (pijnboompitten) en noten.", "zaden en pitten"},
}

// Bestaande types waarvan de afbakening moet kloppen met de besluiten; de AI leest die tekst bij elk oordeel.
// Naam is de naam zoals hij nu is; NieuweNaam alleen bij een hernoeming (de oude naam blijft dan werken).
var gewijzigdeTypes = []struct {
	Naam, NieuweNaam, Eronder, Niet string
}{
	{"dubbelfrisss", "fruitdrank", "Frisse fruitdranken met suiker in elke smaak, ongeacht merk, zoals DubbelFrisss appel & perzik en framboos & cranberry.", "De variant zonder suiker of met 1 kcal; water met smaak (water met smaak)."},
	{"water met smaak", "", "Water met een smaakje, bruisend of niet, zoals spa touch en van de boom fruit water.", "Vitaminwater (vitaminwater); fruitdrank als DubbelFrisss (fruitdrank)."},
	{"borrelhapjes", "", "Gemengde en losse diepvries borrelhapjes voor de oven of airfryer: borrelmix, mini bites, kaashapjes, kipsnacks.", "Bitterballen (bitterballen), kroketten (kroketten), kaassoufflés (kaassoufflés), loempia's (loempia's); frituursnacks als viandel, bamischijf en kipkorn (frituursnacks); gekoelde hapjes uit het tapasschap (tapas)."},
	{"tapas", "", "Kleine borrelhapjes uit het gekoelde tapasschap, zoals cornichons met tiny peppers, gevulde pepers, gehaktballetjes, gemarineerde garnalen en gekookte worst als borrelhapje.", "Olijven (olijven), tapenade (tapenade), diepvries borrelhapjes (borrelhapjes)."},
	{"pudding", "", "Puddingen en kant-en-klare toetjes in bakjes: vanille-, griesmeel- en chocoladepudding, chocolademousse, proteïnepudding, en hoekjesyoghurt met een toevoeging in de hoek (Almhof Hoekje).", "Vla in pak (vla), yoghurt zonder toetje erbij (yoghurt), kant-en-klare pap als rijstepap en griesmeelpap (pap)."},
	{"koekjes", "", "Verpakte koekjes en biscuits, ongeacht merk of smaak: liga, evergreen, bastogne, café noir, chocoladekoekjes.", "Stroopwafels (stroopwafels), speculaas (speculaas), ontbijtkoek (ontbijtkoek), fruitbiscuit (fruitbiscuit)."},
	{"knijpfruit", "", "Fruithapjes voor baby's in een knijpzakje, ook biologisch en met groente, zoals appel banaan, peer en mango zoete aardappel.", "Babyvoeding in een potje, ook als het fruit is (babyhapjes)."},
	{"babyhapjes", "", "Babyvoeding in een potje of kommetje voor baby's en peuters, maaltijd, groente of fruit, zoals Olvarit en Bambix.", "Fruit in een knijpzakje (knijpfruit). Pap (babypap)."},
	{"sausmix", "", "Saus in een zakje om aan te maken, ongeacht merk: champignonsaus, pepersaus, bearnaise, en mixen die een saus heten, zoals macaronisaus, roomsaus, lasagnesaus en kaassaus (mac & cheese).", "Groentesaus (groentesaus), jus (jus), kant-en-klare pastasaus (pastasaus), mixen voor een gerecht of vleessoort (kruidenmix)."},
	{"kruidenmix", "", "Kruidenmixen voor een gerecht of vleessoort, ongeacht merk: bami, nasi, chili con carne, burrito, stamppot, macaroni, gehakt, shoarma, kip, vis, aardappel, patat, provençaalse en Italiaanse kruiden, persillade.", "Een mix die een saus heet, zoals macaronisaus, roomsaus, lasagnesaus en kaassaus (sausmix); world spice blends en mengsels met een eigen smaak, zoals cajun en garam masala (specerijmengsel), speculaaskruiden (speculaaskruiden), boemboe (boemboe), marinademix (marinade)."},
	{"kipschnitzel", "", "Gepaneerde kipschnitzels, kipcordon bleu en gepaneerde kipburgers uit het vleesschap.", "Ongepaneerde kipfilet (kipfilet), diepvries kipburgers voor de frituur (frituursnacks)."},
	{"hamburgers", "", "Rauwe hamburgers van rund, kip of gemengd vlees.", "Vegetarische burgers (vleesvervangers), gepaneerde kipburgers (kipschnitzel), diepvries snackhamburgers voor de frituur (frituursnacks)."},
}

// Samenvoegen: de eerste gaat op in de tweede
var samenvoegen = [][2]string{{"soepbasis", "soepmix"}}

// Artikelen van PLUS naar een ander type. Titel en Was moeten kloppen met de database, anders stopt het
// script: zo wordt nooit een ander artikel omgezet dan bedoeld. Naar "" is "geen type".
type omzetting struct {
	ID, Titel, Was, Naar string
}

var artikelen = []omzetting{
	{"843457", "Kips Kleintje kips", "likkepot", "paté"},
	{"194555", "Malibu Malibu rum white", "rum", "likeur"},
	{"668022", "PLUS Truffelmayo", "spicy mayo", "dipsaus"},
	{"651318", "PLUS Gelderse gekookte worst", "rookworst", "tapas"},
	{"290172", "PLUS Cremeux Blanc", "roodflorakaas", "brie"},
	{"233779", "Olvarit 6+mnd Banaan Appel Yoghurt", "knijpfruit", "babyhapjes"},
	{"233789", "Olvarit 8+mnd Banaan Koek", "knijpfruit", "babyhapjes"},
	{"466510", "PLUS Korenlanders Speculaaspencees", "speculaas", "gebak"},
	{"380427", "Smarties Mini melk chocolade uitdeelzak", "snoep", "chocolade"},
	{"561093", "PLUS Gehaktballetjes Hollands", "borrelhapjes", "tapas"},
	{"561104", "PLUS Gehaktballetjes Indisch", "borrelhapjes", "tapas"},
	{"561114", "PLUS Gehaktballetjes sate", "borrelhapjes", "tapas"},
	{"651150", "PLUS Garnalen in knoflookmarinade", "garnalen", "tapas"},
	{"563542", "PLUS Boerentrots Kipburger gepaneerd 5 stuks", "hamburgers", "kipschnitzel"},
	{"187178", "PLUS Boerentrots Krokante kipburger 5 stuks", "hamburgers", "kipschnitzel"},
	{"722611", "Mora Originals Bamischijf", "borrelhapjes", "frituursnacks"},
	{"731488", "Mora Originals Carrero", "borrelhapjes", "frituursnacks"},
	{"272608", "Mora Originals Kipkorn", "borrelhapjes", "frituursnacks"},
	{"731486", "Mora Originals Pikanto", "borrelhapjes", "frituursnacks"},
	{"485180", "Mora Originals Ribster", "borrelhapjes", "frituursnacks"},
	{"731491", "Mora Originals Viandel", "borrelhapjes", "frituursnacks"},
	{"977363", "Mora Originals 3 x 3 Mmmix Pack", "borrelhapjes", "frituursnacks"},
	{"724479", "Mora Classics Hamburgers", "hamburgers", "frituursnacks"},
	{"724505", "Mora Classics Hamburgers", "hamburgers", "frituursnacks"},
	{"324100", "Mora Specials Kipburgers", "hamburgers", "frituursnacks"},
	{"330996", "Melkunie Gortepap", "pudding", "pap"},
	{"330990", "Melkunie Havermoutpap", "pudding", "pap"},
	{"330992", "Melkunie Griesmeelpap", "pudding", "pap"},
	{"330988", "Melkunie Rijstepap", "pudding", "pap"},
	{"305891", "Almhof Hoekje kers", "yoghurt", "pudding"},
	{"306015", "Almhof Hoekje choco balls", "yoghurt", "pudding"},
	{"249606", "Almhof Hoekje Venetië pistache", "yoghurt", "pudding"},
	{"316393", "Redband Dropfruit duo's", "snoep", "drop"},
	{"456380", "PLUS Fruitbiscuit Appel", "koekjes", "fruitbiscuit"},
	{"456382", "PLUS Fruitbiscuit Naturel", "koekjes", "fruitbiscuit"},
	{"614740", "PLUS Fruitbiscuit yoghurt bosvruchten", "koekjes", "fruitbiscuit"},
	{"644986", "PLUS Fruitbiscuit yoghurt aardbei", "koekjes", "fruitbiscuit"},
	{"973974", "PLUS Fruitbiscuit bosvruchten", "koekjes", "fruitbiscuit"},
	{"719743", "Honig Mix voor macaronisaus stroganoff", "kruidenmix", "sausmix"},
	{"719749", "Honig Mix voor tagliatelle roomsaus", "kruidenmix", "sausmix"},
	{"413089", "Knorr Maaltijdmix Mac & Cheese", "kruidenmix", "sausmix"},
	{"318253", "Quaker Cruesli Zero Sugar Nuts&Seeds", "granola", ""},
	{"824213", "Peijnenburg Naturel zonder toegev. suiker 4-pack", "ontbijtkoek", ""},
	{"286609", "PLUS Premium Honden paté Rund", "", "hondenvoer"},
	{"135995", "PLUS katten kauwsticks zalm", "", "kattensnacks"},
	{"628154", "Hawai Tropical", "", "tropische frisdrank"},
	{"800221", "Knorr Good Potatoes Spek en Ui", "", "instant noedels"},
	{"800223", "Knorr Good Potatoes Broccoli en Kaas", "", "instant noedels"},
	{"158677", "PLUS Puur van smaak Leverkaas", "", ""},
}

// Termen die iemand typte, naar een type. Staat de term gelijk aan de naam van een nieuw type (harissa,
// pijnboompitten, truffelolie), dan hoeft er niets: de naam van een type gaat altijd voor.
var termen = [][2]string{{"geroosterd sesamzaad", "zaden en pitten"}}

// Ronde 2: babyvoeding in een potje is babyhapjes, alleen knijpzakjes zijn knijpfruit. Dit zijn de potjes van
// 125 en 200 gram; "Olvarit Appel zwarte bes 12+" van 100 gram is een knijpzakje en blijft.
var artikelen2 = []omzetting{
	{"233884", "Olvarit 12+mnd Appel Peer Framboos", "knijpfruit", "babyhapjes"},
	{"233886", "Olvarit 12+mnd Appel Perzik Mango", "knijpfruit", "babyhapjes"},
	{"233888", "Olvarit 12+mnd Banaan Sinaasappel Koek", "knijpfruit", "babyhapjes"},
	{"364303", "Olvarit 4+mnd Appel Mango Banaan", "knijpfruit", "babyhapjes"},
	{"234091", "Olvarit 4+mnd Banaan", "knijpfruit", "babyhapjes"},
	{"234095", "Olvarit 4+mnd Peer", "knijpfruit", "babyhapjes"},
	{"234093", "Olvarit 4+mnd Perzik Appel", "knijpfruit", "babyhapjes"},
	{"234089", "Olvarit 6+mnd Appel Aardbei Peer", "knijpfruit", "babyhapjes"},
	{"233775", "Olvarit 6+mnd Appel Banaan Sinaasappel", "knijpfruit", "babyhapjes"},
	{"234072", "Olvarit 6+mnd Perzik Banaan Kiwi", "knijpfruit", "babyhapjes"},
	{"233785", "Olvarit 8+mnd Abrikoos Appel Banaan", "knijpfruit", "babyhapjes"},
	{"233854", "Olvarit 8+mnd Appel Aardbei Banaan", "knijpfruit", "babyhapjes"},
	{"233791", "Olvarit 8+mnd Appel Banaan Peer", "knijpfruit", "babyhapjes"},
}

// Ronde 2: "sesamzaad" hing aan kruiden, terwijl "geroosterd sesamzaad" bij zaden en pitten hoort
var termen2 = [][2]string{{"sesamzaad", "zaden en pitten"}}

const winkel = "PLUS"

func main() {
	echt := flag.Bool("echt", false, "de correcties echt doorvoeren; zonder is het een proef")
	ronde := flag.Int("ronde", 1, "1: de correcties van de eerste ronde; 2: wat daarna nog bleek")
	flag.Parse()
	if *ronde == 2 {
		nieuweTypes, gewijzigdeTypes, samenvoegen = nil, nil, nil
		artikelen, termen = artikelen2, termen2
	} else if *ronde != 1 {
		stop("onbekende ronde %d", *ronde)
	}
	if flag.NArg() != 1 {
		stop("gebruik: go run . [-echt] <pad naar supabase/.temp/pooler-url>")
	}
	adres, err := os.ReadFile(flag.Arg(0))
	if err != nil {
		stop("%v", err)
	}
	u, err := url.Parse(strings.TrimSpace(string(adres)))
	if err != nil {
		stop("het adres van de database is niet te lezen: %v", err)
	}
	if os.Getenv("SUPABASE_DB_PASSWORD") == "" {
		stop("SUPABASE_DB_PASSWORD is niet gezet (set -a; source .env; set +a)")
	}
	u.User = url.UserPassword(u.User.Username(), os.Getenv("SUPABASE_DB_PASSWORD"))

	ctx := context.Background()
	c, err := pgx.Connect(ctx, u.String())
	if err != nil {
		stop("verbinden mislukt: %v", err)
	}
	defer c.Close(ctx)
	tx, err := c.Begin(ctx)
	if err != nil {
		stop("%v", err)
	}
	defer tx.Rollback(ctx)

	// Een vraag met één uitkomst; elke fout stopt het script, en daarmee de hele transactie
	een := func(uit any, vraag string, args ...any) {
		if err := tx.QueryRow(ctx, vraag, args...).Scan(uit); err != nil {
			stop("mislukt, er is niets veranderd: %v\n  bij: %s %v", err, vraag, args)
		}
	}
	typeID := func(naam string) string {
		var id string
		een(&id, `select id::text from public.product_types where key = public.match_key($1)`, naam)
		return id
	}

	// De beheerder als gebruiker van deze transactie, zoals PostgREST dat doet voor een ingelogde gebruiker
	var beheerder string
	een(&beheerder, `select user_id::text from public.admins order by user_id limit 1`)
	claims, _ := json.Marshal(map[string]string{"sub": beheerder, "role": "authenticated"})
	var niets string
	een(&niets, `select set_config('request.jwt.claims', $1, true)`, string(claims))
	een(&niets, `select set_config('request.jwt.claim.sub', $1, true)`, beheerder)
	var isBeheerder bool
	een(&isBeheerder, `select public.is_admin()`)
	if !isBeheerder {
		stop("de beheerder is niet herkend; er is niets veranderd")
	}

	nakijken := func() (artikelen, zonder, termen int) {
		een(&artikelen, `select count(*) from public.article_types where source = 'ai' and reviewed_at is null and type_id is not null and confidence in ('medium', 'low')`)
		een(&zonder, `select count(*) from public.article_types where reviewed_at is null and type_id is null`)
		een(&termen, `select count(*) from public.term_synonyms where source = 'ai' and reviewed_at is null`)
		return
	}
	a, z, t := nakijken()
	fmt.Printf("Vooraf: %d artikelen om na te kijken, %d zonder type, %d termen.\n\n", a, z, t)

	fmt.Println("Nieuwe types:")
	for _, s := range nieuweTypes {
		var uit string
		een(&uit, `select public.create_product_type($1, $2, $3, $4, true, nullif($5, ''))::text`, s.Naam, s.Hoofdgroep, s.Eronder, s.Niet, s.Voorstel)
		var r struct {
			Termen, Artikelen int
		}
		json.Unmarshal([]byte(uit), &r)
		fmt.Printf("  %-20s %-32s meteen gekoppeld: %d artikelen, %d termen\n", s.Naam, s.Hoofdgroep, r.Artikelen, r.Termen)
	}

	fmt.Println("\nSamenvoegen:")
	for _, s := range samenvoegen {
		var uit string
		een(&uit, `select public.merge_product_types($1, $2)::text`, s[0], s[1])
		fmt.Printf("  %s in %s: %s\n", s[0], s[1], uit)
	}

	fmt.Println("\nAfbakening bijgewerkt:")
	for _, g := range gewijzigdeTypes {
		naam := g.Naam
		if g.NieuweNaam != "" {
			naam = g.NieuweNaam
		}
		var uit string
		een(&uit, `select (public.update_product_type(p.id, $2, p.main_group, $3, $4, p.counts_in_profile)).name
		           from public.product_types p where p.key = public.match_key($1)`, g.Naam, naam, g.Eronder, g.Niet)
		if g.NieuweNaam != "" {
			var oudeNaam string
			een(&oudeNaam, `select p.name from public.term_synonyms s join public.product_types p on p.id = s.type_id where s.key = public.match_key($1)`, g.Naam)
			fmt.Printf("  %s heet nu %s; \"%s\" blijft een naam van %s\n", g.Naam, uit, g.Naam, oudeNaam)
		} else {
			fmt.Printf("  %s\n", uit)
		}
	}

	fmt.Println("\nArtikelen omgezet:")
	rijen := []map[string]any{}
	for _, art := range artikelen {
		var titel, was string
		een(&titel, `select title from public.articles where supermarket = $1 and article_id = $2`, winkel, art.ID)
		een(&was, `select coalesce((select p.name from public.article_types t join public.product_types p on p.id = t.type_id
		                            where t.supermarket = $1 and t.article_id = $2), '')`, winkel, art.ID)
		if titel != art.Titel {
			stop("artikel %s heet %q, niet %q; er is niets veranderd", art.ID, titel, art.Titel)
		}
		if was != art.Was {
			stop("artikel %s (%s) heeft type %q, niet %q; er is niets veranderd", art.ID, titel, was, art.Was)
		}
		rij := map[string]any{"supermarket": winkel, "article_id": art.ID, "type_id": nil}
		if art.Naar != "" {
			rij["type_id"] = typeID(art.Naar)
		}
		rijen = append(rijen, rij)
		fmt.Printf("  %-50s %-14s -> %s\n", titel, of(was, "geen type"), of(art.Naar, "geen type"))
	}
	body, _ := json.Marshal(rijen)
	var gezet int
	een(&gezet, `select public.set_article_types($1::jsonb, 'manual')`, string(body))
	if gezet != len(artikelen) {
		stop("%d van de %d artikelen zijn omgezet; er is niets veranderd", gezet, len(artikelen))
	}
	fmt.Printf("  %d artikelen omgezet, gezet door de beheerder.\n", gezet)

	fmt.Println("\nTermen:")
	for _, s := range nieuweTypes {
		var stap int
		een(&stap, `select coalesce((select step from public.term_match($1)), 0)`, s.Naam)
		if stap != 1 {
			stop("de term %q staat niet voor het type met die naam; er is niets veranderd", s.Naam)
		}
	}
	if len(nieuweTypes) > 0 {
		fmt.Println("  de naam van elk nieuw type staat voor dat type (harissa, pijnboompitten, truffelolie, ...)")
	}
	for _, term := range termen {
		rij, _ := json.Marshal([]map[string]any{{"term": term[0], "type_id": typeID(term[1])}})
		var uit string
		een(&uit, `select public.save_term_types($1::jsonb, 'manual')::text`, string(rij))
		var naam string
		een(&naam, `select coalesce((select p.name from public.term_synonyms s join public.product_types p on p.id = s.type_id
		                             where s.key = public.match_key($1) and s.source = 'manual'), '')`, term[0])
		if naam != term[1] {
			stop("de term %q is niet aan %q gekoppeld (%s); er is niets veranderd", term[0], term[1], uit)
		}
		fmt.Printf("  %s -> %s\n", term[0], naam)
	}

	a, z, t = nakijken()
	if *ronde == 2 {
		fmt.Printf("\nDaarna: %d artikelen om na te kijken, %d zonder type, %d termen.\n", a, z, t)
		klaar(ctx, tx, *echt)
		return
	}

	// Wat nu nog in "Artikelen om na te kijken" staat is beoordeeld en goed bevonden
	var rest string
	een(&rest, `select coalesce(jsonb_agg(jsonb_build_object('supermarket', t.supermarket, 'article_id', t.article_id)), '[]'::jsonb)::text
	            from public.article_types t
	            where t.source = 'ai' and t.reviewed_at is null and t.type_id is not null and t.confidence in ('medium', 'low')`)
	var uit string
	een(&uit, `select public.mark_links_reviewed('{}'::text[], $1::jsonb)::text`, rest)
	fmt.Printf("\nDe rest als nagekeken gemarkeerd, met het type dat ze hadden: %s\n", uit)

	a, z, t = nakijken()
	fmt.Printf("\nDaarna: %d artikelen om na te kijken, %d zonder type, %d termen.\n", a, z, t)

	klaar(ctx, tx, *echt)
}

func klaar(ctx context.Context, tx pgx.Tx, echt bool) {
	if !echt {
		fmt.Println("\nPROEF: alles is teruggedraaid, er is niets veranderd (gebruik -echt om door te voeren).")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		stop("vastleggen mislukt, er is niets veranderd: %v", err)
	}
	fmt.Println("\nDoorgevoerd.")
}

func of(tekst, anders string) string {
	if tekst == "" {
		return anders
	}
	return tekst
}

func stop(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
