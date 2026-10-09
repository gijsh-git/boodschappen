// Datatoegang: alle Supabase-calls van de app. Zie ARCHITECTURE.md.
// Elke functie geeft het resultaat van Supabase terug ({ data, error }); beslissen wat er daarna gebeurt doet de aanroeper.
// Buiten dit bestand komt geen `db.` voor.
const Data = (() => {
  let db;
  let kanaal = null; // het live kanaal van de open lijst

  return {
    // Maakt de Supabase-client. app.js roept dit pas aan nadat de # van de mail-link is uitgelezen,
    // want de client ruimt die # op.
    init(url, sleutel) { db = supabase.createClient(url, sleutel); },

    // ---------- Inloggen ----------
    sessie() { return db.auth.getSession(); },
    // Roept `bij(event, sessie)` aan bij elke wijziging van de sessie (ook als de app terug in beeld komt)
    bijSessieWijziging(bij) { return db.auth.onAuthStateChange(bij); },
    logIn(email, wachtwoord) { return db.auth.signInWithPassword({ email, password: wachtwoord }); },
    logUit() { return db.auth.signOut(); },
    // Stuurt een mail met een link die terugkomt op `terugNaar`
    stuurHerstelMail(email, terugNaar) { return db.auth.resetPasswordForEmail(email, { redirectTo: terugNaar }); },
    zetWachtwoord(wachtwoord) { return db.auth.updateUser({ password: wachtwoord }); },

    // ---------- Edge Functions ----------
    // Leest de producten van een foto; schrijft zelf niets
    fotoNaarItems(inhoud) { return db.functions.invoke("foto-naar-items", { body: inhoud }); },
    // Leest een kassabon (foto of pdf); schrijft zelf niets
    leesBon(inhoud) { return db.functions.invoke("bon-uploaden", { body: inhoud }); },

    // ---------- Lijsten ----------
    // Je eigen lidmaatschappen met de lijst erbij, oudste eerst
    lijstenVanGebruiker(userId) {
      return db
        .from("list_members")
        .select("list_id, lists(id, name, counts_for_profile, created_by, archived_at)")
        // Alleen je eigen lidmaatschappen: je mag ook die van lijstgenoten zien, en dan staat een lijst er dubbel
        .eq("user_id", userId)
        .order("joined_at", { ascending: true });
    },
    maakLijst(naam) { return db.rpc("create_list", { p_name: naam }); },
    sluitAan(code) { return db.rpc("join_list", { p_code: code }); },
    archiveerLijst(lijstId, gearchiveerd) { return db.rpc("archive_list", { p_list: lijstId, p_archived: gearchiveerd }); },
    // Jezelf uit een lijst halen (de maker kan dat niet, die archiveert of verwijdert de lijst)
    verlaatLijst(lijstId) { return db.rpc("leave_list", { p_list: lijstId }); },
    verwijderLijst(lijstId) { return db.rpc("delete_list", { p_list: lijstId }); },
    zetLijstProfiel(lijstId, teltMee) { return db.rpc("set_list_profile", { p_list: lijstId, p_counts: teltMee }); },
    // Is de lijst intussen gearchiveerd? (data is null als je de lijst niet meer ziet)
    lijstGearchiveerdOp(lijstId) { return db.from("lists").select("archived_at").eq("id", lijstId).maybeSingle(); },

    // ---------- Items ----------
    items(lijstId) { return db.from("items").select("*").eq("list_id", lijstId).order("created_at", { ascending: true }); },
    voegItemToe(rij) { return db.from("items").insert(rij).select().single(); },
    voegItemsToe(rijen) { return db.from("items").insert(rijen).select(); },
    // Zet een aanbieding uit "Voor jou" op de lijst: de database bepaalt de naam (de titel), het artikel en
    // het type, en geeft het nieuwe item terug
    zetAanbiedingOpLijst(lijstId, aanbiedingId) { return db.rpc("add_offer_item", { p_list: lijstId, p_offer: aanbiedingId }); },
    // Zet een verwijderd item terug met zijn oorspronkelijke id, maker, tijd, aanbieding, artikel, type en keuze
    zetItemTerug(item) {
      return db.from("items").insert({
        id: item.id, list_id: item.list_id, name: item.name, quantity: item.quantity,
        added_by: item.added_by, created_at: item.created_at, offer_id: item.offer_id,
        article_supermarket: item.article_supermarket, article_id: item.article_id, type_id: item.type_id,
        original_name: item.original_name, original_quantity: item.original_quantity, offer_choice: item.offer_choice
      });
    },
    // De artikelen van een aanbieding waaruit je bij een item kunt kiezen: [{ artikel_id, titel, zelfde, past, gekozen }]
    keuzeOpties(itemId, aanbiedingId) { return db.rpc("offer_choice_options", { p_item: itemId, p_offer: aanbiedingId }); },
    // Kiest een aanbieding bij een item (met de aangevinkte artikelen; leeg is de aanbieding als geheel): het
    // item wordt vervangen en onthoudt wat er stond. aantallen: per artikel-id hoe vaak, { id: 2 }. Geeft het
    // gewijzigde item terug.
    kiesAanbieding(itemId, aanbiedingId, artikelIds, aantallen) {
      return db.rpc("choose_offer", { p_item: itemId, p_offer: aanbiedingId, p_articles: artikelIds, p_counts: aantallen });
    },
    // Haalt de keuze weg: het item heet weer wat er oorspronkelijk stond. Geeft het gewijzigde item terug.
    wisKeuze(itemId) { return db.rpc("clear_offer_choice", { p_item: itemId }); },
    // Zet items waarvan de gekozen aanbieding is verlopen terug naar de oorspronkelijke invoer; geeft het aantal
    zetVerlopenKeuzesTerug(lijstId) { return db.rpc("reset_expired_choices", { p_list: lijstId }); },
    verwijderItem(itemId) { return db.from("items").delete().eq("id", itemId); },
    // Gekocht: de database haalt het item weg en bewaart de aankoop (als de lijst meetelt); geeft het aankoop-id of null
    koopItem(itemId) { return db.rpc("buy_item", { p_item: itemId }); },
    maakAankoopOngedaan(aankoopId) { return db.rpc("undo_purchase", { p_purchase: aankoopId }); },

    // ---------- Aanbiedingen ----------
    // Per item bij welke supermarkt er hoeveel geldige aanbiedingen zijn, en hoeveel daarvan zijn weggeklikt
    aanbiedingenVoorLijst(lijstId) { return db.rpc("offers_for_list", { p_list: lijstId }); },
    // Per item en aanbieding wat er precies in de aanbieding is: titel, korting, geldig tot en de artikelen
    aanbiedingenBijLijst(lijstId) { return db.rpc("offer_details_for_list", { p_list: lijstId }); },
    // De geldige aanbiedingen die voor jou tellen (favorieten en vaste producten), als JSON in de volgorde van tonen
    aanbiedingenVoorMij() { return db.rpc("offers_for_me"); },
    // "Niet deze week" bij een item: verbergt de aanbieding bij dat item voor de hele lijst, tot ze verloopt
    klikAanbiedingWeg(itemId, aanbiedingId) { return db.rpc("dismiss_offer", { p_item: itemId, p_offer: aanbiedingId }); },
    haalAanbiedingTerug(itemId, aanbiedingId) { return db.rpc("restore_offer", { p_item: itemId, p_offer: aanbiedingId }); },
    // "Niet deze week" in Voor jou: alleen voor jezelf
    klikAanbiedingWegVoorMij(aanbiedingId) { return db.rpc("dismiss_offer_for_me", { p_offer: aanbiedingId }); },

    // ---------- Aankopen ----------
    aankopen(lijstId) {
      return db
        .from("purchases")
        .select("id, list_id, item_id, name, quantity, bought_by, bought_at, receipt_id, receipt_name, price, discount")
        .eq("list_id", lijstId)
        .order("bought_at", { ascending: false })
        .limit(200);
    },
    verwijderAankoop(aankoopId) { return db.from("purchases").delete().eq("id", aankoopId); },

    // ---------- Bonnen ----------
    // Staat een bon met dezelfde winkel, datum en totaal al in de lijst? (data is true of false)
    bonBestaat(lijstId, winkel, datum, totaal) {
      return db.rpc("receipt_exists", { p_list: lijstId, p_store: winkel, p_date: datum, p_total: totaal });
    },
    // Per bonregel de meest gelijkende aankoop van die dag
    zoekAankopenBijBonregels(lijstId, datum, namen) {
      return db.rpc("match_receipt_lines", { p_list: lijstId, p_date: datum, p_names: namen });
    },
    // Per bonregel het beste item op de lijst dat op of voor de bondatum is toegevoegd
    zoekItemsBijBonregels(lijstId, datum, namen) {
      return db.rpc("match_receipt_items", { p_list: lijstId, p_date: datum, p_names: namen });
    },
    bewaarBon(lijstId, winkel, datum, totaal, regels) {
      return db.rpc("save_receipt", { p_list: lijstId, p_store: winkel, p_date: datum, p_total: totaal, p_lines: regels });
    },
    verwijderBon(bonId) { return db.rpc("delete_receipt", { p_receipt: bonId }); },
    bonnen(lijstId) {
      return db
        .from("receipts")
        .select("id, list_id, store, receipt_date, total, added_by")
        .eq("list_id", lijstId)
        .order("receipt_date", { ascending: false })
        .order("created_at", { ascending: false })
        .limit(200);
    },
    // De aankopen die bij een bon horen
    bonInhoud(bonId) {
      return db
        .from("purchases")
        .select("id, name, quantity, receipt_name, price, discount")
        .eq("receipt_id", bonId)
        .order("name", { ascending: true });
    },

    // ---------- Profiel ----------
    // Je eigen naam (data is null als je er nog geen hebt ingevuld)
    eigenNaam(userId) { return db.from("profiles").select("display_name").eq("user_id", userId).maybeSingle(); },
    bewaarNaam(userId, naam) { return db.from("profiles").upsert({ user_id: userId, display_name: naam }); },
    isBeheerder() { return db.rpc("is_admin"); },
    // Het aankoopprofiel als JSON; periode is '4w', '3m', '12m' of 'alles', lijstId is null voor alle lijsten
    aankoopprofiel(periode, lijstId) { return db.rpc("purchase_profile", { p_period: periode, p_list: lijstId }); },

    // ---------- Favorieten ----------
    // Alleen je eigen favorieten (de database geeft geen andere terug), oudste eerst
    favorieten() { return db.from("favorites").select("id, term, brand, category").order("created_at", { ascending: true }); },
    voegFavorietToe(rij) { return db.from("favorites").insert(rij).select("id, term, brand, category").single(); },
    wijzigFavoriet(id, rij) { return db.from("favorites").update(rij).eq("id", id).select("id, term, brand, category").single(); },
    verwijderFavoriet(id) { return db.from("favorites").delete().eq("id", id); },
    // Suggesties uit de artikelen die ooit in een aanbieding zaten: termen met hun hoofdcategorie, en merken
    favorietTermen(tekst) { return db.rpc("suggest_favorite_terms", { p_query: tekst }); },
    favorietMerken(tekst) { return db.rpc("suggest_favorite_brands", { p_query: tekst }); },

    // ---------- Koppelingen ----------
    // Alleen voor de beheerder; de functies controleren de rol zelf.
    // Wat de AI heeft gekoppeld en nog niet is nagekeken, wat geen type heeft, en alle types met hun tellingen
    koppelingOverzicht() { return db.rpc("type_link_overview"); },
    // De namen en artikelen van één type
    typeDetails(typeId) { return db.rpc("type_details", { p_type: typeId }); },
    // sleutels: sleutels van termen; artikelen: [{ supermarket, article_id }]
    markeerNagekeken(sleutels, artikelen) { return db.rpc("mark_links_reviewed", { p_terms: sleutels, p_articles: artikelen }); },
    // typeId null is "geen type"; het oordeel is daarna van de beheerder en de AI vervangt het niet meer
    zetTermType(term, typeId, merk) {
      return db.rpc("save_term_types", { p_rows: [{ term, type_id: typeId, brand: merk || null }], p_source: "manual" });
    },
    zetArtikelType(supermarkt, artikelId, typeId) {
      return db.rpc("set_article_types", { p_rows: [{ supermarket: supermarkt, article_id: artikelId, type_id: typeId }], p_source: "manual" });
    },
    // voorstel: het voorstel van de AI waar het type voor komt (mag leeg); wat precies dat voorstel had hoort er meteen bij
    maakType(velden, voorstel) {
      return db.rpc("create_product_type", {
        p_name: velden.naam, p_main_group: velden.hoofdgroep, p_scope: velden.valtEronder, p_excludes: velden.valtErNietOnder,
        p_counts: velden.teltMee, p_suggestion: voorstel || null,
      });
    },
    wijzigType(typeId, velden) {
      return db.rpc("update_product_type", {
        p_type: typeId, p_name: velden.naam, p_main_group: velden.hoofdgroep, p_scope: velden.valtEronder,
        p_excludes: velden.valtErNietOnder, p_counts: velden.teltMee,
      });
    },
    // Een type dat de AI aanmaakte is gezien
    markeerTypeNagekeken(typeId) { return db.rpc("review_product_type", { p_type: typeId }); },
    // Zijn artikelen en namen blijven zonder type achter
    verwijderType(typeId) { return db.rpc("delete_product_type", { p_type: typeId }); },
    // Het type bron gaat op in doel (beide bij naam); niet terug te draaien
    voegTypesSamen(bronNaam, doelNaam) { return db.rpc("merge_product_types", { p_source: bronNaam, p_target: doelNaam }); },

    // ---------- Live volgen ----------
    // Eén kanaal per lijst voor items, leden, de lijst zelf, aankopen en weggeklikte aanbiedingen. `op` heeft
    // per soort een functie die het Supabase-bericht krijgt: { item, lid, lijst, aankoop, weggeklikt }. Een
    // nieuw kanaal sluit het vorige.
    // Een DELETE van items en aankopen bevat alleen de id, geen list_id, dus daar kan niet op de lijst gefilterd
    // worden (Realtime stuurt zo'n bericht dan helemaal niet). Die luisteren zonder filter; de aanroeper kijkt
    // zelf of de id in de open lijst zit.
    volgLijst(lijstId, op) {
      this.stopVolgen();
      kanaal = db
        .channel("items-" + lijstId)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "items", filter: `list_id=eq.${lijstId}` }, op.item)
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "items", filter: `list_id=eq.${lijstId}` }, op.item)
        .on("postgres_changes", { event: "DELETE", schema: "public", table: "items" }, op.item)
        .on("postgres_changes", { event: "*", schema: "public", table: "list_members", filter: `list_id=eq.${lijstId}` }, op.lid)
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "lists", filter: `id=eq.${lijstId}` }, op.lijst)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "purchases", filter: `list_id=eq.${lijstId}` }, op.aankoop)
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "purchases", filter: `list_id=eq.${lijstId}` }, op.aankoop)
        .on("postgres_changes", { event: "DELETE", schema: "public", table: "purchases" }, op.aankoop)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "offer_dismissals", filter: `list_id=eq.${lijstId}` }, op.weggeklikt)
        .on("postgres_changes", { event: "UPDATE", schema: "public", table: "offer_dismissals", filter: `list_id=eq.${lijstId}` }, op.weggeklikt)
        .subscribe();
    },
    stopVolgen() {
      if (kanaal) db.removeChannel(kanaal);
      kanaal = null;
    },

    // ---------- Leden ----------
    leden(lijstId) {
      return db
        .from("list_members")
        .select("user_id, joined_at, is_manager")
        .eq("list_id", lijstId)
        .order("joined_at", { ascending: true });
    },
    // Namen van jezelf en je lijstgenoten (de database geeft alleen die profielen terug)
    namen() { return db.from("profiles").select("user_id, display_name"); },
    maakUitnodiging(lijstId) { return db.rpc("create_invite", { p_list: lijstId }); },
    zetBeheerder(lijstId, userId, beheerder) { return db.rpc("set_member_manager", { p_list: lijstId, p_user: userId, p_manager: beheerder }); },
    verwijderLid(lijstId, userId) { return db.rpc("remove_member", { p_list: lijstId, p_user: userId }); }
  };
})();
