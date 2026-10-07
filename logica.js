// Logica: state en regels zonder DOM. Zie ARCHITECTURE.md.
// Roept alleen `Data` aan; app.js toont wat hier uitkomt. Nu de favorieten, de aanbiedingen bij de lijst en
// Voor jou: de rest van de logica staat nog in app.js en verhuist per onderdeel.
const Logica = (() => {
  // ---------- Favorieten ----------
  let favorieten = null; // eigen favorieten: { id, term, brand, category }; null = nog niet opgehaald
  const suggestieVraag = { term: 0, merk: 0 }; // volgnummers, zodat een laat antwoord een nieuwere vraag niet overschrijft
  const FAVORIET_VELDEN_MAX = 60; // gelijk aan de controle in de database

  // Dezelfde vorm als normalize_search in de database: kleine letters, zonder accenten, spaties ingedikt
  function zoekvorm(tekst) {
    return (tekst || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
  }

  function netjes(tekst) {
    return (tekst || "").replace(/\s+/g, " ").trim();
  }

  // ---------- Aanbiedingen bij de lijst ----------
  let deals = {};      // item-id -> [{ supermarkt, aantal }]: actuele aanbiedingen per item
  let dealsVraag = 0;  // volgnummer, zodat een laat antwoord een nieuwer antwoord niet overschrijft
  const WINKELS = { AH: "Albert Heijn", PLUS: "PLUS" }; // volledige naam bij de afkorting in deals

  // ---------- Voor jou ----------
  let voorjou = null;  // vaste producten uit het aankoopprofiel: { naam, dagen, om_de, laatste }; null = nog niet opgehaald
  let voorjouVraag = 0; // volgnummer, zodat een laat antwoord na uitloggen genegeerd wordt
  const nietNu = new Set(); // producten die je met "Niet nu" hebt weggetikt; geldt tot je de app sluit

  function dagenGeleden(dag) {
    return Math.floor((Date.now() - new Date(dag).getTime()) / 864e5);
  }

  return {
    zoekvorm,

    // ---------- Aanbiedingen bij de lijst ----------
    // De aanbiedingen bij één item, of undefined als er geen zijn
    dealsVan(itemId) { return deals[itemId]; },

    // Het zoeken gebeurt in de database (deals_for_list); we krijgen alleen per item terug bij welke
    // supermarkt er hoeveel aanbiedingen zijn. Geeft false bij een fout (dan gewoon geen labels) of als
    // er intussen een nieuwere vraag is gesteld.
    async laadDeals(lijstId) {
      const vraag = ++dealsVraag;
      const { data, error } = await Data.dealsVoorLijst(lijstId);
      if (vraag !== dealsVraag || error) return false;
      const nieuw = {};
      data.forEach((d) => (nieuw[d.item_id] ||= []).push(d));
      deals = nieuw;
      return true;
    },

    // Bij wisselen van lijst en uitloggen; een antwoord dat nog onderweg is hoort bij de vorige lijst
    vergeetDeals() {
      deals = {};
      dealsVraag++;
    },

    // De supermarkten met een aanbieding voluit, bijv. ["Albert Heijn", "PLUS"]
    dealWinkels(lijst) {
      return [...new Set(lijst.map((d) => WINKELS[d.supermarkt] || d.supermarkt))].sort((a, b) => a.localeCompare(b));
    },

    // ---------- Voor jou ----------
    // De vaste producten van het huishouden: de top 10 van de laatste 3 maanden uit het aankoopprofiel.
    voorJou() { return voorjou; },

    // `nogOpen` zegt of het scherm er nog op wacht. Geeft null als het antwoord niet meer nodig is.
    async laadVoorJou(nogOpen) {
      const vraag = ++voorjouVraag;
      const { data, error } = await Data.aankoopprofiel("3m", null);
      if (vraag !== voorjouVraag || !nogOpen()) return null;
      if (error) return { fout: error.message };
      voorjou = data.top;
      return {};
    },

    // Bij uitloggen: de volgende gebruiker begint leeg
    vergeetVoorJou() {
      voorjou = null;
      voorjouVraag++;
      nietNu.clear();
    },

    // "Niet nu": het product komt niet meer terug tot je de app sluit
    slaOver(naam) { nietNu.add(naam); },

    // Het gebruikelijke aantal dagen sinds de laatste aankoop is voorbij
    bijnaOp(product) {
      return product.om_de != null && dagenGeleden(product.laatste) >= Number(product.om_de);
    },

    // Wat er nog voor te stellen is: zonder wat al op de lijst staat (`namenOpLijst`) of is weggetikt.
    // Het product dat het verst over zijn gebruikelijke tussenpoos heen is staat bovenaan.
    voorJouOver(namenOpLijst) {
      const opLijst = new Set(namenOpLijst.map((n) => n.trim().toLowerCase()));
      const druk = (p) => (p.om_de == null ? 0 : dagenGeleden(p.laatste) / Number(p.om_de));
      return (voorjou || [])
        .filter((p) => !nietNu.has(p.naam) && !opLijst.has(p.naam.trim().toLowerCase()))
        .sort((a, b) => druk(b) - druk(a));
    },

    // ---------- Favorieten ----------
    favorieten() { return favorieten; },

    async laadFavorieten() {
      const { data, error } = await Data.favorieten();
      if (error) return { fout: error.message };
      favorieten = data;
      return {};
    },

    // Bij uitloggen: de volgende gebruiker begint leeg
    vergeetFavorieten() {
      favorieten = null;
      suggestieVraag.term++;
      suggestieVraag.merk++;
    },

    // Voegt een favoriet toe (id = null) of wijzigt er een. `suggestie` is de gekozen suggestie voor de term
    // ({ term, category }) of bij wijzigen de favoriet zelf; de categorie blijft alleen staan als de term
    // nog dezelfde is. Een zelf getypte term heeft geen categorie.
    async bewaarFavoriet(id, { term, merk, suggestie }) {
      const t = netjes(term);
      const m = netjes(merk);
      if (!t && !m) return { fout: "Vul een product of een merk in." };
      if (t.length > FAVORIET_VELDEN_MAX || m.length > FAVORIET_VELDEN_MAX) return { fout: `Gebruik hooguit ${FAVORIET_VELDEN_MAX} tekens.` };
      const dubbel = (favorieten || []).some((f) => f.id !== id && zoekvorm(f.term) === zoekvorm(t) && zoekvorm(f.brand) === zoekvorm(m));
      if (dubbel) return { fout: "Deze favoriet heb je al." };

      const zelfde = t && suggestie && zoekvorm(suggestie.term) === zoekvorm(t);
      const rij = { term: t || null, brand: m || null, category: zelfde ? suggestie.category || null : null };
      const { data, error } = id ? await Data.wijzigFavoriet(id, rij) : await Data.voegFavorietToe(rij);
      // 23505: de database vond hem toch dubbel (bijvoorbeeld toegevoegd op een ander toestel)
      if (error) return { fout: error.code === "23505" ? "Deze favoriet heb je al." : error.message };
      favorieten = id ? (favorieten || []).map((f) => (f.id === id ? data : f)) : [...(favorieten || []), data];
      return {};
    },

    // Haalt hem meteen uit de lijst; lukt het verwijderen niet, dan wordt de lijst opnieuw opgehaald
    async verwijderFavoriet(id) {
      favorieten = (favorieten || []).filter((f) => f.id !== id);
      const { error } = await Data.verwijderFavoriet(id);
      if (!error) return {};
      await this.laadFavorieten();
      return { fout: error.message };
    },

    // Suggesties tijdens het typen. soort is "term" ([{ term, category, articles }]) of "merk" ([{ brand, articles }]).
    // Geeft null als er intussen een nieuwere vraag is gesteld.
    async favorietSuggesties(soort, tekst) {
      const vraag = ++suggestieVraag[soort];
      const zoek = netjes(tekst);
      if (zoek.length < 2) return [];
      const { data, error } = soort === "term" ? await Data.favorietTermen(zoek) : await Data.favorietMerken(zoek);
      if (vraag !== suggestieVraag[soort]) return null;
      return error ? [] : data;
    },

    // Een late suggestie na het kiezen of opslaan moet niet alsnog openklappen
    stopSuggesties(soort) { suggestieVraag[soort]++; }
  };
})();
