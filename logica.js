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
  let deals = {};      // item-id -> [{ supermarkt, aantal }]: actuele aanbiedingen per item, zonder wat is weggeklikt
  let wegPerItem = {}; // item-id -> hoeveel aanbiedingen er bij dat item zijn weggeklikt
  let dealsVraag = 0;  // volgnummer, zodat een laat antwoord een nieuwer antwoord niet overschrijft
  // Wat er precies in de aanbieding is, per item en aanbieding; null = nog niet opgehaald:
  // { item_id, id, supermarkt, titel, korting, geldig_tot, artikelen: [titel], artikelen_totaal, artikelen_zelfde, gekozen,
  //   weggeklikt_door: id van wie de aanbieding bij dit item heeft weggeklikt, of null }
  // In de volgorde van de database: per item, en daarbinnen eerst de aanbiedingen met dezelfde variant als het item.
  let dealDetails = null;
  let dealDetailsVraag = 0;
  const WINKELS = { AH: "Albert Heijn", PLUS: "PLUS" }; // volledige naam bij de afkorting van de supermarkt
  // De aanbieding die je in het paneel aan het kiezen bent, of null:
  // { itemId, aanbiedingId, opties: [{ artikel_id, titel, zelfde, past, gekozen }] of null (nog bezig),
  //   aan: Set van aangevinkte artikel-id's, aantal: Map van artikel-id naar aantal (ontbreekt = 1),
  //   alles: de hele aanbieding tonen in plaats van de eerste KEUZE_TOON }
  let keuze = null;
  const KEUZE_MAX = 99; // hoogste aantal per artikel
  const KEUZE_TOON = 5; // zoveel artikelen zie je voordat je de rest uitvouwt

  // ---------- Voor jou ----------
  let voorjou = null;  // vaste producten uit het aankoopprofiel: { naam, dagen, om_de, laatste }; null = nog niet opgehaald
  let voorjouVraag = 0; // volgnummer, zodat een laat antwoord na uitloggen genegeerd wordt
  const nietNu = new Set(); // producten die je met "Niet nu" hebt weggetikt; geldt tot je de app sluit
  // Geldige aanbiedingen die voor jou tellen, in de volgorde van de database (favorieten eerst):
  // { id, supermarkt, titel, korting, geldig_tot, favorieten: [{ term, brand, artikel }], producten: [{ naam, dagen }] }
  let aanbiedingen = null; // null = nog niet opgehaald
  let aanbiedingenVraag = 0;

  // ---------- Koppelingen ----------
  // Alleen voor de beheerder. { termen, artikelen, zonder_type, types } uit type_link_overview(); null = nog niet opgehaald
  //   termen:      [{ sleutel, term, type_id, type, merk, zekerheid, reden, voorstel, op }]
  //   artikelen:   [{ supermarkt, artikel_id, titel, merk, inhoud, categorie, type_id, type, zekerheid, reden }]
  //   zonder_type: [{ supermarkt, artikel_id, titel, merk, inhoud, categorie, zekerheid, reden, voorstel }]
  //   types:       [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder, telt_mee, artikelen, namen, aankopen }]
  let koppelingen = null;
  let typeOpen = null; // id van het type dat is opengeklapt
  let typeDetails = {}; // type-id -> { namen, artikelen }, pas opgehaald bij openklappen
  const ZEKERHEID = { high: "hoog", medium: "middel", low: "laag" };

  // De artikelen die je bij het kiezen ziet: de eerste KEUZE_TOON waar het item voor staat (de database zet
  // dezelfde variant vooraan), en na uitvouwen de hele aanbieding. Staat het item voor geen enkel artikel
  // (gekozen via Voor jou), dan de eerste KEUZE_TOON van de aanbieding.
  function zichtbareKeuzes() {
    if (!keuze || !keuze.opties) return [];
    if (keuze.alles) return keuze.opties;
    const passend = keuze.opties.filter((o) => o.past || o.zelfde || o.gekozen);
    return (passend.length ? passend : keuze.opties).slice(0, KEUZE_TOON);
  }

  // ---------- Een item op de lijst ----------
  // Het aantal zoals het vóór de titel staat: een kaal getal wordt "2×" en één stuks tonen we niet;
  // met een eenheid ("500 g", "2 pak") blijft het zoals het is getypt
  function aantalTekst(hoeveelheid) {
    const tekst = netjes(hoeveelheid);
    const kaal = tekst.match(/^(\d+)\s*[x×]?$/i);
    if (!kaal) return tekst;
    return Number(kaal[1]) > 1 ? Number(kaal[1]) + "×" : "";
  }

  // Hoeveel stuks er op de lijst staan: 1 zonder aantal, null als er een eenheid bij staat (niet te tellen)
  function aantalStuks(hoeveelheid) {
    const tekst = netjes(hoeveelheid);
    if (!tekst) return 1;
    const kaal = tekst.match(/^(\d+)\s*[x×]?$/i);
    return kaal ? Number(kaal[1]) : null;
  }

  // Hoeveel je er moet kopen voor de korting: "2 voor 3.99" en "2e halve prijs" 2, "1+1 gratis" 2,
  // "2+1 gratis" 3; null bij een korting die al bij één stuk geldt
  function nodigVoorKorting(korting) {
    const tekst = (korting || "").toLowerCase();
    const voor = tekst.match(/^(\d+)\s*voor\b/) || tekst.match(/^(\d+)e\s+(?:halve prijs|gratis)/);
    if (voor) return Number(voor[1]) > 1 ? Number(voor[1]) : null;
    const gratis = tekst.match(/^(\d+)\s*\+\s*(\d+)\s*gratis/);
    return gratis ? Number(gratis[1]) + Number(gratis[2]) : null;
  }

  function dagenGeleden(dag) {
    return Math.floor((Date.now() - new Date(dag).getTime()) / 864e5);
  }

  return {
    zoekvorm,

    // ---------- Een item op de lijst ----------
    // Wat er op de rij van een item staat:
    // { aantal: "2×" of "500 g" of "", voor: de oorspronkelijke term of null, label: de korting, "Bonus" of null,
    //   geldigTot: laatste dag van de aanbieding of null, nodig: stuks voor de korting als er nu minder staan, anders null }
    itemRegel(item) {
      // Gekozen, of de aanbieding zelf op de lijst (vanuit Voor jou): de korting en tot wanneer
      const keuze = this.keuzeVan(item);
      const vast = keuze || this.eigenAanbieding(item.id);
      const nodig = vast ? nodigVoorKorting(vast.korting) : null;
      const stuks = aantalStuks(item.quantity);
      return {
        aantal: aantalTekst(item.quantity),
        voor: keuze ? keuze.voor : null,
        label: vast ? vast.korting || "Bonus" : deals[item.id] ? "Bonus" : null,
        geldigTot: vast ? vast.geldigTot : null,
        nodig: nodig && stuks !== null && stuks < nodig ? nodig : null
      };
    },

    // ---------- Aanbiedingen bij de lijst ----------
    // De aanbiedingen bij één item, of undefined als er geen zijn
    dealsVan(itemId) { return deals[itemId]; },

    // Staat de aanbieding zelf op de lijst (vanuit Voor jou), dan haar korting en laatste dag voor het
    // label: { korting, geldigTot }; anders null
    eigenAanbieding(itemId) {
      const eigen = (deals[itemId] || []).find((d) => d.korting);
      // de bron schrijft "2 VOOR 5.99"
      return eigen ? { korting: eigen.korting.toLowerCase(), geldigTot: eigen.geldig_tot } : null;
    },

    // Het zoeken gebeurt in de database (offers_for_list); we krijgen alleen per item terug bij welke
    // supermarkt er hoeveel aanbiedingen zijn. Geeft false bij een fout (dan gewoon geen labels) of als
    // er intussen een nieuwere vraag is gesteld.
    async laadDeals(lijstId) {
      const vraag = ++dealsVraag;
      const { data, error } = await Data.aanbiedingenVoorLijst(lijstId);
      if (vraag !== dealsVraag || error) return false;
      const nieuw = {};
      const weg = {};
      data.forEach((d) => {
        if (d.aantal > 0) (nieuw[d.item_id] ||= []).push(d);
        if (d.weggeklikt > 0) weg[d.item_id] = (weg[d.item_id] || 0) + d.weggeklikt;
      });
      deals = nieuw;
      wegPerItem = weg;
      return true;
    },

    // Hoeveel aanbiedingen er bij deze items zijn weggeklikt ("Niet deze week")
    aantalWeggeklikt(items) { return items.reduce((som, i) => som + (wegPerItem[i.id] || 0), 0); },

    // "Niet deze week" bij een item, en terughalen: geldt voor de hele lijst. Geeft {} of { fout }.
    async klikWeg(itemId, aanbiedingId) {
      const { error } = await Data.klikAanbiedingWeg(itemId, aanbiedingId);
      if (error) return { fout: error.message };
      if (keuze && keuze.itemId === itemId && keuze.aanbiedingId === aanbiedingId) keuze = null;
      return {};
    },
    async haalTerug(itemId, aanbiedingId) {
      const { error } = await Data.haalAanbiedingTerug(itemId, aanbiedingId);
      return error ? { fout: error.message } : {};
    },

    // Wegklikken geldt voor een aanbieding die via de naam bij het item hoort, niet voor de aanbieding die
    // zelf op de lijst staat (vanuit Voor jou)
    kanWegklikken(detail, item) { return item.offer_id !== detail.id; },

    // "Niet deze week" in Voor jou: alleen voor jezelf, tot de aanbieding verloopt. Geeft {} of { fout }.
    async klikWegVoorMij(aanbiedingId) {
      const { error } = await Data.klikAanbiedingWegVoorMij(aanbiedingId);
      if (error) return { fout: error.message };
      if (aanbiedingen) aanbiedingen = aanbiedingen.filter((a) => a.id !== aanbiedingId);
      return {};
    },

    // Bij wisselen van lijst en uitloggen; een antwoord dat nog onderweg is hoort bij de vorige lijst
    vergeetDeals() {
      deals = {};
      wegPerItem = {};
      dealsVraag++;
      dealDetails = null;
      dealDetailsVraag++;
      keuze = null;
    },

    // ---------- Een aanbieding kiezen ----------
    // De gekozen aanbieding bij een item, of null bij een gewoon item: { voor, korting, geldigTot }
    keuzeVan(item) {
      const k = item.offer_choice;
      if (!item.original_name || !k) return null;
      // de bron schrijft "2 VOOR 5.99"
      return { voor: item.original_name, korting: (k.korting || "").toLowerCase(), geldigTot: k.geldig_tot };
    },

    keuzeOpen() { return keuze; },

    // Opent de artikelen van een aanbieding bij een item. Aangevinkt staan de artikelen met dezelfde variant
    // als de term, voor zover je ze ziet: wat nog ingeklapt is komt nooit ongezien op de lijst.
    // Geeft null als je intussen iets anders opende.
    async openKeuze(itemId, aanbiedingId) {
      const mijn = keuze = { itemId, aanbiedingId, opties: null, aan: new Set(), aantal: new Map(), alles: false };
      const { data, error } = await Data.keuzeOpties(itemId, aanbiedingId);
      if (keuze !== mijn) return null;
      if (error) { keuze = null; return { fout: error.message }; }
      mijn.opties = data;
      zichtbareKeuzes().forEach((o) => { if (o.zelfde) mijn.aan.add(o.artikel_id); });
      return {};
    },

    sluitKeuze() { keuze = null; },

    zetKeuzeArtikel(artikelId, aan) {
      if (!keuze) return;
      if (aan) keuze.aan.add(artikelId); else keuze.aan.delete(artikelId);
    },

    // Hoe vaak een aangevinkt artikel op de lijst moet: 1 t/m KEUZE_MAX
    keuzeAantal(artikelId) { return (keuze && keuze.aantal.get(artikelId)) || 1; },

    zetKeuzeAantal(artikelId, aantal) {
      if (keuze) keuze.aantal.set(artikelId, Math.min(Math.max(Math.round(aantal) || 1, 1), KEUZE_MAX));
    },

    keuzeZichtbaar() { return zichtbareKeuzes(); },

    // Hoeveel artikelen er zijn aangevinkt, voor op de knop "Zet op de lijst (2)"
    keuzeAangevinkt() { return keuze ? keuze.aan.size : 0; },

    toonAlleKeuzes() { if (keuze) keuze.alles = true; },

    // Zet de keuze op de lijst: het item wordt het eerste aangevinkte artikel, voor elk volgend artikel komt
    // er een item bij, elk met zijn aantal. Geeft { item } (het gewijzigde item) of { fout }.
    async bevestigKeuze() {
      if (!keuze || !keuze.opties) return { fout: "Er is niets om te kiezen." };
      const mijn = keuze;
      const aantallen = Object.fromEntries([...mijn.aan].map((id) => [id, mijn.aantal.get(id) || 1]));
      const { data, error } = await Data.kiesAanbieding(mijn.itemId, mijn.aanbiedingId, [...mijn.aan], aantallen);
      if (error) return { fout: error.message };
      if (keuze === mijn) keuze = null;
      return { item: data };
    },

    // Haalt de keuze weg, ook bij de andere items uit dezelfde keuze: er blijft één item over met wat er stond.
    // Geeft { item } of { fout }.
    async wisKeuze(itemId) {
      const { data, error } = await Data.wisKeuze(itemId);
      if (error) return { fout: error.message };
      if (keuze && keuze.itemId === itemId) keuze = null;
      return { item: data };
    },

    // Bij het laden van de lijst: items waarvan de gekozen aanbieding is verlopen vallen terug op wat er
    // stond. Een fout hier mag het laden niet tegenhouden.
    async zetVerlopenKeuzesTerug(lijstId) {
      try { await Data.zetVerlopenKeuzesTerug(lijstId); } catch {}
    },

    // De aanbiedingen bij de items van de lijst, voor het paneel onder de groene chip
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

    // Wat er in het paneel op de rij van een aanbieding staat:
    // { label: de korting of "Bonus", voor: de term op de lijst of null, winkel: de supermarkt als er meer dan één
    //   in het paneel staat (anders staat hij al in de chip), gekozen: het gekozen artikel, "Hele aanbieding" of null }
    paneelRegel(detail, item) {
      const term = item ? item.original_name || item.name : null;
      // Staat de aanbieding zelf op de lijst (vanuit Voor jou), dan is de term de titel: niet dubbel tonen
      const zelfde = term && zoekvorm(term) === zoekvorm(this.aanbiedingNaam(detail));
      const artikel = item && item.offer_choice ? (item.offer_choice.artikelen || [])[0] : null;
      return {
        label: (detail.korting || "").toLowerCase() || "Bonus", // de bron schrijft "2 VOOR 5.99"
        voor: term && !zelfde ? term : null,
        winkel: this.dealWinkels(dealDetails || []).length > 1 ? detail.supermarkt : null,
        gekozen: detail.gekozen ? (artikel ? artikel.titel : "Hele aanbieding") : null
      };
    },

    winkelNaam(supermarkt) { return WINKELS[supermarkt] || supermarkt; },

    // De supermarkten met een aanbieding, kort zoals in de database, bijv. ["AH", "PLUS"]
    dealWinkels(lijst) {
      return [...new Set(lijst.map((d) => d.supermarkt))].sort((a, b) => a.localeCompare(b));
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

    // Wat er op de lijst komt bij "zet op lijst": de aanbieding zelf, zoals ze op het scherm staat. De database
    // maakt dezelfde naam (add_offer_item) en onthoudt bij het item het artikel en het product uit de catalogus.
    aanbiedingNaam(aanbieding) {
      return aanbieding.titel.replace(/\s*\*+$/, ""); // "Alle Perla*": het sterretje verwijst naar de kleine lettertjes
    },

    // "Niet nu": het product komt niet meer terug tot je de app sluit
    slaOver(naam) { nietNu.add(naam); },

    // Het gebruikelijke aantal dagen sinds de laatste aankoop is voorbij
    bijnaOp(product) {
      return product.om_de != null && dagenGeleden(product.laatste) >= Number(product.om_de);
    },

    // Wat er nog voor te stellen is: zonder wat al op de lijst staat (`itemsOpLijst`) of is weggetikt. Op de
    // lijst staan telt ook via een aanbieding: staat "AH Tijgerbrood" er met zijn aanbieding, dan is "brood" niet
    // meer nodig. Het product dat het verst over zijn gebruikelijke tussenpoos heen is staat bovenaan.
    voorJouOver(itemsOpLijst) {
      const opLijst = new Set(itemsOpLijst.map((i) => i.name.trim().toLowerCase()));
      const gekozen = new Set(itemsOpLijst.map((i) => i.offer_id).filter(Boolean));
      for (const a of aanbiedingen || []) {
        if (gekozen.has(a.id)) a.producten.forEach((p) => opLijst.add(p.naam.trim().toLowerCase()));
      }
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

    // ---------- Koppelingen ----------
    // Alleen voor de beheerder. De AI koppelt artikelen en termen zelf aan een type en alles telt meteen mee;
    // hier kijkt de beheerder na wat twijfelachtig is en zet hij recht wat fout is.
    koppelingen() { return koppelingen; },
    typeOpen() { return typeOpen; },
    openType(typeId) { typeOpen = typeId; },
    // De namen en artikelen van een type, of undefined als ze nog niet zijn opgehaald
    detailsVan(typeId) { return typeDetails[typeId]; },
    zekerheidNaam(code) { return ZEKERHEID[code] || code; },

    // Bij uitloggen en bij het openen van het scherm: opnieuw beginnen
    vergeetKoppelingen() {
      koppelingen = null;
      typeOpen = null;
      typeDetails = {};
    },

    async laadKoppelingen() {
      const { data, error } = await Data.koppelingOverzicht();
      if (error) return { fout: error.message };
      koppelingen = data;
      return {};
    },

    // Pas ophalen als je het type openklapt
    async laadTypeDetails(typeId) {
      const { data, error } = await Data.typeDetails(typeId);
      if (error) return { fout: error.message };
      typeDetails[typeId] = data;
      return {};
    },

    // De artikelen om na te kijken, per type: [{ type_id, type, rijen }]
    artikelGroepen() {
      const per = new Map();
      for (const rij of (koppelingen || {}).artikelen || []) {
        if (!per.has(rij.type_id)) per.set(rij.type_id, { type_id: rij.type_id, type: rij.type, rijen: [] });
        per.get(rij.type_id).rijen.push(rij);
      }
      return [...per.values()];
    },

    // Wat de AI nergens kwijt kon, per voorgesteld type: [{ voorstel, artikelen, termen }]. De groepen met de
    // meeste rijen eerst; wat zonder voorstel is (geen gewone boodschap) staat onderaan met voorstel null.
    ontbrekend() {
      const per = new Map();
      const groep = (voorstel) => {
        const sleutel = zoekvorm(voorstel || "");
        if (!per.has(sleutel)) per.set(sleutel, { voorstel: voorstel || null, artikelen: [], termen: [] });
        return per.get(sleutel);
      };
      for (const artikel of (koppelingen || {}).zonder_type || []) groep(artikel.voorstel).artikelen.push(artikel);
      for (const term of (koppelingen || {}).termen || []) {
        if (!term.type_id && term.voorstel) groep(term.voorstel).termen.push(term);
      }
      const aantal = (g) => g.artikelen.length + g.termen.length;
      return [...per.values()].sort((a, b) => (a.voorstel === null) - (b.voorstel === null) || aantal(b) - aantal(a));
    },

    // De hoofdgroepen die er zijn, voor de keuzelijst bij een type
    hoofdgroepen() {
      return [...new Set(((koppelingen || {}).types || []).map((t) => t.hoofdgroep))].sort((a, b) => a.localeCompare(b, "nl"));
    },

    // De hoofdgroep waar de artikelen van een groep het vaakst in staan, als voorzet bij "Type aanmaken"
    hoofdgroepVan(artikelen) {
      const bestaand = new Set(this.hoofdgroepen());
      const telling = {};
      for (const a of artikelen) {
        const hoofd = (a.categorie || "").includes("/") ? a.categorie.split("/")[0].trim() : "";
        if (bestaand.has(hoofd)) telling[hoofd] = (telling[hoofd] || 0) + 1;
      }
      return Object.keys(telling).sort((a, b) => telling[b] - telling[a])[0] || "";
    },

    // De types voor de lijst onderaan: de zoektekst staat in de naam of de hoofdgroep
    gefilterdeTypes(zoekTekst) {
      const zoek = zoekvorm(zoekTekst);
      const alle = (koppelingen || {}).types || [];
      return zoek ? alle.filter((t) => zoekvorm(t.naam).includes(zoek) || zoekvorm(t.hoofdgroep).includes(zoek)) : alle;
    },

    // De types voor de keuzelijst "Ander type": eerst wat met de zoektekst begint, dan wat hem bevat.
    // AANTAL: zoveel hooguit; `zonder` is het type dat de rij al heeft.
    zoekTypes(zoekTekst, zonder) {
      const zoek = zoekvorm(zoekTekst);
      if (!zoek) return [];
      const alle = ((koppelingen || {}).types || []).filter((t) => t.id !== zonder);
      const begint = alle.filter((t) => zoekvorm(t.naam).startsWith(zoek));
      const bevat = alle.filter((t) => !zoekvorm(t.naam).startsWith(zoek) && zoekvorm(t.naam).includes(zoek));
      return [...begint, ...bevat].slice(0, 8);
    },

    // Na elke wijziging alles opnieuw ophalen: een correctie raakt de tellingen en soms meerdere blokken
    async herlaadKoppelingen() {
      typeDetails = {};
      return this.laadKoppelingen();
    },

    // "Klopt": de beheerder heeft het oordeel gezien; type en bron blijven wat ze zijn
    async klopt(termen, artikelen) {
      const { error } = await Data.markeerNagekeken(
        termen.map((t) => t.sleutel),
        artikelen.map((a) => ({ supermarket: a.supermarkt, article_id: a.artikel_id })));
      if (error) return { fout: error.message };
      return this.herlaadKoppelingen();
    },

    // "Ander type" en "Geen type" (typeId null) bij een term. Het merk blijft staan bij een ander type.
    async zetTermType(term, typeId) {
      const { error } = await Data.zetTermType(term.term, typeId, typeId ? term.merk : null);
      if (error) return { fout: error.message };
      return this.herlaadKoppelingen();
    },

    // "Ander type" en "Geen type" (typeId null) bij een artikel
    async zetArtikelType(artikel, typeId) {
      const { error } = await Data.zetArtikelType(artikel.supermarkt, artikel.artikel_id, typeId);
      if (error) return { fout: error.message };
      return this.herlaadKoppelingen();
    },

    // velden: { naam, hoofdgroep, valtEronder, valtErNietOnder, teltMee }. Geeft { nieuw } terug met wat erbij kwam.
    async maakType(velden, voorstel) {
      if (!velden.naam.trim()) return { fout: "Geef het type een naam." };
      if (!velden.hoofdgroep) return { fout: "Kies een hoofdgroep." };
      const { data, error } = await Data.maakType(velden, voorstel);
      if (error) return { fout: error.message };
      const uit = await this.herlaadKoppelingen();
      return uit.fout ? uit : { nieuw: data };
    },

    async wijzigType(type, velden) {
      if (!velden.naam.trim()) return { fout: "Geef het type een naam." };
      const { error } = await Data.wijzigType(type.id, velden);
      if (error) return { fout: error.message };
      return this.herlaadKoppelingen();
    },

    // Het type bron gaat op in doel: artikelen, namen en items verhuizen, de naam van de bron blijft werken
    async voegTypesSamen(bron, doel) {
      const { error } = await Data.voegTypesSamen(bron.naam, doel.naam);
      if (error) return { fout: error.message };
      if (typeOpen === bron.id) typeOpen = doel.id;
      return this.herlaadKoppelingen();
    },
  };
})();
