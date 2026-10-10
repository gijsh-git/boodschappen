// Haalt de PLUS-aanbiedingen van één week op, met per aanbieding de artikelen, en zet die in een JSON-bestand.
// Alleen lezen, zonder account: dezelfde JSON-calls die plus.nl/aanbiedingen zelf doet (OutSystems).
// Die calls zijn intern en kunnen bij elke nieuwe versie van de site veranderen. De versienummers die de site
// bij een call verwacht staan daarom niet in dit script; ze worden elke keer uit de scripts van de site gelezen.
// Landelijke aanbiedingen, zonder winkelkeuze. "Gratis bezorging" is geen korting op een artikel en blijft buiten beschouwing.
//
// Gebruik:
//
//	cd scripts/plus-aanbiedingen && go run . ../../data/plus-aanbiedingen.json
//	go run . -volgende ../../data/plus-aanbiedingen.json     de volgende week, als die al gepubliceerd is
//	go run . -producten 50 ../../data/plus-aanbiedingen.json ook de productpagina van de eerste 50 artikelen (-1: alle)
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/andybalholm/brotli"
)

const (
	basis = "https://www.plus.nl"
	// Zonder de naam van een gewone browser geeft de site geen antwoord
	browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
	// Het vaste token dat OutSystems meestuurt voor wie niet is ingelogd; het staat in /scripts/OutSystems.js
	anoniemToken = "T6C+9iB49TLra4jEsMeSckDMNhQ="
	pauze        = 250 * time.Millisecond
)

// Een call van de site: het script waarin hij staat, de naam, en het scherm dat hem doet
type call struct {
	Script string
	Naam   string
	Scherm string
	// Gevuld door zoekCall
	pad string
	api string
}

var (
	lijstCall   = &call{Script: "ECP_Composition_CW.Promotions.Promotion_LP_Content_TF.mvc.js", Naam: "DataActionGetPromotionList", Scherm: "MainFlow.Promotions"}
	detailCall  = &call{Script: "ECP_Promotion_CW.PromotionDetailsFlow.PromotionOffer_DP_Content.mvc.js", Naam: "DataActionPromotionOfferDetail_Get", Scherm: "MainFlow.Promotions"}
	productCall = &call{Script: "ECP_Product_CW.ProductDetails.PDPContent.mvc.js", Naam: "DataActionGetProductDetailsAndAgeInfo", Scherm: "MainFlow.ProductDetailsPage"}
)

type artikel struct {
	// Het artikelnummer van de webshop (SKU). Tekst, omdat het een nummer met voorloopnullen kan zijn
	WebshopID string `json:"webshop_id"`
	Titel     string `json:"titel"`
	Merk      string `json:"merk,omitempty"`
	// Zoals PLUS het schrijft, zonder "Per": "1000 ml", "16 st". Bij een losse aanbieding uit de slug gehaald
	Inhoud string `json:"inhoud,omitempty"`
	// Bij een groep alleen de diepste categorie ("Zuiveldranken"); met de productpagina het hele pad, gescheiden door "/"
	Categorie string  `json:"categorie,omitempty"`
	Prijs     float64 `json:"prijs,omitempty"`
	// Alleen gevuld als PLUS een actieprijs per stuk geeft; bij "1+1 gratis" of "3 voor" is die er niet
	Actieprijs float64 `json:"actieprijs,omitempty"`
	// Alleen in de winkel te koop, niet online (sterke drank)
	AlleenWinkel bool `json:"alleen_winkel,omitempty"`
	// Een artikel dat alleen een plaatselijke winkel voert
	Lokaal bool   `json:"lokaal,omitempty"`
	Slug   string `json:"slug,omitempty"`

	// Hieronder: alleen gevuld met -producten, van de productpagina
	EAN         string  `json:"ean,omitempty"`
	Hoeveelheid float64 `json:"hoeveelheid,omitempty"`
	Eenheid     string  `json:"eenheid,omitempty"`
	// De gewone prijs per basiseenheid ("kilo", "liter", "stuk"), zonder korting
	PrijsPerEenheid float64 `json:"prijs_per_eenheid,omitempty"`
	Basiseenheid    string  `json:"basiseenheid,omitempty"`
}

