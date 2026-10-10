// Haalt de AH-bonus van de lopende week op, met per aanbieding de artikelen, en zet die in een JSON-bestand,
// in het formaat dat voor elke winkel gelijk is (zie scripts/aanbiedingen-opslaan.py).
// Alleen lezen, met een anoniem token: er is geen AH-account voor nodig en er wordt niets ingelogd.
// Elk artikel heeft twee id's: webshop_id (de webwinkel) en artikel_id, bij AH het hqId. Dat is het product_id dat op een kassabon staat.
// Alleen de landelijke AH-bonus; Gall & Gall, Etos en de online aanbiedingen blijven buiten beschouwing.
//
// Gebruik:
//
//	cd scripts/ah-bonus && go run . ../../data/ah-aanbiedingen.json
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"

	appie "github.com/gwillem/appie-go"
)

// De artikelen van een bonusgroep ("Alle Hak potten") komen niet met de categorie mee, maar per groep
const groepVraag = `query BonusGroep($id: String, $van: String, $tot: String) {
	bonusPromotions(input: {
		id: $id, periodStart: $van, periodEnd: $tot,
		filterUnavailableProducts: false, forcePromotionVisibility: true, showAllPromotionSegments: true
	}) {
		productCount
		products {
			id hqId title brand category salesUnitSize
			priceV2(periodStart: $van, periodEnd: $tot, filterUnavailableProducts: false, forcePromotionVisibility: true) {
				now { amount }
				was { amount }
			}
		}
	}
}`

type artikel struct {
	WebshopID int    `json:"webshop_id"`
	HqID      int    `json:"artikel_id,omitempty"`
	Titel     string `json:"titel"`
	Merk      string `json:"merk,omitempty"`
	Inhoud    string `json:"inhoud,omitempty"`
	// Bij een losse aanbieding alleen de subcategorie, bij een groep "hoofdcategorie/subcategorie"
	Categorie string  `json:"categorie,omitempty"`
	Prijs     float64 `json:"prijs,omitempty"`
	// Alleen gevuld als AH een bonusprijs per stuk geeft; bij "2e halve prijs" is die er niet
	Bonusprijs float64 `json:"actieprijs,omitempty"`
}

type label struct {
	Code         string  `json:"code"`
	Omschrijving string  `json:"omschrijving"`
	Aantal       int     `json:"aantal,omitempty"`
	Gratis       int     `json:"gratis,omitempty"`
	Prijs        float64 `json:"prijs,omitempty"`
	Percentage   float64 `json:"percentage,omitempty"`
	Bedrag       float64 `json:"bedrag,omitempty"`
}

type aanbieding struct {
	ID        string  `json:"id"`
	Titel     string  `json:"titel"`
	Korting   string  `json:"korting"`
	Labels    []label `json:"labels"`
	Categorie string  `json:"categorie"`
	Van       string  `json:"van"`
	Tot       string  `json:"tot"`
	// true: een bonusgroep met meerdere artikelen; false: één los artikel
	Groep        bool      `json:"groep"`
	AlleenWinkel bool      `json:"alleen_winkel,omitempty"`
	Artikelen    []artikel `json:"artikelen"`
	// Wat AH zelf als aantal artikelen opgeeft; kan afwijken van wat er is teruggekomen
	AantalVolgensAH int `json:"aantal_volgens_ah,omitempty"`
	// true: de artikelen van deze groep ophalen is mislukt, de lijst hierboven is dus niet compleet
	Mislukt bool `json:"mislukt,omitempty"`
}

type week struct {
	Winkel       string       `json:"winkel"`
	Van          string       `json:"van"`
	Tot          string       `json:"tot"`
	Opgehaald    string       `json:"opgehaald"`
	Aanbiedingen []aanbieding `json:"aanbiedingen"`
}

type apiLabel struct {
	Code               string  `json:"code"`
	DefaultDescription string  `json:"defaultDescription"`
	Count              int     `json:"count"`
	FreeCount          int     `json:"freeCount"`
	Price              float64 `json:"price"`
	Percentage         float64 `json:"percentage"`
	Amount             float64 `json:"amount"`
}

