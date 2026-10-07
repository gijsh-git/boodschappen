// Logica: state en regels zonder DOM. Zie ARCHITECTURE.md.
// Roept alleen `Data` aan; app.js toont wat hier uitkomt. Nu de favorieten, de aanbiedingen bij de lijst,
// Voor jou en de producten: de rest van de logica staat nog in app.js en verhuist per onderdeel.
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
  // Wat er precies in de aanbieding is, per item en aanbieding; null = nog niet opgehaald:
  // { item_id, id, supermarkt, titel, korting, geldig_tot, artikelen: [titel], artikelen_totaal }
  let dealDetails = null;
  let dealDetailsVraag = 0;
  const WINKELS = { AH: "Albert Heijn", PLUS: "PLUS" }; // volledige naam bij de afkorting van de supermarkt

  // ---------- Voor jou ----------
  let voorjou = null;  // vaste producten uit het aankoopprofiel: { naam, dagen, om_de, laatste }; null = nog niet opgehaald
  let voorjouVraag = 0; // volgnummer, zodat een laat antwoord na uitloggen genegeerd wordt
  const nietNu = new Set(); // producten die je met "Niet nu" hebt weggetikt; geldt tot je de app sluit
  // Geldige aanbiedingen die voor jou tellen, in de volgorde van de database (favorieten eerst):
  // { id, supermarkt, titel, korting, geldig_tot, favorieten: [{ term, brand, artikel }], producten: [{ naam, dagen }] }
  let aanbiedingen = null; // null = nog niet opgehaald
  let aanbiedingenVraag = 0;

  // ---------- Producten ----------
  let producten = null;  // alle producten: { id, name, namen, aankopen, telt_mee }; null = nog niet opgehaald
  let productOpen = null; // id van het product dat is opengeklapt
  let productHerkomst = {}; // product-id -> de samenvoegingen die nog in dat product zitten
  let samenvoegBron = null; // product dat je aan het samenvoegen bent; de volgende tik kiest het doel
  // Artikel → product, niveau 2: { voorstellen: [rij], gekoppeld: [rij] }; null = nog niet opgehaald
  // rij: { supermarkt, artikel_id, titel, merk, inhoud, categorie, product_id, product, zekerheid, reden, bron }
  let koppelingen = null;
  const ZEKERHEID = { high: "hoog", medium: "middel", low: "laag" };

  function dagenGeleden(dag) {
    return Math.floor((Date.now() - new Date(dag).getTime()) / 864e5);
  }

  return {
    zoekvorm,

    // ---------- Aanbiedingen bij de lijst ----------
    // De aanbiedingen bij één item, of undefined als er geen zijn
    dealsVan(itemId) { return deals[itemId]; },

    // Het zoeken gebeurt in de database (offers_for_list); we krijgen alleen per item terug bij welke
    // supermarkt er hoeveel aanbiedingen zijn. Geeft false bij een fout (dan gewoon geen labels) of als
    // er intussen een nieuwere vraag is gesteld.
    async laadDeals(lijstId) {
      const vraag = ++dealsVraag;
      const { data, error } = await Data.aanbiedingenVoorLijst(lijstId);
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
      dealDetails = null;
      dealDetailsVraag++;
    },

    // De aanbiedingen bij de items van de lijst, voor het paneel onder de groene balk
    dealDetails() { return dealDetails; },

    // Geeft null als er intussen een nieuwere vraag is gesteld of de lijst is losgelaten
    async laadDealDetails(lijstId) {
      const vraag = ++dealDetailsVraag;
      const { data, error } = await Data.aanbiedingenBijLijst(lijstId);
      if (vraag !== dealDetailsVraag) return null;
      if (error) return { fout: error.message };
      dealDetails = data;
      return {};
    },

    winkelNaam(supermarkt) { return WINKELS[supermarkt] || supermarkt; },

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
      aanbiedingen = null;
      aanbiedingenVraag++;
    },

    // De aanbiedingen die voor jou tellen: via je eigen favorieten en via de vaste producten van het huishouden.
    // Zoeken en rangorde gebeuren in de database (offers_for_me).
    aanbiedingen() { return aanbiedingen; },

    // `nogOpen` zegt of het scherm er nog op wacht. Geeft null als het antwoord niet meer nodig is.
    async laadAanbiedingen(nogOpen) {
      const vraag = ++aanbiedingenVraag;
      const { data, error } = await Data.aanbiedingenVoorMij();
      if (vraag !== aanbiedingenVraag || !nogOpen()) return null;
      if (error) return { fout: error.message };
      aanbiedingen = data;
      return {};
    },

    // Wat er op de lijst komt bij "zet op lijst". Via een favoriet: de aanbieding zelf, want de term zegt niet
    // wat er in de bonus is ("banaan" bij een aanbieding op verse sappen). Via het profiel: het vaste product.
    aanbiedingNaam(aanbieding) {
      if (aanbieding.favorieten.length === 0) return aanbieding.producten[0].naam;
      return aanbieding.titel.replace(/\s*\*+$/, ""); // "Alle Perla*": het sterretje verwijst naar de kleine lettertjes
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
    stopSuggesties(soort) { suggestieVraag[soort]++; },

    // ---------- Producten ----------
    // Alleen voor de beheerder. Een product is een verzameling namen (aliassen); samenvoegen verhuist
    // de namen van het ene product naar het andere.
    producten() { return producten; },
    productOpen() { return productOpen; },
    samenvoegBron() { return samenvoegBron; },
    // De samenvoegingen die nog in een product zitten, of undefined als ze nog niet zijn opgehaald
    herkomstVan(productId) { return productHerkomst[productId]; },

    // Bij het openen van het scherm en bij uitloggen: alles opnieuw
    vergeetProducten() {
      producten = null;
      productOpen = null;
      productHerkomst = {};
      samenvoegBron = null;
      koppelingen = null;
    },

    async laadProducten() {
      const { data, error } = await Data.productOverzicht();
      if (error) return { fout: error.message };
      producten = data;
      return {};
    },

    // Pas ophalen als je het product openklapt
    async laadHerkomst(productId) {
      const { data, error } = await Data.productHerkomst(productId);
      if (error) return { fout: error.message };
      productHerkomst[productId] = data;
      return {};
    },

    // Welk product openstaat (null = geen). De herkomst wordt daarna opnieuw opgehaald.
    openProduct(productId) { productOpen = productId; },
    // Na een wijziging: samenvoegen en losmaken raken meerdere producten tegelijk
    wisHerkomst() { productHerkomst = {}; },

    // Het product dat je gaat samenvoegen (de volgende tik kiest het doel), of null om te stoppen
    kiesSamenvoegBron(product) { samenvoegBron = product; },

    // Wat het scherm toont: zonder het product dat je aan het samenvoegen bent, gefilterd op naam of alias
    gefilterdeProducten(zoekTekst) {
      const zoek = zoekTekst.trim().toLowerCase();
      return (producten || []).filter((p) =>
        (!samenvoegBron || p.id !== samenvoegBron.id) &&
        (!zoek || p.name.toLowerCase().includes(zoek) || p.namen.some((n) => n.includes(zoek))));
    },

    async voegSamen(bron, doel) {
      const { error } = await Data.voegProductenSamen(bron.id, doel.id);
      if (error) return { fout: error.message };
      samenvoegBron = null;
      return {};
    },

    async maakLos(samenvoeging) {
      const { error } = await Data.maakSamenvoegenOngedaan(samenvoeging.id);
      return error ? { fout: error.message } : {};
    },

    async hernoemProduct(product, naam) {
      const { data, error } = await Data.hernoemProduct(product.id, naam);
      if (error) return { fout: error.message };
      product.name = data.name;
      return {};
    },

    // Voor dingen die geen boodschappen zijn (draagtas, plastic zak): buiten het aankoopprofiel houden
    async zetProductTelt(product, aan) {
      const { data, error } = await Data.zetProductProfiel(product.id, aan);
      if (error) return { fout: error.message };
      product.telt_mee = data.counts_in_profile;
      return {};
    },

    // ---------- Artikelen koppelen (niveau 2) ----------
    // Een script buiten de app stelt per artikel uit de aanbiedingen een product voor; de beheerder keurt goed.
    async laadKoppelingen() {
      const { data, error } = await Data.artikelKoppelingen();
      if (error) return { fout: error.message };
      koppelingen = data;
      return {};
    },

    // De voorstellen per product: [{ product_id, product, voorstellen: [rij] }], in de volgorde van de database.
    // twijfel = true geeft de voorstellen met zekerheid laag, anders die met hoog en middel.
    voorstelGroepen(twijfel) {
      const groepen = [];
      const per = {};
      ((koppelingen && koppelingen.voorstellen) || [])
        .filter((v) => (v.zekerheid === "low") === twijfel)
        .forEach((v) => {
          if (!per[v.product_id]) groepen.push(per[v.product_id] = { product_id: v.product_id, product: v.product, voorstellen: [] });
          per[v.product_id].voorstellen.push(v);
        });
      return groepen;
    },

    // De goedgekeurde artikelen bij één product
    gekoppeldBij(productId) {
      return ((koppelingen && koppelingen.gekoppeld) || []).filter((k) => k.product_id === productId);
    },

    zekerheidNaam(code) { return ZEKERHEID[code] || code; },

    // Eén voorstel of een hele groep goedkeuren. Het product gaat mee, zodat de database alleen goedkeurt
    // wat hier te zien was.
    async keurGoed(voorstellen) {
      const { error } = await Data.keurKoppelingenGoed(
        voorstellen.map((v) => ({ supermarket: v.supermarkt, article_id: v.artikel_id, product_id: v.product_id })));
      const uit = await this.laadKoppelingen();
      return error ? { fout: error.message } : uit;
    },

    // Een voorstel afwijzen of een goedgekeurde koppeling losmaken: die combinatie wordt niet meer voorgesteld
    async wijsAf(rij) {
      const { error } = await Data.wijsKoppelingAf(rij.supermarkt, rij.artikel_id);
      const uit = await this.laadKoppelingen();
      return error ? { fout: error.message } : uit;
    }
  };
})();