type aanbieding struct {
	// "4450-135" bij een groep, de slug van het artikel bij een losse aanbieding
	ID    string `json:"id"`
	Titel string `json:"titel"`
	// De kortingstekst: "1+1 GRATIS", "2 VOOR 4.99", "25 % KORTING". Leeg als er alleen een actieprijs is
	Korting string `json:"korting,omitempty"`
	// Een tweede label: "OP=OP", "VOORDEELVERPAKKING"
	Extra string `json:"extra,omitempty"`
	// Welke artikelen meedoen, in woorden: "Alle pakken à 1 liter"
	Variant string `json:"variant,omitempty"`
	// Waar de actieprijs voor geldt: "Per pak", "3 pakken", "Per kilo"
	Verpakking string  `json:"verpakking,omitempty"`
	Uitleg     string  `json:"uitleg,omitempty"`
	Categorie  string  `json:"categorie"`
	Actieprijs float64 `json:"actieprijs,omitempty"`
	// De gewone prijs van het goedkoopste en het duurste artikel in de groep
	PrijsVan float64 `json:"prijs_van,omitempty"`
	PrijsTot float64 `json:"prijs_tot,omitempty"`
	Van      string  `json:"van"`
	Tot      string  `json:"tot"`
	// true: een aanbieding met meerdere artikelen; false: één los artikel
	Groep        bool `json:"groep"`
	AlleenWinkel bool `json:"alleen_winkel,omitempty"`
	// Bij deze aanbieding krijg je extra spaarzegels
	Zegels    bool      `json:"zegels,omitempty"`
	Artikelen []artikel `json:"artikelen"`
	// true: de artikelen van deze groep ophalen is mislukt, de lijst hierboven is dus niet compleet
	Mislukt bool `json:"mislukt,omitempty"`
}

type week struct {
	Van          string       `json:"van"`
	Tot          string       `json:"tot"`
	Opgehaald    string       `json:"opgehaald"`
	Aanbiedingen []aanbieding `json:"aanbiedingen"`
	// Aanbiedingen "Gratis bezorging", die niet zijn meegenomen
	Overgeslagen int `json:"overgeslagen"`
}

// OutSystems schrijft bedragen als tekst ("19.99"); een enkele keer als getal
type bedrag float64

func (b *bedrag) UnmarshalJSON(data []byte) error {
	tekst := strings.Trim(string(data), `"`)
	if tekst == "" || tekst == "null" {
		return nil
	}
	getal, err := strconv.ParseFloat(tekst, 64)
	if err != nil {
		return fmt.Errorf("geen bedrag: %s", data)
	}
	*b = bedrag(getal)
	return nil
}

type klant struct {
	http   *http.Client
	module string
}

func (k *klant) vraag(methode, url string, body []byte, verwijzing string) ([]byte, error) {
	req, err := http.NewRequest(methode, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", browser)
	// De site antwoordt met Brotli, ook als je er niet om vraagt
	req.Header.Set("Accept-Encoding", "gzip, br")
	if body != nil {
		req.Header.Set("Content-Type", "application/json; charset=UTF-8")
		req.Header.Set("Accept", "application/json")
		req.Header.Set("X-CSRFToken", anoniemToken)
		req.Header.Set("Origin", basis)
		req.Header.Set("Referer", verwijzing)
	}
	resp, err := k.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var lezer io.Reader = resp.Body
	switch resp.Header.Get("Content-Encoding") {
	case "br":
		lezer = brotli.NewReader(resp.Body)
	case "gzip":
		if lezer, err = gzip.NewReader(resp.Body); err != nil {
			return nil, err
		}
	}
	data, err := io.ReadAll(lezer)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d: %.200s", resp.StatusCode, data)
	}
	return data, nil
}

