// Haalt alle AH-kassabonnen met details op en zet ze in data/ah-bonnen.json.
// Alleen lezen: er worden twee soorten vragen gesteld (lijst van bonnen, details van één bon).
// Het product_id op een bon is geen id uit de webwinkel; de volledige productnaam is er dus niet mee op te zoeken.
// Inloggen gaat via ah-mcp (ah_login); dit script gebruikt de tokens die dat opslaat.
//
// Gebruik:
//
//	cd scripts/ah-bonnen && go run . ../../data/ah-bonnen.json
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	appie "github.com/gwillem/appie-go"
)

// AH geeft de bonnen per pagina; de bibliotheek zelf vraagt alleen de eerste 100 op
const lijstVraag = `query FetchPosReceipts($offset: Int!, $limit: Int!) {
	posReceiptsPage(pagination: {offset: $offset, limit: $limit}) {
		posReceipts { id dateTime totalAmount { amount } }
	}
}`

const perPagina = 100

type regel struct {
	Naam      string  `json:"naam"`
	Aantal    int     `json:"aantal"`
	Stukprijs float64 `json:"stukprijs,omitempty"`
	Bedrag    float64 `json:"bedrag"`
	ProductID int     `json:"product_id,omitempty"`
}

type korting struct {
	Naam   string  `json:"naam"`
	Bedrag float64 `json:"bedrag"`
}

type bon struct {
	ID        string    `json:"id"`
	Datum     string    `json:"datum"`
	Totaal    float64   `json:"totaal"`
	Regels    []regel   `json:"regels"`
	Kortingen []korting `json:"kortingen"`
	// false: de details konden (nog) niet worden opgehaald; opnieuw draaien probeert het weer
	Compleet bool `json:"compleet"`
}

func main() {
	if len(os.Args) != 2 {
		stop("gebruik: go run . <pad naar ah-bonnen.json>")
	}
	uit := os.Args[1]

	configMap, err := os.UserConfigDir()
	if err != nil {
		stop("kan de map met instellingen niet vinden: %v", err)
	}
	c, err := appie.NewWithConfig(filepath.Join(configMap, "ah-mcp", "tokens.json"))
	if err != nil || !c.IsAuthenticated() {
		stop("niet ingelogd bij AH; log eerst in via ah-mcp (ah_login)")
	}
	ctx := context.Background()

	// Wat er al is opgehaald blijft staan, zodat opnieuw draaien alleen het ontbrekende ophaalt
	bekend := map[string]bon{}
	if data, err := os.ReadFile(uit); err == nil {
		var oud []bon
		if err := json.Unmarshal(data, &oud); err != nil {
			stop("%s is geen geldig bestand: %v", uit, err)
		}
		for _, b := range oud {
			bekend[b.ID] = b
		}
	}

	var bonnen []bon
	gezien := map[string]bool{}
	for offset := 0; ; offset += perPagina {
		var antwoord struct {
			PosReceiptsPage struct {
				PosReceipts []struct {
					ID          string `json:"id"`
					DateTime    string `json:"dateTime"`
					TotalAmount struct {
						Amount float64 `json:"amount"`
					} `json:"totalAmount"`
				} `json:"posReceipts"`
			} `json:"posReceiptsPage"`
		}
		vars := map[string]any{"offset": offset, "limit": perPagina}
		if err := c.DoGraphQL(ctx, lijstVraag, vars, &antwoord); err != nil {
			// Verder terug dan AH toelaat geeft een fout; wat we al hebben is dan alles
			if offset == 0 {
				stop("bonnen ophalen mislukt: %v", err)
			}
			fmt.Fprintf(os.Stderr, "pagina vanaf %d gaf een fout, daar stopt de lijst: %v\n", offset, err)
			break
		}
		pagina := antwoord.PosReceiptsPage.PosReceipts
		nieuw := 0
		for _, r := range pagina {
			if gezien[r.ID] {
				continue
			}
			gezien[r.ID] = true
			nieuw++
			bonnen = append(bonnen, bon{ID: r.ID, Datum: r.DateTime, Totaal: r.TotalAmount.Amount})
		}
		// Laatste pagina, of AH geeft steeds dezelfde bonnen terug
		if len(pagina) < perPagina || nieuw == 0 {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "%d bonnen gevonden\n", len(bonnen))

	mislukt := 0
	for i := range bonnen {
		b := &bonnen[i]
		if oud, ok := bekend[b.ID]; ok && oud.Compleet {
			b.Regels, b.Kortingen, b.Compleet = oud.Regels, oud.Kortingen, true
			continue
		}
		details, err := c.GetReceipt(ctx, b.ID)
		if err != nil {
			mislukt++
			fmt.Fprintf(os.Stderr, "bon %d van %d mislukt: %v\n", i+1, len(bonnen), err)
		} else {
			b.Regels = []regel{}
			for _, it := range details.Items {
				b.Regels = append(b.Regels, regel{it.Description, it.Quantity, it.UnitPrice, it.Amount, it.ProductID})
			}
			b.Kortingen = []korting{}
			for _, k := range details.Discounts {
				b.Kortingen = append(b.Kortingen, korting{k.Name, k.Amount})
			}
			b.Compleet = true
		}
		// Rustig aan, en tussendoor bewaren zodat een onderbreking niets kost
		if (i+1)%20 == 0 {
			bewaar(uit, bonnen)
			fmt.Fprintf(os.Stderr, "%d van %d\n", i+1, len(bonnen))
		}
		time.Sleep(400 * time.Millisecond)
	}
	bewaar(uit, bonnen)

	// Alleen aantallen en periode tonen, niet de aankopen zelf
	if len(bonnen) > 0 {
		fmt.Printf("%d bonnen opgeslagen in %s (%d zonder details), van %.10s tot %.10s\n",
			len(bonnen), uit, mislukt, bonnen[len(bonnen)-1].Datum, bonnen[0].Datum)
	} else {
		fmt.Println("geen bonnen gevonden")
	}

}

func bewaar(pad string, bonnen []bon) {
	data, err := json.MarshalIndent(bonnen, "", "  ")
	if err != nil {
		stop("omzetten mislukt: %v", err)
	}
	if err := os.WriteFile(pad, data, 0600); err != nil {
		stop("schrijven naar %s mislukt: %v", pad, err)
	}
}

func stop(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