func labels(in []apiLabel) []label {
	uit := []label{}
	for _, l := range in {
		uit = append(uit, label{l.Code, l.DefaultDescription, l.Count, l.FreeCount, l.Price, l.Percentage, l.Amount})
	}
	return uit
}

// Een verzoek aan AH mislukt af en toe zonder reden; een paar keer proberen voorkomt een halve week
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

func main() {
	if len(os.Args) != 2 {
		stop("gebruik: go run . <pad naar ah-aanbiedingen.json>")
	}
	uit := os.Args[1]

	ctx := context.Background()
	c := appie.New()
	if err := c.GetAnonymousToken(ctx); err != nil {
		stop("anoniem token ophalen mislukt: %v", err)
	}

	var meta struct {
		Periods []struct {
			BonusStartDate string `json:"bonusStartDate"`
			BonusEndDate   string `json:"bonusEndDate"`
			Tabs           []struct {
				URLMetadataList []struct {
					BonusType   string `json:"bonusType"`
					Description string `json:"description"`
				} `json:"urlMetadataList"`
			} `json:"tabs"`
		} `json:"periods"`
	}
	if err := probeer(func() error {
		return c.DoRequest(ctx, http.MethodGet, "/mobile-services/bonuspage/v3/metadata", nil, &meta)
	}); err != nil {
		stop("bonusweek ophalen mislukt: %v", err)
	}
	if len(meta.Periods) == 0 {
		stop("AH geeft geen bonusweek terug")
	}
	periode := meta.Periods[0]
	w := week{Winkel: "AH", Van: periode.BonusStartDate, Tot: periode.BonusEndDate, Opgehaald: time.Now().Format(time.RFC3339)}

	// Dezelfde categorie staat onder meerdere tabbladen
	var categorieen []string
	gezienCat := map[string]bool{}
	for _, tab := range periode.Tabs {
		for _, m := range tab.URLMetadataList {
			if m.BonusType == "NATIONAL" && !gezienCat[m.Description] {
				gezienCat[m.Description] = true
				categorieen = append(categorieen, m.Description)
			}
		}
	}

	gezien := map[string]bool{}
	for _, cat := range categorieen {
		var sectie struct {
			BonusGroupOrProducts []struct {
				Product *struct {
					WebshopID               int        `json:"webshopId"`
					HqID                    int        `json:"hqId"`
					Title                   string     `json:"title"`
					Brand                   string     `json:"brand"`
					SalesUnitSize           string     `json:"salesUnitSize"`
					SubCategory             string     `json:"subCategory"`
					SegmentID               string     `json:"segmentId"`
					BonusSegmentDescription string     `json:"bonusSegmentDescription"`
					BonusMechanism          string     `json:"bonusMechanism"`
					DiscountLabels          []apiLabel `json:"discountLabels"`
					BonusStartDate          string     `json:"bonusStartDate"`
					BonusEndDate            string     `json:"bonusEndDate"`
					PriceBeforeBonus        float64    `json:"priceBeforeBonus"`
					CurrentPrice            float64    `json:"currentPrice"`
					IsBonusPrice            bool       `json:"isBonusPrice"`
				} `json:"product"`
				BonusGroup *struct {
					ID                  string     `json:"id"`
					SegmentDescription  string     `json:"segmentDescription"`
					DiscountDescription string     `json:"discountDescription"`
					DiscountLabels      []apiLabel `json:"discountLabels"`
					BonusStartDate      string     `json:"bonusStartDate"`
					BonusEndDate        string     `json:"bonusEndDate"`
					StoreOnlyPromotion  bool       `json:"storeOnlyPromotion"`
				} `json:"bonusGroup"`
			} `json:"bonusGroupOrProducts"`
		}
		params := url.Values{}
		params.Set("application", "AHWEBSHOP")
		params.Set("date", w.Van)
		params.Set("promotionType", "NATIONAL")
		params.Set("category", cat)
		if err := probeer(func() error {
			return c.DoRequest(ctx, http.MethodGet, "/mobile-services/bonuspage/v2/section?"+params.Encode(), nil, &sectie)
		}); err != nil {
			stop("categorie %s ophalen mislukt: %v", cat, err)
		}
		for _, x := range sectie.BonusGroupOrProducts {
			if p := x.Product; p != nil {
				id := p.SegmentID
				if id == "" {
					id = "artikel-" + strconv.Itoa(p.WebshopID)
				}
				if gezien[id] {
					continue
				}
				gezien[id] = true
				a := artikel{p.WebshopID, p.HqID, p.Title, p.Brand, p.SalesUnitSize, p.SubCategory, p.PriceBeforeBonus, 0}
				if p.IsBonusPrice {
					a.Bonusprijs = p.CurrentPrice
				}
				titel := p.BonusSegmentDescription
				if titel == "" {
					titel = p.Title
				}
				w.Aanbiedingen = append(w.Aanbiedingen, aanbieding{
					ID: id, Titel: titel, Korting: p.BonusMechanism, Labels: labels(p.DiscountLabels),
					Categorie: cat, Van: p.BonusStartDate, Tot: p.BonusEndDate, Artikelen: []artikel{a},
				})
			}
			if g := x.BonusGroup; g != nil && !gezien[g.ID] {
				gezien[g.ID] = true
				w.Aanbiedingen = append(w.Aanbiedingen, aanbieding{
					ID: g.ID, Titel: g.SegmentDescription, Korting: g.DiscountDescription, Labels: labels(g.DiscountLabels),
					Categorie: cat, Van: g.BonusStartDate, Tot: g.BonusEndDate, Groep: true,
					AlleenWinkel: g.StoreOnlyPromotion, Artikelen: []artikel{},
				})
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "%d aanbiedingen in %d categorieën\n", len(w.Aanbiedingen), len(categorieen))

	mislukt := 0
	for i := range w.Aanbiedingen {
		a := &w.Aanbiedingen[i]
		if !a.Groep {
			continue
		}
		var antwoord struct {
			BonusPromotions []struct {
				ProductCount int `json:"productCount"`
				Products     []struct {
					ID            int    `json:"id"`
					HqID          int    `json:"hqId"`
					Title         string `json:"title"`
					Brand         string `json:"brand"`
					Category      string `json:"category"`
					SalesUnitSize string `json:"salesUnitSize"`
					PriceV2       struct {
						Now struct {
							Amount float64 `json:"amount"`
						} `json:"now"`
						Was struct {
							Amount float64 `json:"amount"`
						} `json:"was"`
					} `json:"priceV2"`
				} `json:"products"`
			} `json:"bonusPromotions"`
		}
		vars := map[string]any{"id": a.ID, "van": w.Van, "tot": w.Tot}
		if err := probeer(func() error { return c.DoGraphQL(ctx, groepVraag, vars, &antwoord) }); err != nil {
			mislukt++
			a.Mislukt = true
			fmt.Fprintf(os.Stderr, "groep %s (%s) mislukt: %v\n", a.ID, a.Titel, err)
		} else if len(antwoord.BonusPromotions) > 0 {
			g := antwoord.BonusPromotions[0]
			a.AantalVolgensAH = g.ProductCount
			for _, p := range g.Products {
				art := artikel{p.ID, p.HqID, p.Title, p.Brand, p.SalesUnitSize, p.Category, p.PriceV2.Was.Amount, 0}
				// Zonder "was" is "now" de gewone prijs
				if art.Prijs == 0 {
					art.Prijs = p.PriceV2.Now.Amount
				} else {
					art.Bonusprijs = p.PriceV2.Now.Amount
				}
				a.Artikelen = append(a.Artikelen, art)
			}
		}
		time.Sleep(400 * time.Millisecond)
	}

	data, err := json.MarshalIndent(w, "", "  ")
	if err != nil {
		stop("omzetten mislukt: %v", err)
	}
	if err := os.WriteFile(uit, data, 0600); err != nil {
		stop("schrijven naar %s mislukt: %v", uit, err)
	}

	groepen, artikelen := 0, 0
	for _, a := range w.Aanbiedingen {
		if a.Groep {
			groepen++
		}
		artikelen += len(a.Artikelen)
	}
	fmt.Printf("bonus van %s tot %s opgeslagen in %s: %d aanbiedingen (%d groepen, %d mislukt), %d artikelen\n",
		w.Van, w.Tot, uit, len(w.Aanbiedingen), groepen, mislukt, artikelen)
}

func stop(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