// Een verzoek mislukt af en toe zonder reden; een paar keer proberen voorkomt een halve week
func probeer(vraag func() error) error {
	var err error
	for poging := 1; poging <= 3; poging++ {
		if err = vraag(); err == nil {
			return nil
		}
		time.Sleep(time.Duration(poging) * 2 * time.Second)
	}
	return err
}

// Leest uit het script van de site waar een call heen moet en welk versienummer erbij hoort
func (k *klant) zoekCall(c *call) error {
	data, err := k.vraag("GET", basis+"/ECOP/scripts/"+c.Script, nil, "")
	if err != nil {
		return err
	}
	patroon := regexp.MustCompile(`callDataAction\("` + regexp.QuoteMeta(c.Naam) + `",\s*"([^"]+)",\s*"([^"]+)"`)
	gevonden := patroon.FindSubmatch(data)
	if gevonden == nil {
		return fmt.Errorf("%s staat niet meer in %s: de site is veranderd", c.Naam, c.Script)
	}
	c.pad, c.api = string(gevonden[1]), string(gevonden[2])
	return nil
}

// Doet een call van de site en zet het deel "data" van het antwoord in uit
func (k *klant) haal(c *call, variabelen map[string]any, verwijzing string, uit any) error {
	body, err := json.Marshal(map[string]any{
		"versionInfo": map[string]string{"moduleVersion": k.module, "apiVersion": c.api},
		"viewName":    c.Scherm,
		"screenData":  map[string]any{"variables": variabelen},
	})
	if err != nil {
		return err
	}
	return probeer(func() error {
		data, err := k.vraag("POST", basis+"/"+c.pad, body, verwijzing)
		if err != nil {
			return err
		}
		var antwoord struct {
			Data      json.RawMessage `json:"data"`
			Exception *struct {
				Name    string `json:"name"`
				Message string `json:"message"`
			} `json:"exception"`
		}
		if err := json.Unmarshal(data, &antwoord); err != nil {
			return fmt.Errorf("geen JSON: %.200s", data)
		}
		if antwoord.Exception != nil {
			return fmt.Errorf("%s: %s", antwoord.Exception.Name, antwoord.Exception.Message)
		}
		return json.Unmarshal(antwoord.Data, uit)
	})
}

// De site stuurt bij elke call de toestand van het scherm mee. Dit zijn de velden van een bezoeker die niet is
// ingelogd en geen winkel heeft gekozen; de velden op "InDataFetchStatus" zeggen dat een waarde is ingevuld.
func bezoeker(extra map[string]any) map[string]any {
	v := map[string]any{
		"StoreNumber": 0, "CheckoutId": "", "IsOrderEditMode": false, "OrderEditId": "",
		"OneWelcomeUserId": "", "_oneWelcomeUserIdInDataFetchStatus": 1,
		"IsDesktop": true, "_isDesktopInDataFetchStatus": 1,
		"IsTablet": false, "_isTabletInDataFetchStatus": 1,
		"IsPhone": false, "_isPhoneInDataFetchStatus": 1,
		"IsCustomerUnderAge": false, "_isCustomerUnderAgeInDataFetchStatus": 1,
		"IsTimetraveler": false, "_isTimetravelerInDataFetchStatus": 1,
	}
	for sleutel, waarde := range extra {
		v[sleutel] = waarde
	}
	return v
}

type apiAanbieding struct {
	Brand                string
	Name                 string
	Variant              string
	Explanation          string
	Package              string
	Slug                 string
	NewPrice             bedrag
	PriceOriginalProduct bedrag `json:"PriceOriginal_Product"`
	PriceOriginalHighest bedrag `json:"PriceOriginal_Highest"`
	PriceOriginalLowest  bedrag `json:"PriceOriginal_Lowest"`
	IsOfflineSaleOnly    bool
	Label                string `json:"DisplayInfo_Label"`
	PromotionBasedLabel  string `json:"DisplayInfo_PromotionBasedLabel"`
	StartDate            string
	EndDate              string
	IsFreeDeliveryOffer  bool
	IsSingleProduct      bool
	ProductSKU           string `json:"Product_SKU"`
	StampURL             string
}

