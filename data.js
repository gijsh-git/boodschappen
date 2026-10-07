// Datatoegang: alle Supabase-calls van de app. Zie ARCHITECTURE.md.
// Elke functie geeft het resultaat van Supabase terug ({ data, error }); beslissen wat er daarna gebeurt doet de aanroeper.
// Buiten dit bestand komt geen `db.` voor.
const Data = (() => {
  let db;

  return {
    // Krijgt de Supabase-client van app.js, die hem pas maakt nadat de # van de mail-link is uitgelezen
    init(client) { db = client; },

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
    verwijderLijst(lijstId) { return db.rpc("delete_list", { p_list: lijstId }); },
    zetLijstProfiel(lijstId, teltMee) { return db.rpc("set_list_profile", { p_list: lijstId, p_counts: teltMee }); },
    // Is de lijst intussen gearchiveerd? (data is null als je de lijst niet meer ziet)
    lijstGearchiveerdOp(lijstId) { return db.from("lists").select("archived_at").eq("id", lijstId).maybeSingle(); },

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
