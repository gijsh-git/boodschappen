// Logica: state en regels zonder DOM. Zie ARCHITECTURE.md.
// Roept alleen `Data` aan; app.js toont wat hier uitkomt. Nu alleen de favorieten: de rest van de logica
// staat nog in app.js en verhuist per onderdeel.
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

  return {
    zoekvorm,

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