type apiLijst struct {
	PromotionOfferList struct {
		List []struct {
			Category struct {
				CategoryLabel string
				Offers        struct {
					List []apiAanbieding
				}
			}
		}
	}
	PromotionPeriod struct {
		FromDate string
		ToDate   string
	}
}

type apiDetail struct {
	PromotionOfferDetail struct {
		ProductList struct {
			List []struct {
				PLP struct {
					SKU      string
					Brand    string
					Name     string
					Subtitle string `json:"Product_Subtitle"`
					Slug     string
					// Ondanks de naam is dit de actieprijs per stuk; 0 als die er niet is
					OriginalPrice bedrag
					Categories    struct {
						List []struct{ Name string }
					}
					IsOfflineSaleOnly bool
					IsLocalItem       bool
				} `json:"PLP_Str"`
				PriceOriginal bedrag `json:"Price_Original"`
			}
		}
	}
}

type apiProduct struct {
	ProductOut struct {
		Overview struct {
			BaseUnitPrice bedrag
		}
		Categories struct {
			List []struct{ Name string }
		}
		// Het EAN staat bij elk artikel onder "Medicine", niet alleen bij medicijnen
		Medicine struct {
			EAN string
		}
	}
	ReferenceQuantity struct {
		Symbol   string `json:"Product_Symbol"`
		BaseUnit string `json:"Unit_BaseUnit"`
		Size     bedrag `json:"Product_Size"`
	}
}

// "plus-spruiten-zak-750-g-188088": de inhoud staat voor het artikelnummer
var slugInhoud = regexp.MustCompile(`-(\d+)-([a-z]+)-\d+$`)

func titel(merk, naam string) string {
	return strings.TrimSpace(strings.TrimSpace(merk) + " " + strings.TrimSpace(naam))
}

func main() {
	volgende := flag.Bool("volgende", false, "de volgende week in plaats van de lopende")
	producten := flag.Int("producten", 0, "van zoveel artikelen ook de productpagina ophalen (EAN, inhoud, categoriepad); -1 is alle")
	flag.Parse()
	if flag.NArg() != 1 {
		stop("gebruik: go run . [-volgende] [-producten N] <pad naar plus-aanbiedingen.json>")
	}
	uit := flag.Arg(0)

	koekjes, _ := cookiejar.New(nil)
	k := &klant{http: &http.Client{Jar: koekjes, Timeout: 60 * time.Second}}

	// De eerste pagina zet de cookies van de beveiliging voor de site (Imperva)
	if _, err := k.vraag("GET", basis+"/aanbiedingen", nil, ""); err != nil {
		stop("plus.nl openen mislukt: %v", err)
	}
	var info struct {
		Manifest struct {
			VersionToken string `json:"versionToken"`
		} `json:"manifest"`
	}
	data, err := k.vraag("GET", basis+"/moduleservices/moduleinfo", nil, "")
	if err != nil {
		stop("versie van de site ophalen mislukt: %v", err)
	}
	if err := json.Unmarshal(data, &info); err != nil || info.Manifest.VersionToken == "" {
		stop("versie van de site niet gevonden: %.200s", data)
	}
	k.module = info.Manifest.VersionToken
	for _, c := range []*call{lijstCall, detailCall, productCall} {
		if err := k.zoekCall(c); err != nil {
			stop("%v", err)
		}
	}

	// 1 is de lopende week, 2 de volgende. De site zelf stuurt 0 en krijgt dan de week die hij wil tonen
	periode := 1
	if *volgende {
		periode = 2
	}
	var lijst apiLijst
	err = k.haal(lijstCall, bezoeker(map[string]any{
		"IsShowData": false, "StoreChannel": "", "HideDummy": false, "PromotionPeriodId": periode,
		"UserStoreId": "0", "_userStoreIdInDataFetchStatus": 1,
		"ItemsInCartJSON": "", "_itemsInCartJSONInDataFetchStatus": 1,
		"IsNextWeekPromotions": *volgende, "_isNextWeekPromotionsInDataFetchStatus": 1,
	}), basis+"/aanbiedingen", &lijst)
	if err != nil {
		stop("aanbiedingen ophalen mislukt: %v", err)
	}

	w := week{Van: lijst.PromotionPeriod.FromDate, Tot: lijst.PromotionPeriod.ToDate, Opgehaald: time.Now().Format(time.RFC3339), Aanbiedingen: []aanbieding{}}
	for _, blok := range lijst.PromotionOfferList.List {
		for _, o := range blok.Category.Offers.List {
			if o.IsFreeDeliveryOffer {
				w.Overgeslagen++
				continue
			}
			a := aanbieding{
				ID: o.Slug, Titel: titel(o.Brand, o.Name), Korting: o.Label, Extra: o.PromotionBasedLabel,
				Variant: o.Variant, Verpakking: o.Package, Uitleg: o.Explanation, Categorie: blok.Category.CategoryLabel,
				Actieprijs: float64(o.NewPrice), PrijsVan: float64(o.PriceOriginalLowest), PrijsTot: float64(o.PriceOriginalHighest),
				Van: o.StartDate, Tot: o.EndDate, Groep: !o.IsSingleProduct, AlleenWinkel: o.IsOfflineSaleOnly,
				Zegels: o.StampURL != "", Artikelen: []artikel{},
			}
			// Een losse aanbieding heeft geen eigen pagina met artikelen: het artikel staat in de lijst zelf.
			// Bij een groep staat in Product_SKU een nummer dat er niets mee te maken heeft.
			if o.IsSingleProduct {
				art := artikel{
					WebshopID: o.ProductSKU, Titel: a.Titel, Merk: strings.TrimSpace(o.Brand), Categorie: a.Categorie,
					Prijs: float64(o.PriceOriginalProduct), Actieprijs: float64(o.NewPrice), AlleenWinkel: o.IsOfflineSaleOnly, Slug: o.Slug,
				}
				if m := slugInhoud.FindStringSubmatch(o.Slug); m != nil {
					art.Inhoud = m[1] + " " + m[2]
				}
				a.Artikelen = append(a.Artikelen, art)
			}
			w.Aanbiedingen = append(w.Aanbiedingen, a)
		}
	}
	if len(w.Aanbiedingen) == 0 {
		stop("geen aanbiedingen gevonden voor %s tot %s", w.Van, w.Tot)
	}

	mislukt := 0
	for i := range w.Aanbiedingen {
		a := &w.Aanbiedingen[i]
		if !a.Groep {
			continue
		}
		var detail apiDetail
		err := k.haal(detailCall, bezoeker(map[string]any{
			"StoreChannelD": "", "PromotionOfferId": a.ID, "_promotionOfferIdInDataFetchStatus": 1,
		}), basis+"/aanbiedingen/"+a.ID, &detail)
		if err != nil {
			mislukt++
			a.Mislukt = true
			fmt.Fprintf(os.Stderr, "groep %s (%s) mislukt: %v\n", a.ID, a.Titel, err)
		}
		for _, regel := range detail.PromotionOfferDetail.ProductList.List {
			p := regel.PLP
			art := artikel{
				WebshopID: p.SKU, Titel: titel(p.Brand, p.Name), Merk: strings.TrimSpace(p.Brand),
				Inhoud: strings.TrimSpace(strings.TrimPrefix(p.Subtitle, "Per ")),
				Prijs:  float64(regel.PriceOriginal), Actieprijs: float64(p.OriginalPrice),
				AlleenWinkel: p.IsOfflineSaleOnly, Lokaal: p.IsLocalItem, Slug: p.Slug,
			}
			if n := len(p.Categories.List); n > 0 {
				art.Categorie = p.Categories.List[n-1].Name
			}
			a.Artikelen = append(a.Artikelen, art)
		}
		time.Sleep(pauze)
	}

	// De productpagina: één verzoek per artikel, daarom alleen op verzoek
	opgehaald, zonderPagina := 0, 0
	gezien := map[string]*artikel{}
	for i := range w.Aanbiedingen {
		for j := range w.Aanbiedingen[i].Artikelen {
			art := &w.Aanbiedingen[i].Artikelen[j]
			if art.WebshopID == "" || art.Slug == "" {
				continue
			}
			// Hetzelfde artikel kan in twee aanbiedingen zitten
			if eerder := gezien[art.WebshopID]; eerder != nil {
				art.EAN, art.Hoeveelheid, art.Eenheid = eerder.EAN, eerder.Hoeveelheid, eerder.Eenheid
				art.PrijsPerEenheid, art.Basiseenheid = eerder.PrijsPerEenheid, eerder.Basiseenheid
				if eerder.EAN != "" {
					art.Categorie = eerder.Categorie
				}
				continue
			}
			if *producten >= 0 && opgehaald+zonderPagina >= *producten {
				continue
			}
			gezien[art.WebshopID] = art
			var p apiProduct
			err := k.haal(productCall, map[string]any{
				"ChannelId": "", "Locale": "nl-NL", "StoreId": "0", "StoreNumber": 0, "CheckoutId": "", "OrderEditId": "",
				"IsOrderEditMode": false, "TotalLineItemQuantity": 0, "HasDailyValueIntakePercent": false,
				"CartPromotionDeliveryDate": "1900-01-01", "LineItemQuantity": 0,
				"IsPhone": false, "_isPhoneInDataFetchStatus": 1, "OneWelcomeUserId": "", "_oneWelcomeUserIdInDataFetchStatus": 1,
				"SKU": art.WebshopID, "_sKUInDataFetchStatus": 1, "TotalCartItems": 0, "_totalCartItemsInDataFetchStatus": 1,
				"ProductName": art.Slug, "_productNameInDataFetchStatus": 1,
			}, basis+"/product/"+art.Slug, &p)
			time.Sleep(pauze)
			if err != nil {
				zonderPagina++
				fmt.Fprintf(os.Stderr, "product %s (%s) mislukt: %v\n", art.WebshopID, art.Titel, err)
				continue
			}
			opgehaald++
			art.EAN = p.ProductOut.Medicine.EAN
			art.Hoeveelheid, art.Eenheid = float64(p.ReferenceQuantity.Size), p.ReferenceQuantity.Symbol
			art.PrijsPerEenheid, art.Basiseenheid = float64(p.ProductOut.Overview.BaseUnitPrice), p.ReferenceQuantity.BaseUnit
			pad := []string{}
			for _, c := range p.ProductOut.Categories.List {
				pad = append(pad, c.Name)
			}
			if len(pad) > 0 {
				art.Categorie = strings.Join(pad, "/")
			}
		}
	}

	data, err = json.MarshalIndent(w, "", "  ")
	if err != nil {
		stop("omzetten mislukt: %v", err)
	}
	if err := os.WriteFile(uit, data, 0600); err != nil {
		stop("schrijven naar %s mislukt: %v", uit, err)
	}

	groepen, artikelen, leeg := 0, 0, 0
	for _, a := range w.Aanbiedingen {
		if a.Groep {
			groepen++
		}
		if len(a.Artikelen) == 0 {
			leeg++
		}
		artikelen += len(a.Artikelen)
	}
	fmt.Printf("aanbiedingen van %s tot %s opgeslagen in %s: %d aanbiedingen (%d groepen, %d mislukt, %d zonder artikelen), %d artikelen, %d keer gratis bezorging overgeslagen\n",
		w.Van, w.Tot, uit, len(w.Aanbiedingen), groepen, mislukt, leeg, artikelen, w.Overgeslagen)
	if *producten != 0 {
		fmt.Printf("productpagina's: %d opgehaald, %d mislukt\n", opgehaald, zonderPagina)
	}
}

func stop(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
