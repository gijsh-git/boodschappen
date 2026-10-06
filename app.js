const { SUPABASE_URL, SUPABASE_ANON_KEY } = window.CONFIG;

// Links uit een mail (uitnodiging, wachtwoord vergeten) komen binnen met gegevens achter de #.
// Die lezen we hier uit, vóórdat Supabase de # opruimt.
const linkParams = new URLSearchParams(location.hash.slice(1));
const linkType = linkParams.get("type");
const linkError = linkParams.get("error_description");
// Na een uitnodiging of "wachtwoord vergeten" moet er eerst een wachtwoord gekozen worden.
let mustSetPassword = linkType === "invite" || linkType === "recovery";

const db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const $ = (id) => document.getElementById(id);
const views = ["login", "forgot", "sent", "password", "naam", "profiel", "setup", "nieuw", "list", "aankopen", "foto", "bon", "bonnen", "stapel"];
let resetEmail = "";
let userId = null;
let mijnNaam = null;   // weergavenaam; null = nog niet opgehaald of nog niet ingevuld
let naamOpen = false;  // het naam-scherm staat open
let naamBewerken = false; // naam-scherm is geopend vanuit het profiel (niet de eerste keer)
let profielOpen = false;  // het profiel-scherm (of het naam-scherm daarbinnen) staat open
let namen = {};        // user_id -> weergavenaam van jezelf en je lijstgenoten
let infoId = null;     // item waarvan de info ("toegevoegd door") openstaat
let lijsten = [];      // de actieve lijsten waar je lid van bent
let archief = [];      // de gearchiveerde lijsten waar je lid van bent
let lijstenOpen = false;  // het overzicht van lijsten staat open
const LIJST_SLEUTEL = "bonusbuddy-lijst"; // localStorage: id van de laatst geopende lijst
const ARCHIEF_MELDING = "Deze lijst is gearchiveerd door de maker.";
const UITLEG_SLEUTEL = "bonusbuddy-veeguitleg"; // localStorage: "weg" als de uitleg over vegen is weggeklikt
let currentList = null;
let channel = null;
let items = [];
let leden = [];        // deelnemers van de huidige lijst: { user_id, joined_at }
let deals = {};        // item-id -> [{ supermarkt, aantal }]: actuele aanbiedingen per item
let dealsVraag = 0;    // volgnummer, zodat een laat antwoord een nieuwer antwoord niet overschrijft
let aankopen = null;   // aankopen van de huidige lijst, nieuwste eerst; null = nog niet opgehaald
let aankopenOpen = false; // het scherm met aankopen staat open
let fotoOpen = false;  // het scherm "Foto controleren" staat open
let fotoProducten = []; // producten uit de foto: { naam, hoeveelheid, aan }
let fotoVraag = 0;     // volgnummer, zodat een antwoord na annuleren genegeerd wordt
const FOTO_MAX = 2000; // langste zijde in pixels waarmee de foto wordt verstuurd
const BON_PDF_MAX = 4_000_000; // grootste pdf in bytes; past na base64 binnen de grens van de functie
let bonnen = null;     // gescande bonnen van de huidige lijst, nieuwste eerst; null = nog niet opgehaald
let bonInzien = null;  // id van de bon die is opengeklapt
let bonInhoud = {};    // bon-id -> de aankopen die bij die bon horen
let bonOpen = false;   // het scherm "Bon controleren" staat open
const BON_MAX = 20;    // meeste bonnen in één stapel; rem op de kosten van het lezen
const BON_TEGELIJK = 2; // zoveel bonnen worden tegelijk gelezen
// Stapel gekozen bonnen: { nr, bestand, bestandsnaam, status, melding, supermarkt, datum, totaal, regels, dubbel, gecontroleerd, controleFout, controle, uitkomst }
// status: "wacht", "lezen", "klaar" (gelezen, nog op te slaan), "fout" of "opgeslagen"
// regels: { bonNaam, naam, aantal, prijs, korting, aan, koppel, koppelAan }
let bonStapel = [];
let bonNr = 0;         // volgnummer voor de bonnen in de stapel
let bonHuidig = null;  // de bon uit de stapel die in "Bon controleren" open staat
let bonVraag = 0;      // volgnummer van de stapel, zodat een antwoord na leegmaken genegeerd wordt
let stapelBezig = false; // "Alles zonder bijzonderheden opslaan" loopt
let slepen = 0;        // aantal rijen dat nu wordt versleept (of nog uitschuift)
let renderWacht = false;  // er is een render() overgeslagen tijdens het slepen
let ongedaan = null;   // laatste actie die nog terug te draaien is: { item, aankoopId }
let ongedaanTimer = null;

function show(view) {
  views.forEach((v) => ($("view-" + v).hidden = v !== view));
}

function say(id, text) {
  $(id).textContent = text || "";
}

// Foutmeldingen van Supabase (Engels) omzetten naar begrijpelijk Nederlands
function nl(error) {
  const m = error.message || "";
  if (/invalid login credentials/i.test(m)) return "E-mailadres of wachtwoord klopt niet. Nog geen wachtwoord? Kies 'Wachtwoord vergeten?'.";
  if (/signups not allowed/i.test(m)) return "Dit e-mailadres is niet uitgenodigd. Vraag de beheerder om een uitnodiging.";
  if (/security purposes/i.test(m)) return "Wacht een minuut voordat je opnieuw een mail aanvraagt.";
  if (/rate limit/i.test(m)) return "Er zijn te veel mails verstuurd. Probeer het over een tijdje opnieuw.";
  if (/different from the old/i.test(m)) return "Kies een ander wachtwoord dan je vorige.";
  if (/password/i.test(m) && /at least|weak|short/i.test(m)) return "Kies een sterker wachtwoord van minstens 8 tekens.";
  if (/session missing|expired|invalid/i.test(m)) return "De link is verlopen of al gebruikt. Vraag een nieuwe aan via 'Wachtwoord vergeten?'.";
  return m;
}

// ---------- Start ----------
async function init() {
  if (SUPABASE_URL.includes("JOUW-PROJECT")) {
    show("login");
    say("login-msg", "Vul eerst config.js in met je Supabase-gegevens.");
    return;
  }
  const { data: { session } } = await db.auth.getSession();
  userId = session ? session.user.id : null;
  db.auth.onAuthStateChange((event, s) => {
    if (event === "PASSWORD_RECOVERY") mustSetPassword = true;
    userId = s ? s.user.id : null;
    if (s) route(); else { mijnNaam = null; naamOpen = false; profielOpen = false; lijstenOpen = false; aankopenOpen = false; fotoOpen = false; leegStapel(); show("login"); }
  });
  if (session) route(); else show("login");
  if (linkError) say("login-msg", "De link is verlopen of al gebruikt. Vraag een nieuwe aan via 'Wachtwoord vergeten?'.");
}

async function route() {
  if (mustSetPassword) { naamOpen = false; profielOpen = false; lijstenOpen = false; aankopenOpen = false; fotoOpen = false; bonOpen = false; return show("password"); }
  // Supabase meldt de sessie opnieuw als de app terug in beeld komt; dan niet wegspringen van naam, profiel, overzicht, aankopen, foto of bon
  if (naamOpen || profielOpen || lijstenOpen || aankopenOpen || fotoOpen || bonOpen) return;
  if (mijnNaam === null) {
    const { data: profiel, error: profielFout } = await db
      .from("profiles")
      .select("display_name")
      .eq("user_id", userId)
      .maybeSingle();
    if (mustSetPassword) return show("password");
    // Bij een fout (bijv. tabel bestaat nog niet) gewoon door naar de lijst
    if (!profielFout && !profiel) return toonNaam(false);
    if (profiel) mijnNaam = profiel.display_name;
  }
  const fout = await loadLijsten();
  if (mustSetPassword) return show("password");
  // Terug van de camera komt de sessiemelding vaak net vóór de gekozen foto; dan staat het foto- of bonscherm inmiddels open
  if (fotoOpen || bonOpen) return;
  if (fout) {
    renderLijsten();
    $("lijsten-leeg").hidden = true; // onbekend of je lijsten hebt, dus niet "nog geen lijsten" tonen
    show("setup");
    say("setup-msg", "Je lijsten konden niet worden opgehaald: " + fout.message);
    return;
  }
  if (lijsten.length === 0) return toonOverzicht();
  // De laatst geopende lijst weer openen; anders de eerste
  let laatste = null;
  try { laatste = localStorage.getItem(LIJST_SLEUTEL); } catch {}
  openList(lijsten.find((l) => l.id === laatste) || lijsten[0]);
}

// ---------- Inloggen ----------
$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  say("login-msg", "Bezig...");
  const { error } = await db.auth.signInWithPassword({
    email: $("email").value.trim(),
    password: $("password").value
  });
  if (error) return say("login-msg", nl(error));
  $("password").value = "";
  say("login-msg", "");
});

// ---------- Wachtwoord vergeten ----------
$("forgot").addEventListener("click", () => {
  $("forgot-email").value = $("email").value.trim();
  say("forgot-msg", "");
  show("forgot");
});

// Stuurt een mail met een link naar het scherm "Kies je wachtwoord"
function sendReset(email) {
  return db.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
}

$("forgot-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = $("forgot-email").value.trim();
  say("forgot-msg", "Bezig...");
  const { error } = await sendReset(email);
  if (error) return say("forgot-msg", nl(error));
  resetEmail = email;
  $("sent-email").textContent = email;
  say("forgot-msg", "");
  say("sent-msg", "");
  show("sent");
});

$("resend").addEventListener("click", async () => {
  say("sent-msg", "Bezig...");
  const { error } = await sendReset(resetEmail);
  say("sent-msg", error ? nl(error) : "Opnieuw verstuurd.");
});

document.querySelectorAll(".to-login").forEach((btn) => {
  btn.addEventListener("click", () => { say("login-msg", ""); show("login"); });
});

// Op iPhone/iPad opent message:// de Mail-app; elders is mailto: het beste alternatief
if (/iPhone|iPad|iPod/.test(navigator.userAgent)) $("open-mail").href = "message://";

// ---------- Wachtwoord kiezen ----------
$("password-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  say("password-msg", "Bezig...");
  const { error } = await db.auth.updateUser({ password: $("new-password").value });
  if (error) return say("password-msg", nl(error));
  mustSetPassword = false;
  $("new-password").value = "";
  say("password-msg", "");
  history.replaceState(null, "", location.pathname);
  route();
});

// Oogje: wachtwoord tonen of verbergen
document.querySelectorAll(".pw-toggle").forEach((btn) => {
  btn.addEventListener("click", () => {
    const input = $(btn.dataset.for);
    const tonen = input.type === "password";
    input.type = tonen ? "text" : "password";
    btn.setAttribute("aria-pressed", tonen);
    btn.setAttribute("aria-label", tonen ? "Wachtwoord verbergen" : "Wachtwoord tonen");
  });
});

// ---------- Weergavenaam ----------
// bewerken = false: eerste keer invullen (verplicht); true: later aanpassen vanuit het profiel
function toonNaam(bewerken) {
  if (!naamOpen) $("naam").value = mijnNaam || "";
  naamOpen = true;
  naamBewerken = bewerken;
  $("naam-kop").textContent = bewerken ? "Naam wijzigen" : "Hoe heet je?";
  $("naam-annuleren-regel").hidden = !bewerken;
  say("naam-msg", "");
  show("naam");
}

$("naam-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const naam = $("naam").value.trim();
  if (!naam) return say("naam-msg", "Vul je naam in.");
  say("naam-msg", "Bezig...");
  const { error } = await db.from("profiles").upsert({ user_id: userId, display_name: naam });
  if (error) return say("naam-msg", nl(error));
  mijnNaam = naam;
  namen[userId] = naam;
  naamOpen = false;
  say("naam-msg", "");
  if (naamBewerken) toonProfiel(); else route();
});

$("naam-annuleren").addEventListener("click", toonProfiel);
$("naam-wijzigen").addEventListener("click", () => toonNaam(true));

// ---------- Profiel ----------
function toonProfiel() {
  naamOpen = false;
  profielOpen = true;
  $("profiel-naam").textContent = mijnNaam || "Nog niet ingevuld";
  // Het profiel is bereikbaar vanuit de lijst en vanuit het overzicht; terug gaat naar waar je vandaan kwam
  $("profiel-terug").textContent = lijstenOpen ? "Terug naar mijn lijsten" : "Terug naar de lijst";
  show("profiel");
}

$("profiel-knop").addEventListener("click", toonProfiel);
$("profiel-knop-setup").addEventListener("click", toonProfiel);
$("profiel-terug").addEventListener("click", () => {
  profielOpen = false;
  if (lijstenOpen) return toonLijsten();
  render();
  show("list");
});

async function logout() {
  await db.auth.signOut();
  if (channel) db.removeChannel(channel);
  currentList = null;
  mustSetPassword = false;
  mijnNaam = null;
  naamOpen = false;
  profielOpen = false;
  lijstenOpen = false;
  aankopenOpen = false;
  fotoOpen = false;
  leegStapel();
  lijsten = [];
  archief = [];
  leden = [];
  deals = {};
  aankopen = null;
  namen = {};
  verbergOngedaan();
  show("login");
}
$("logout").addEventListener("click", logout);

// ---------- Overzicht van lijsten ----------
// Haalt al je lijsten op; geeft de fout terug als het misgaat
async function loadLijsten() {
  const { data, error } = await db
    .from("list_members")
    .select("list_id, lists(id, name, invite_code, counts_for_profile, created_by, archived_at)")
    // Alleen je eigen lidmaatschappen: je mag ook die van lijstgenoten zien, en dan staat een lijst er dubbel
    .eq("user_id", userId)
    .order("joined_at", { ascending: true });
  if (error) return error;
  const alle = data.map((m) => m.lists).filter(Boolean);
  lijsten = alle.filter((l) => !l.archived_at);
  archief = alle.filter((l) => l.archived_at);
  return null;
}

function toonOverzicht() {
  lijstenOpen = true;
  say("setup-msg", "");
  renderLijsten();
  show("setup");
}

// Overzicht direct tonen met wat we al weten, daarna verversen (de ander kan iets gewijzigd hebben)
async function toonLijsten() {
  toonOverzicht();
  const fout = await loadLijsten();
  if (fout) return say("setup-msg", fout.message);
  renderLijsten();
}

function lijstRij(lijst) {
  const li = document.createElement("li");
  li.className = "lijst-rij";

  const naam = document.createElement("button");
  naam.type = "button";
  naam.className = "lijst-naam";
  naam.textContent = lijst.name;
  if (currentList && currentList.id === lijst.id) naam.setAttribute("aria-current", "true");
  naam.addEventListener("click", () => openList(lijst));

  const label = document.createElement("label");
  label.className = "schakel-regel";
  const tekst = document.createElement("span");
  tekst.textContent = "Meetellen voor aankoopprofiel";
  const box = document.createElement("input");
  box.type = "checkbox";
  box.className = "schakelaar";
  box.setAttribute("role", "switch");
  box.checked = lijst.counts_for_profile !== false;
  box.addEventListener("change", () => setTeltMee(lijst, box.checked));
  label.append(tekst, box);

  li.append(naam, label);
  // Archiveren en verwijderen kan alleen de maker; de database controleert dat ook
  if (lijst.created_by === userId) {
    const weg = document.createElement("button");
    weg.type = "button";
    weg.className = "link lijst-weg";
    weg.textContent = "Lijst archiveren";
    weg.addEventListener("click", () => archiveerLijst(lijst));
    // Prullenbakje rechts op dezelfde regel: de lijst definitief verwijderen
    const prul = document.createElement("button");
    prul.type = "button";
    prul.className = "lijst-prul";
    prul.setAttribute("aria-label", `Lijst ${lijst.name} verwijderen`);
    prul.innerHTML = '<svg width="20" height="20" aria-hidden="true"><use href="#icon-prullenbak"/></svg>';
    prul.addEventListener("click", () => verwijderLijst(lijst));
    li.append(weg, prul);
  }
  return li;
}

// Rij in het blok "Gearchiveerd": alleen de naam, en voor de maker een knop om terug te zetten
function archiefRij(lijst) {
  const li = document.createElement("li");
  li.className = "lid-rij";
  const naam = document.createElement("span");
  naam.textContent = lijst.name;
  li.append(naam);
  if (lijst.created_by === userId) {
    const terug = document.createElement("button");
    terug.type = "button";
    terug.className = "link";
    terug.textContent = "Terugzetten";
    terug.addEventListener("click", () => zetLijstTerug(lijst));
    li.append(terug);
  }
  return li;
}

// Archiveren in plaats van verwijderen: de aankopen en bonnen blijven bewaard voor het aankoopprofiel
async function archiveerLijst(lijst) {
  if (!confirm(`Lijst "${lijst.name}" archiveren? De lijst verdwijnt uit het overzicht, ook voor de andere leden. De aankopen en bonnen blijven bewaard en je kunt de lijst later terugzetten.`)) return;
  say("setup-msg", "");
  // Vooraf loslaten: anders meldt realtime onze eigen wijziging als "gearchiveerd door de maker"
  if (currentList && currentList.id === lijst.id) sluitLijst();
  const { data, error } = await db.rpc("archive_list", { p_list: lijst.id, p_archived: true });
  if (error) return say("setup-msg", error.message);
  lijsten = lijsten.filter((l) => l.id !== lijst.id);
  archief = archief.filter((l) => l.id !== lijst.id).concat(data);
  renderLijsten();
}

// Definitief verwijderen: ook de aankopen en bonnen van de lijst zijn dan weg
async function verwijderLijst(lijst) {
  if (!confirm(`Lijst "${lijst.name}" definitief verwijderen? Alle items, aankopen en bonnen van deze lijst verdwijnen, ook voor de andere leden en uit het aankoopprofiel. Dit kan niet ongedaan worden gemaakt.\n\nWil je de aankopen bewaren? Kies dan "Lijst archiveren".`)) return;
  say("setup-msg", "");
  // Vooraf loslaten: anders meldt realtime ons eigen verdwenen lidmaatschap als "je bent verwijderd"
  if (currentList && currentList.id === lijst.id) sluitLijst();
  const { error } = await db.rpc("delete_list", { p_list: lijst.id });
  if (error) return say("setup-msg", error.message);
  lijsten = lijsten.filter((l) => l.id !== lijst.id);
  renderLijsten();
}

async function zetLijstTerug(lijst) {
  say("setup-msg", "");
  const { data, error } = await db.rpc("archive_list", { p_list: lijst.id, p_archived: false });
  if (error) return say("setup-msg", error.message);
  archief = archief.filter((l) => l.id !== lijst.id);
  if (!lijsten.some((l) => l.id === lijst.id)) lijsten.push(data);
  renderLijsten();
}

// De huidige lijst loslaten: geen live updates meer en niet meer onthouden als laatst geopend
function sluitLijst() {
  if (channel) db.removeChannel(channel);
  channel = null;
  currentList = null;
  items = [];
  leden = [];
  deals = {};
  aankopen = null;
  aankopenOpen = false;
  fotoOpen = false;
  leegStapel();
  verbergOngedaan();
  try { localStorage.removeItem(LIJST_SLEUTEL); } catch {}
}

// De open lijst is niet meer van jou (verwijderd door de maker, of de lijst is weg of gearchiveerd): terug naar het overzicht
async function verlaatLijst(melding) {
  const id = currentList.id;
  sluitLijst();
  lijsten = lijsten.filter((l) => l.id !== id);
  naamOpen = false;
  profielOpen = false;
  await toonLijsten();
  say("setup-msg", melding || "Je bent uit een lijst verwijderd, of de lijst bestaat niet meer.");
}

function renderLijsten() {
  $("lijsten-leeg").hidden = lijsten.length > 0;
  $("lijsten").replaceChildren(...lijsten.map(lijstRij));
  $("archief-blok").hidden = archief.length === 0;
  $("archief-aantal").textContent = `(${archief.length})`;
  $("archief").replaceChildren(...archief.map(archiefRij));
}

// Aparte pagina om een lijst toe te voegen; lijstenOpen blijft aan zodat route() niet wegspringt
$("nieuw-knop").addEventListener("click", () => {
  say("nieuw-msg", "");
  show("nieuw");
});
$("nieuw-terug").addEventListener("click", toonLijsten);

// Geldt voor de hele lijst, dus ook voor de andere leden
async function setTeltMee(lijst, aan) {
  lijst.counts_for_profile = aan; // direct tonen, daarna opslaan
  say("setup-msg", "");
  const { error } = await db.rpc("set_list_profile", { p_list: lijst.id, p_counts: aan });
  if (error) {
    await loadLijsten();
    renderLijsten();
    say("setup-msg", error.message);
  }
}

$("lijsten-knop").addEventListener("click", toonLijsten);

// ---------- Lijst maken / aansluiten ----------
$("create-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const { data, error } = await db.rpc("create_list", { p_name: $("list-name").value.trim() });
  if (error) return say("nieuw-msg", error.message);
  $("list-name").value = "";
  openList(data);
});

$("join-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const { data, error } = await db.rpc("join_list", { p_code: $("join-code").value });
  if (error) return say("nieuw-msg", error.message);
  $("join-code").value = "";
  openList(data);
});

// ---------- De lijst ----------
async function openList(list) {
  const gewisseld = !currentList || currentList.id !== list.id;
  currentList = list;
  lijstenOpen = false;
  aankopenOpen = false;
  fotoOpen = false;
  bonOpen = false;
  if (!lijsten.some((l) => l.id === list.id)) lijsten.push(list);
  try { localStorage.setItem(LIJST_SLEUTEL, list.id); } catch {}
  // Bij wisselen niet kort de items van de vorige lijst laten zien
  if (gewisseld) { leegStapel(); items = []; leden = []; deals = {}; aankopen = null; infoId = null; verbergOngedaan(); say("status", ""); render(); }
  $("list-title").textContent = list.name;
  $("invite-code").textContent = list.invite_code;
  show("list");
  await loadItems();
  subscribe();
}

// Namen van jezelf en je lijstgenoten ophalen (de database geeft alleen die profielen terug)
async function loadNamen() {
  const { data, error } = await db.from("profiles").select("user_id, display_name");
  if (error) return;
  namen = Object.fromEntries(data.map((p) => [p.user_id, p.display_name]));
  render();
}

// Deelnemers van de huidige lijst ophalen
async function loadLeden() {
  const lijstId = currentList.id;
  const { data, error } = await db
    .from("list_members")
    .select("user_id, joined_at")
    .eq("list_id", lijstId)
    .order("joined_at", { ascending: true });
  if (!currentList || currentList.id !== lijstId) return;
  if (error) return;
  // Sta je er zelf niet meer in, dan ben je verwijderd (de database geeft dan niets terug)
  if (!data.some((m) => m.user_id === userId)) return verlaatLijst();
  leden = data;
  renderLeden();
}

function lidRij(lid) {
  const li = document.createElement("li");
  li.className = "lid-rij";

  const naam = document.createElement("span");
  naam.textContent = (namen[lid.user_id] || "iemand zonder naam") + (lid.user_id === userId ? " (jij)" : "");
  li.append(naam);

  if (lid.user_id === currentList.created_by) {
    const maker = document.createElement("small");
    maker.textContent = "maker";
    li.append(maker);
  }
  // Verwijderen kan alleen de maker; de database controleert dat ook
  if (currentList.created_by === userId && lid.user_id !== userId) {
    const weg = document.createElement("button");
    weg.type = "button";
    weg.className = "link";
    weg.textContent = "Verwijderen";
    weg.addEventListener("click", () => verwijderLid(lid));
    li.append(weg);
  }
  return li;
}

function renderLeden() {
  if (!currentList) return;
  $("leden-aantal").textContent = leden.length ? `(${leden.length})` : "";
  $("leden").replaceChildren(...leden.map(lidRij));
}

async function verwijderLid(lid) {
  const naam = namen[lid.user_id] || "Deze deelnemer";
  if (!confirm(`${naam} uit de lijst verwijderen? De code om te delen wordt daarna vernieuwd.`)) return;
  const lijstId = currentList.id;
  say("status", "");
  const { data, error } = await db.rpc("remove_member", { p_list: lijstId, p_user: lid.user_id });
  if (!currentList || currentList.id !== lijstId) return;
  if (error) { say("status", error.message); return loadLeden(); }
  leden = leden.filter((m) => m.user_id !== lid.user_id);
  currentList.invite_code = data.invite_code;
  $("invite-code").textContent = data.invite_code;
  renderLeden();
}

// Heeft de maker de open lijst intussen gearchiveerd? (realtime mist dat als de telefoon in standby stond)
async function controleerArchief() {
  const lijstId = currentList.id;
  const { data } = await db.from("lists").select("archived_at").eq("id", lijstId).maybeSingle();
  if (!currentList || currentList.id !== lijstId) return;
  if (data && data.archived_at) verlaatLijst(ARCHIEF_MELDING);
}

async function loadItems() {
  loadNamen();
  loadLeden();
  controleerArchief();
  const lijstId = currentList.id;
  const { data, error } = await db
    .from("items")
    .select("*")
    .eq("list_id", lijstId)
    .order("created_at", { ascending: true });
  // Intussen van lijst gewisseld (of uitgelogd)? Dan dit antwoord negeren.
  if (!currentList || currentList.id !== lijstId) return;
  if (error) return say("status", error.message);
  items = data;
  render();
  loadDeals();
}

// Aanbiedingen bij de items van deze lijst. Het zoeken gebeurt in de database (deals_for_list);
// we krijgen alleen per item terug bij welke supermarkt er hoeveel aanbiedingen zijn.
async function loadDeals() {
  if (!currentList) return;
  const lijstId = currentList.id;
  const vraag = ++dealsVraag;
  const { data, error } = await db.rpc("deals_for_list", { p_list: lijstId });
  if (vraag !== dealsVraag || !currentList || currentList.id !== lijstId) return;
  if (error) return; // geen aanbiedingen kunnen ophalen: dan gewoon geen labels
  const nieuw = {};
  data.forEach((d) => (nieuw[d.item_id] ||= []).push(d));
  deals = nieuw;
  render();
}

// Tekst van het label, bijv. "Bonus: AH 2, PLUS 1"
function dealTekst(lijst) {
  return "Bonus: " + [...lijst]
    .sort((a, b) => a.supermarkt.localeCompare(b.supermarkt))
    .map((d) => `${d.supermarkt} ${d.aantal}`)
    .join(", ");
}

function subscribe() {
  if (channel) db.removeChannel(channel);
  channel = db
    .channel("items-" + currentList.id)
    .on("postgres_changes",
      { event: "*", schema: "public", table: "items", filter: `list_id=eq.${currentList.id}` },
      (p) => {
        if (p.eventType === "INSERT") {
          if (!items.some((i) => i.id === p.new.id)) items.push(p.new);
          loadDeals();
        } else if (p.eventType === "UPDATE") {
          items = items.map((i) => (i.id === p.new.id ? p.new : i));
        } else if (p.eventType === "DELETE") {
          items = items.filter((i) => i.id !== p.old.id);
        }
        render();
      })
    .on("postgres_changes",
      { event: "*", schema: "public", table: "list_members", filter: `list_id=eq.${currentList.id}` },
      (p) => {
        if (!currentList) return;
        if (p.eventType === "INSERT") {
          // Iemand sluit aan: leden en de naam van de nieuwkomer ophalen
          loadLeden();
          loadNamen();
        } else if (p.eventType === "DELETE") {
          // Bij verwijderen zelf controleren om welke lijst het gaat
          if (p.old.list_id !== currentList.id) return;
          if (p.old.user_id === userId) return verlaatLijst();
          leden = leden.filter((m) => m.user_id !== p.old.user_id);
          renderLeden();
        }
      })
    .on("postgres_changes",
      { event: "UPDATE", schema: "public", table: "lists", filter: `id=eq.${currentList.id}` },
      (p) => {
        // De maker heeft de lijst gearchiveerd terwijl jij hem open had
        if (currentList && p.new.id === currentList.id && p.new.archived_at) verlaatLijst(ARCHIEF_MELDING);
      })
    .on("postgres_changes",
      { event: "*", schema: "public", table: "purchases", filter: `list_id=eq.${currentList.id}` },
      (p) => {
        // Nog niet opgehaald: dan komt alles straks mee met loadAankopen()
        if (!currentList || !aankopen) return;
        if (p.eventType === "INSERT") {
          if (p.new.list_id !== currentList.id) return;
          if (!aankopen.some((a) => a.id === p.new.id)) aankopen.unshift(p.new);
          // Een aankoop van een bon heeft de bondatum en hoort dus niet altijd bovenaan
          aankopen.sort((a, b) => new Date(b.bought_at) - new Date(a.bought_at));
        } else if (p.eventType === "UPDATE") {
          // Een bestaande aankoop is aan een bon gekoppeld en heeft nu een prijs
          aankopen = aankopen.map((a) => (a.id === p.new.id ? p.new : a));
        } else if (p.eventType === "DELETE") {
          // Bij verwijderen stuurt de database alleen de id mee
          aankopen = aankopen.filter((a) => a.id !== p.old.id);
        }
        renderAankopen();
      })
    .subscribe();
}

// Als de app weer zichtbaar wordt (telefoon uit standby), opnieuw ophalen
document.addEventListener("visibilitychange", () => {
  if (document.hidden || !currentList) return;
  loadItems();
  if (aankopenOpen) loadAankopen();
});

function itemRow(item) {
  const li = document.createElement("li");
  li.className = "item";

  // Gekleurde laag die tevoorschijn komt als je de rij opzij schuift
  const achter = document.createElement("div");
  achter.className = "item-achter";
  achter.setAttribute("aria-hidden", "true");
  const gekocht = document.createElement("span");
  gekocht.className = "achter-gekocht";
  gekocht.textContent = "✓ Gekocht";
  const weg = document.createElement("span");
  weg.className = "achter-weg";
  weg.textContent = "Verwijderen ×";
  achter.append(gekocht, weg);

  const voor = document.createElement("div");
  voor.className = "item-voor";

  // Knoppen doen hetzelfde als swipen, voor muis en toetsenbord
  const koopKnop = document.createElement("button");
  koopKnop.className = "koop";
  koopKnop.textContent = "✓";
  koopKnop.setAttribute("aria-label", "Gekocht");
  koopKnop.addEventListener("click", () => koop(item));

  const tekst = document.createElement("div");
  tekst.className = "item-tekst";
  const naam = document.createElement("span");
  naam.textContent = item.name;
  tekst.append(naam);
  if (item.quantity) {
    const q = document.createElement("small");
    q.textContent = item.quantity;
    tekst.append(q);
  }

  const del = document.createElement("button");
  del.className = "del";
  del.textContent = "×";
  del.setAttribute("aria-label", "Verwijderen");
  del.addEventListener("click", () => remove(item));

  const open = infoId === item.id;
  const info = document.createElement("button");
  info.className = "info";
  info.textContent = "?";
  info.setAttribute("aria-label", "Wie heeft dit toegevoegd?");
  info.setAttribute("aria-expanded", open);
  info.addEventListener("click", () => {
    infoId = open ? null : item.id;
    render();
    // Naam nog onbekend (bijv. net ingevuld door de ander)? Dan opnieuw ophalen.
    if (!open && item.added_by && !namen[item.added_by]) loadNamen();
  });

  voor.append(koopKnop, tekst, info, del);
  if (deals[item.id]) {
    const bonus = document.createElement("p");
    bonus.className = "item-deal";
    bonus.textContent = dealTekst(deals[item.id]);
    voor.append(bonus);
  }
  if (open) {
    const p = document.createElement("p");
    p.className = "item-info";
    p.textContent = itemInfo(item);
    voor.append(p);
  }
  li.append(achter, voor);
  maakSwipebaar(li, voor, item);
  return li;
}

// Rij opzij slepen: naar rechts = gekocht, naar links = verwijderen
function maakSwipebaar(li, voor, item) {
  let startX = 0, startY = 0, dx = 0;
  let pointer = null;
  let bezig = false; // vinger of muis is neer
  let vast = false;  // de beweging is herkend als opzij slepen

  // Zo ver moet de rij opzij voordat loslaten telt
  const drempel = () => Math.min(140, li.offsetWidth * 0.35);

  voor.addEventListener("pointerdown", (e) => {
    if (bezig || e.button !== 0 || e.target.closest("button")) return;
    pointer = e.pointerId;
    startX = e.clientX;
    startY = e.clientY;
    dx = 0;
    bezig = true;
  });

  voor.addEventListener("pointermove", (e) => {
    if (!bezig || e.pointerId !== pointer) return;
    const x = e.clientX - startX;
    const y = e.clientY - startY;
    if (!vast) {
      // Eerst zeker weten dat het om opzij gaat; omhoog/omlaag is scrollen
      if (Math.abs(y) > 10 && Math.abs(y) > Math.abs(x)) { bezig = false; return; }
      if (Math.abs(x) < 10) return;
      vast = true;
      slepen++;
      try { voor.setPointerCapture(pointer); } catch {}
      voor.style.transition = "none";
    }
    dx = x;
    voor.style.transform = `translateX(${dx}px)`;
    li.classList.toggle("naar-rechts", dx > 0);
    li.classList.toggle("naar-links", dx < 0);
    li.classList.toggle("voorbij", Math.abs(dx) > drempel());
  });

  function einde(e, afgebroken) {
    if (!bezig || e.pointerId !== pointer) return;
    bezig = false;
    if (!vast) return;
    vast = false;
    const doen = !afgebroken && Math.abs(dx) > drempel();
    const rechts = dx > 0;
    voor.style.transition = "";
    // Ver genoeg: de rij schuift het beeld uit; anders veert hij terug
    voor.style.transform = doen ? `translateX(${rechts ? 100 : -100}%)` : "";
    setTimeout(() => {
      slepen--;
      if (doen) return rechts ? koop(item) : remove(item);
      li.classList.remove("naar-rechts", "naar-links", "voorbij");
      if (renderWacht) render();
    }, 180);
  }
  voor.addEventListener("pointerup", (e) => einde(e, false));
  voor.addEventListener("pointercancel", (e) => einde(e, true));
}

// Datum in gewone taal, bijv. "di 6 oktober"
function datum(iso) {
  const d = new Date(iso);
  const opmaak = { weekday: "short", day: "numeric", month: "long" };
  if (d.getFullYear() !== new Date().getFullYear()) opmaak.year = "numeric";
  return d.toLocaleDateString("nl-NL", opmaak);
}

// Datum en tijd in gewone taal, bijv. "di 6 oktober om 14:32"
function datumTijd(iso) {
  const tijd = new Date(iso).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" });
  return `${datum(iso)} om ${tijd}`;
}

// Bedrag zoals je het in Nederland schrijft, bijv. "2,49"; leeg als het bedrag onbekend is
function bedragTekst(bedrag) {
  return bedrag == null ? "" : Number(bedrag).toFixed(2).replace(".", ",");
}

// Bedrag uit een invoerveld ("2,49" of "2.49"); null als het leeg is of geen bedrag
function leesBedrag(tekst) {
  const t = String(tekst).replace(/[€\s]/g, "").replace(",", ".");
  if (!t) return null;
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : null;
}

// Tekst onder een item: door wie en wanneer het is toegevoegd
function itemInfo(item) {
  const wie = namen[item.added_by] || "iemand zonder naam";
  return `Toegevoegd door ${wie} op ${datumTijd(item.created_at)}`;
}

function render() {
  // Niet opnieuw opbouwen terwijl er een rij wordt versleept: die zou onder je vinger verdwijnen
  if (slepen > 0) { renderWacht = true; return; }
  renderWacht = false;
  $("items").replaceChildren(...items.map(itemRow));
  renderLeden();
}

$("add-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = $("item-name").value.trim();
  if (!name) return;
  const quantity = $("item-qty").value.trim() || null;
  $("item-name").value = "";
  $("item-qty").value = "";
  $("item-name").focus();
  const { data, error } = await db
    .from("items")
    .insert({ list_id: currentList.id, name, quantity })
    .select()
    .single();
  if (error) return say("status", error.message);
  if (!items.some((i) => i.id === data.id)) items.push(data);
  render();
  loadDeals();
});

// Gekocht: het item gaat van de lijst en de database bewaart het als aankoop (als de lijst meetelt)
async function koop(item) {
  items = items.filter((i) => i.id !== item.id); // direct tonen, daarna opslaan
  render();
  const { data, error } = await db.rpc("buy_item", { p_item: item.id });
  if (!currentList || currentList.id !== item.list_id) return;
  if (error) { say("status", error.message); return loadItems(); }
  // Geen aankoop terwijl de lijst wel meetelt: de ander was net eerder, dus er valt niets terug te draaien
  if (!data && currentList.counts_for_profile !== false) return;
  toonOngedaan(`"${item.name}" gekocht`, item, data);
}

async function remove(item) {
  items = items.filter((i) => i.id !== item.id);
  render();
  const { error } = await db.from("items").delete().eq("id", item.id);
  if (!currentList || currentList.id !== item.list_id) return;
  if (error) { say("status", error.message); return loadItems(); }
  toonOngedaan(`"${item.name}" verwijderd`, item, null);
}

// Uitleg over vegen boven de lijst: wegklikken onthouden we op dit toestel
try { $("veeg-uitleg").hidden = localStorage.getItem(UITLEG_SLEUTEL) === "weg"; } catch {}
$("veeg-uitleg-weg").addEventListener("click", () => {
  $("veeg-uitleg").hidden = true;
  try { localStorage.setItem(UITLEG_SLEUTEL, "weg"); } catch {}
});

// ---------- Ongedaan maken ----------
// Balkje onderin dat een paar seconden blijft staan na gekocht of verwijderd
function toonOngedaan(tekst, item, aankoopId) {
  ongedaan = { item, aankoopId };
  $("ongedaan-tekst").textContent = tekst;
  $("ongedaan").hidden = false;
  clearTimeout(ongedaanTimer);
  ongedaanTimer = setTimeout(verbergOngedaan, 5000);
}

function verbergOngedaan() {
  clearTimeout(ongedaanTimer);
  ongedaan = null;
  $("ongedaan").hidden = true;
}

$("ongedaan-knop").addEventListener("click", async () => {
  if (!ongedaan) return;
  const { item, aankoopId } = ongedaan;
  verbergOngedaan();
  // Met aankoop: de database zet het item terug en haalt de aankoop weg.
  // Zonder aankoop (verwijderd, of de lijst telt niet mee): het item zelf opnieuw toevoegen.
  const { error } = aankoopId
    ? await db.rpc("undo_purchase", { p_purchase: aankoopId })
    : await db.from("items").insert({
        id: item.id, list_id: item.list_id, name: item.name, quantity: item.quantity,
        added_by: item.added_by, created_at: item.created_at
      });
  if (!currentList || currentList.id !== item.list_id) return;
  if (error) say("status", error.message);
  loadItems();
});

// ---------- Aankopen ----------
function toonAankopen() {
  aankopenOpen = true;
  aankopen = null;
  $("aankopen-lijst").textContent = currentList.name;
  $("aankopen-uitleg").hidden = currentList.counts_for_profile !== false;
  // Een bon scannen heeft alleen zin bij een lijst die meetelt; de database weigert het anders ook
  $("bon-knop").hidden = currentList.counts_for_profile === false;
  say("aankopen-msg", "");
  renderAankopen();
  show("aankopen");
  loadAankopen();
}

async function loadAankopen() {
  if (!currentList) return;
  const lijstId = currentList.id;
  const { data, error } = await db
    .from("purchases")
    .select("id, list_id, item_id, name, quantity, bought_by, bought_at, receipt_id, receipt_name, price, discount")
    .eq("list_id", lijstId)
    .order("bought_at", { ascending: false })
    .limit(200);
  if (!currentList || currentList.id !== lijstId) return;
  if (error) return say("aankopen-msg", error.message);
  aankopen = data;
  renderAankopen();
}

function aankoopRij(aankoop) {
  const li = document.createElement("li");
  li.className = "aankoop-rij";

  const tekst = document.createElement("div");
  tekst.className = "aankoop-tekst";
  const kop = document.createElement("div");
  kop.className = "aankoop-kop";
  const naam = document.createElement("span");
  naam.textContent = aankoop.name;
  kop.append(naam);
  if (aankoop.quantity) {
    const q = document.createElement("small");
    q.textContent = aankoop.quantity;
    kop.append(q);
  }
  // Prijs van de bon: wat er na aftrek van de korting is betaald
  if (aankoop.price != null) {
    const prijs = document.createElement("small");
    prijs.className = "aankoop-prijs";
    prijs.textContent = "€ " + bedragTekst(aankoop.price - (aankoop.discount || 0));
    kop.append(prijs);
  }

  // Bij aankopen uit oude afgestreepte items is niet bekend wie het kocht
  const wie = aankoop.bought_by ? ` door ${namen[aankoop.bought_by] || "iemand zonder naam"}` : "";
  // Een aankoop die alleen van een bon komt heeft geen tijdstip, alleen de datum van de bon
  const vanBon = aankoop.receipt_id && !aankoop.item_id;
  const p = document.createElement("p");
  p.className = "aankoop-info";
  p.textContent = vanBon
    ? `Gekocht op ${datum(aankoop.bought_at)}, van de bon`
    : `Gekocht${wie} op ${datumTijd(aankoop.bought_at)}`;
  if (aankoop.discount) p.textContent += `, € ${bedragTekst(aankoop.discount)} korting`;
  tekst.append(kop, p);

  const del = document.createElement("button");
  del.className = "del";
  del.textContent = "×";
  del.setAttribute("aria-label", "Aankoop verwijderen");
  del.addEventListener("click", () => verwijderAankoop(aankoop));

  li.append(tekst, del);
  return li;
}

// Aankoop weghalen (bijv. per ongeluk als gekocht gemarkeerd); het item komt niet terug op de lijst
async function verwijderAankoop(aankoop) {
  if (!confirm(`Aankoop "${aankoop.name}" verwijderen? Dit kan niet ongedaan worden gemaakt.`)) return;
  const lijstId = currentList.id;
  say("aankopen-msg", "");
  aankopen = (aankopen || []).filter((a) => a.id !== aankoop.id); // direct tonen, daarna opslaan
  renderAankopen();
  const { error } = await db.from("purchases").delete().eq("id", aankoop.id);
  if (!currentList || currentList.id !== lijstId) return;
  if (error) { say("aankopen-msg", error.message); loadAankopen(); }
}

function renderAankopen() {
  $("aankopen").replaceChildren(...(aankopen || []).map(aankoopRij));
  $("aankopen-leeg").hidden = !aankopen || aankopen.length > 0;
}

$("aankopen-knop").addEventListener("click", toonAankopen);
$("aankopen-terug").addEventListener("click", () => {
  aankopenOpen = false;
  render();
  show("list");
});

// ---------- Foto ----------
// Foto verkleinen en als JPEG (base64) teruggeven: kleiner verzoek, lagere kosten, en elk fotoformaat wordt leesbaar
function verkleinFoto(bestand) {
  return new Promise((klaar, mislukt) => {
    const url = URL.createObjectURL(bestand);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      const schaal = Math.min(1, FOTO_MAX / Math.max(img.naturalWidth, img.naturalHeight));
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.round(img.naturalWidth * schaal));
      canvas.height = Math.max(1, Math.round(img.naturalHeight * schaal));
      const ctx = canvas.getContext("2d");
      ctx.fillStyle = "#fff"; // doorzichtige delen worden anders zwart
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      klaar(canvas.toDataURL("image/jpeg", 0.85).split(",")[1]);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      mislukt(new Error("Deze afbeelding kan niet worden geopend."));
    };
    img.src = url;
  });
}

// Foutmelding van de Edge Function; die stuurt zelf een Nederlandse tekst mee in { fout }
async function fotoFout(error) {
  try {
    const inhoud = await error.context.json();
    if (inhoud && inhoud.fout) return inhoud.fout;
  } catch {}
  // Supabase kent de functie niet: hij is nog niet uitgerold (of heet anders)
  if (error.context && error.context.status === 404) return "Deze functie is nog niet uitgerold in Supabase.";
  return "De foto kon niet worden gelezen. Controleer je verbinding en probeer het opnieuw.";
}

// Foto laten lezen en de gevonden producten ter controle tonen
async function leesFoto(bestand) {
  const lijstId = currentList.id;
  const vraag = ++fotoVraag;
  fotoOpen = true;
  fotoProducten = [];
  $("foto-toevoegen").disabled = false;
  $("foto-lijst").textContent = currentList.name;
  renderFoto();
  say("foto-msg", "Foto wordt gelezen...");
  show("foto");

  let producten = null, melding = "";
  try {
    const afbeelding = await verkleinFoto(bestand);
    const { data, error } = await db.functions.invoke("foto-naar-items", { body: { afbeelding, type: "image/jpeg" } });
    if (error) melding = await fotoFout(error);
    else producten = (data && data.producten) || [];
  } catch (e) {
    melding = e.message;
  }
  // Intussen geannuleerd of van lijst gewisseld? Dan dit antwoord negeren.
  if (vraag !== fotoVraag || !fotoOpen || !currentList || currentList.id !== lijstId) return;
  if (!producten) return say("foto-msg", melding);
  fotoProducten = producten.map((p) => ({ naam: p.naam, hoeveelheid: p.hoeveelheid || "", aan: true }));
  renderFoto();
  say("foto-msg", fotoProducten.length ? "" : "Er zijn geen producten gevonden op deze foto.");
}

function fotoRij(product) {
  const li = document.createElement("li");
  li.className = "foto-rij";

  const box = document.createElement("input");
  box.type = "checkbox";
  box.checked = product.aan;
  box.setAttribute("aria-label", "Toevoegen aan lijst");
  box.addEventListener("change", () => { product.aan = box.checked; });

  const naam = document.createElement("input");
  naam.type = "text";
  naam.value = product.naam;
  naam.autocomplete = "off";
  naam.setAttribute("aria-label", "Product");
  naam.addEventListener("input", () => { product.naam = naam.value; });

  const aantal = document.createElement("input");
  aantal.type = "text";
  aantal.className = "qty";
  aantal.value = product.hoeveelheid;
  aantal.placeholder = "Aantal";
  aantal.autocomplete = "off";
  aantal.setAttribute("aria-label", "Aantal");
  aantal.addEventListener("input", () => { product.hoeveelheid = aantal.value; });

  li.append(box, naam, aantal);
  return li;
}

function renderFoto() {
  $("foto-producten").replaceChildren(...fotoProducten.map(fotoRij));
  $("foto-uitleg").hidden = fotoProducten.length === 0;
  $("foto-toevoegen").hidden = fotoProducten.length === 0;
}

function sluitFoto() {
  fotoOpen = false;
  fotoVraag++;
  fotoProducten = [];
  $("foto-toevoegen").disabled = false;
  render();
  show("list");
}

$("foto-knop").addEventListener("click", () => $("foto-invoer").click());
$("foto-invoer").addEventListener("change", () => {
  const bestand = $("foto-invoer").files[0];
  $("foto-invoer").value = ""; // zodat dezelfde foto daarna opnieuw gekozen kan worden
  if (bestand && currentList) leesFoto(bestand);
});
$("foto-terug").addEventListener("click", sluitFoto);

// De aangevinkte producten in één keer op de lijst zetten
$("foto-toevoegen").addEventListener("click", async () => {
  const lijstId = currentList.id;
  const rijen = fotoProducten
    .filter((p) => p.aan && p.naam.trim())
    .map((p) => ({ list_id: lijstId, name: p.naam.trim(), quantity: p.hoeveelheid.trim() || null }));
  if (rijen.length === 0) return say("foto-msg", "Vink minstens één product aan.");
  say("foto-msg", "Bezig...");
  $("foto-toevoegen").disabled = true;
  const { data, error } = await db.from("items").insert(rijen).select();
  if (!fotoOpen || !currentList || currentList.id !== lijstId) return;
  $("foto-toevoegen").disabled = false;
  if (error) return say("foto-msg", error.message);
  data.forEach((nieuw) => { if (!items.some((i) => i.id === nieuw.id)) items.push(nieuw); });
  sluitFoto();
  loadDeals();
});

// ---------- Bon ----------
// Bonnen die je kiest komen in een stapel (bonStapel) en worden op de achtergrond gelezen. Eén bon opent
// meteen "Bon controleren"; bij meer bonnen krijg je eerst het overzicht "Bonnen controleren".
// De stapel bestaat alleen in het geheugen: de bestanden gaan naar de Edge Function en worden nergens bewaard;
// opslaan gebeurt pas na controle, via save_receipt.

// Bestand klaarmaken om te versturen: een foto wordt verkleind, een pdf (bijv. de digitale bon
// uit de app van de supermarkt) gaat zoals hij is
function leesBonBestand(bestand) {
  if (bestand.type !== "application/pdf") return verkleinFoto(bestand).then((afbeelding) => ({ afbeelding, type: "image/jpeg" }));
  if (bestand.size > BON_PDF_MAX) return Promise.reject(new Error("Deze pdf is te groot."));
  return new Promise((klaar, mislukt) => {
    const lezer = new FileReader();
    lezer.onload = () => klaar({ afbeelding: lezer.result.split(",")[1], type: "application/pdf" });
    lezer.onerror = () => mislukt(new Error("Deze pdf kan niet worden geopend."));
    lezer.readAsDataURL(bestand);
  });
}

// Gekozen bestanden op de stapel leggen en beginnen met lezen
function startStapel(bestanden) {
  const nieuw = bestanden.slice(0, Math.max(0, BON_MAX - bonStapel.length)).map((bestand) => ({
    nr: ++bonNr, bestand, bestandsnaam: bestand.name || "Bon", status: "wacht", melding: "",
    supermarkt: "", datum: "", totaal: "", regels: [],
    dubbel: false, gecontroleerd: false, controleFout: false, controle: 0, uitkomst: null
  }));
  bonStapel.push(...nieuw);
  if (bonStapel.length === 1) openStapelBon(bonStapel[0]); else toonStapel();
  if (nieuw.length < bestanden.length) say("stapel-msg", `Je kunt hoogstens ${BON_MAX} bonnen tegelijk controleren. De rest is niet meegenomen.`);
  leesVolgende();
}

// Wachtende bonnen laten lezen, hoogstens BON_TEGELIJK tegelijk
function leesVolgende() {
  let lopend = bonStapel.filter((b) => b.status === "lezen").length;
  for (const bon of bonStapel) {
    if (lopend >= BON_TEGELIJK) break;
    if (bon.status !== "wacht") continue;
    lopend++;
    leesBon(bon);
  }
}

// Eén bon uit de stapel (foto of pdf) laten lezen door de Edge Function
async function leesBon(bon) {
  const lijstId = currentList.id;
  const vraag = bonVraag;
  bon.status = "lezen";
  bon.melding = "";
  renderStapel();

  let gelezen = null, melding = "";
  try {
    // De foto wordt pas hier verkleind, zodat niet alle bonnen tegelijk in het geheugen staan
    const { data, error } = await db.functions.invoke("bon-uploaden", { body: await leesBonBestand(bon.bestand) });
    if (error) melding = await fotoFout(error);
    else gelezen = (data && data.bon) || { regels: [] };
  } catch (e) {
    melding = e.message;
  }
  // Stapel intussen leeggemaakt, bon eruit gehaald of van lijst gewisseld? Dan dit antwoord negeren.
  if (vraag !== bonVraag || !bonStapel.includes(bon) || !currentList || currentList.id !== lijstId) return;
  if (gelezen && !(gelezen.regels || []).length) { gelezen = null; melding = "Er is geen kassabon gevonden op deze foto."; }
  if (gelezen) {
    bon.status = "klaar";
    bon.bestand = null; // de foto is niet meer nodig
    bon.supermarkt = gelezen.supermarkt || "";
    bon.datum = gelezen.datum || "";
    bon.totaal = bedragTekst(gelezen.totaal);
    bon.regels = gelezen.regels.map((r) => ({
      bonNaam: r.bon_naam, naam: r.naam, aantal: r.aantal > 1 ? String(r.aantal) : "",
      prijs: bedragTekst(r.prijs), korting: r.korting || null,
      aan: true, koppel: null, koppelAan: true
    }));
  } else {
    // Het bestand blijft staan, zodat "Opnieuw" in het overzicht het nog eens kan proberen
    bon.status = "fout";
    bon.melding = melding;
  }
  if (bonHuidig === bon && bonOpen) vulBon();
  renderStapel();
  leesVolgende();
  controleerBon(bon);
}

// Vraagt de database of deze bon al eens is toegevoegd, en welke regels lijken op een aankoop
// van dezelfde dag. Opnieuw na het wijzigen van supermarkt, datum, totaal of een productnaam,
// en na het opslaan van een andere bon uit de stapel. Geeft false als de controle is ingehaald of afgebroken.
async function controleerBon(bon = bonHuidig) {
  if (!bon || bon.status !== "klaar" || !currentList) return false;
  const lijstId = currentList.id;
  const vraag = ++bon.controle;
  const winkel = bon.supermarkt.trim();
  let dubbel = false, koppels = [], fout = false;
  if (bon.datum) {
    const [bestaat, gevonden] = await Promise.all([
      winkel
        ? db.rpc("receipt_exists", { p_list: lijstId, p_store: winkel, p_date: bon.datum, p_total: leesBedrag(bon.totaal) })
        : { data: false },
      db.rpc("match_receipt_lines", { p_list: lijstId, p_date: bon.datum, p_names: bon.regels.map((r) => r.naam) })
    ]);
    if (vraag !== bon.controle || bon.status !== "klaar" || !bonStapel.includes(bon) || !currentList || currentList.id !== lijstId) return false;
    fout = Boolean(bestaat.error || gevonden.error);
    dubbel = !bestaat.error && bestaat.data === true;
    koppels = gevonden.error ? [] : gevonden.data;
  }
  bon.dubbel = dubbel;
  bon.controleFout = fout;
  bon.gecontroleerd = true;
  if (bonHuidig === bon) $("bon-dubbel").hidden = !dubbel;
  const perRegel = {};
  koppels.forEach((k) => { perRegel[k.regel - 1] = { id: k.purchase_id, naam: k.name, heeftBon: k.has_receipt }; });
  // Alleen het regeltje over de koppeling bijwerken: de rij opnieuw opbouwen zou je uit een invoerveld gooien
  bon.regels.forEach((regel, i) => { regel.koppel = perRegel[i] || null; toonKoppel(regel); });
  renderStapel();
  return true;
}

// Som van de aangevinkte regels, na aftrek van korting
function bonSom(bon) {
  return bon.regels
    .filter((r) => r.aan)
    .reduce((s, r) => s + (leesBedrag(r.prijs) || 0) - (r.korting || 0), 0);
}

// Staat dezelfde bon (supermarkt, datum en totaal) al eerder in de stapel?
function dubbelInStapel(bon) {
  const winkel = bon.supermarkt.trim().toLowerCase();
  if (!winkel || !bon.datum) return false;
  return bonStapel.slice(0, bonStapel.indexOf(bon)).some((b) =>
    b.status === "klaar" && b.supermarkt.trim().toLowerCase() === winkel && b.datum === bon.datum
    && leesBedrag(b.totaal) === leesBedrag(bon.totaal));
}

// Alles wat aan een gelezen bon opvalt en eerst bekeken moet worden; leeg = kan zo worden opgeslagen
function bonTwijfels(bon) {
  const twijfels = [];
  const aan = bon.regels.filter((r) => r.aan);
  const totaal = leesBedrag(bon.totaal);
  const vandaag = new Date().toLocaleDateString("sv-SE"); // JJJJ-MM-DD in de eigen tijdzone
  if (!bon.supermarkt.trim()) twijfels.push("De supermarkt is niet gelezen.");
  if (!bon.datum) twijfels.push("De datum is niet gelezen.");
  else if (bon.datum > vandaag) twijfels.push("De datum ligt in de toekomst.");
  if (totaal === null) twijfels.push(bon.totaal.trim() ? "Het totaal is geen geldig bedrag." : "Het totaal is niet gelezen.");
  else if (Math.abs(bonSom(bon) - totaal) >= 0.005) twijfels.push(`De regels tellen op tot € ${bedragTekst(bonSom(bon))}, op de bon staat € ${bedragTekst(totaal)}.`);
  if (aan.length === 0) twijfels.push("Er is geen regel aangevinkt.");
  const zonderPrijs = aan.filter((r) => leesBedrag(r.prijs) === null).length;
  if (zonderPrijs) twijfels.push(zonderPrijs === 1 ? "Bij 1 regel ontbreekt de prijs." : `Bij ${zonderPrijs} regels ontbreekt de prijs.`);
  if (bon.dubbel) twijfels.push("Deze bon lijkt al te zijn toegevoegd.");
  if (dubbelInStapel(bon)) twijfels.push("Deze bon staat twee keer in deze stapel.");
  const gekoppeld = aan.filter((r) => r.koppel).length;
  if (gekoppeld) twijfels.push(gekoppeld === 1 ? "1 regel lijkt op een aankoop van dezelfde dag." : `${gekoppeld} regels lijken op een aankoop van dezelfde dag.`);
  if (bon.controleFout) twijfels.push("De controle op dubbelingen is niet gelukt.");
  return twijfels;
}

// Gelezen, gecontroleerd en niets op aan te merken: mag mee met "Alles zonder bijzonderheden opslaan"
function zonderTwijfel(bon) {
  return bon.status === "klaar" && bon.gecontroleerd && bonTwijfels(bon).length === 0;
}

// Wat er mis is met de invoer van een bon; leeg als hij zo kan worden opgeslagen
function bonFout(bon) {
  const gekozen = bon.regels.filter((r) => r.aan && r.naam.trim());
  if (!bon.supermarkt.trim()) return "Vul de supermarkt in.";
  if (!bon.datum) return "Vul de datum van de bon in.";
  if (bon.totaal.trim() && leesBedrag(bon.totaal) === null) return "Het totaal is geen geldig bedrag.";
  if (gekozen.length === 0) return "Vink minstens één regel aan.";
  if (gekozen.some((r) => r.prijs.trim() && leesBedrag(r.prijs) === null)) return "Een van de prijzen is geen geldig bedrag.";
  return "";
}

// De aangevinkte regels van een bon in één keer opslaan als aankopen, met de bondatum als aankoopdatum.
// Geeft de foutmelding terug, of "" als het is gelukt.
async function bewaarBon(bon) {
  const fout = bonFout(bon);
  if (fout) return fout;
  const regels = bon.regels.filter((r) => r.aan && r.naam.trim()).map((r) => ({
    name: r.naam.trim(), receipt_name: r.bonNaam, quantity: r.aantal.trim() || null,
    price: leesBedrag(r.prijs), discount: r.korting,
    purchase_id: r.koppel && r.koppelAan ? r.koppel.id : null
  }));
  const { data, error } = await db.rpc("save_receipt", {
    p_list: currentList.id, p_store: bon.supermarkt.trim(), p_date: bon.datum, p_total: leesBedrag(bon.totaal), p_lines: regels
  });
  if (error) return error.message;
  bon.status = "opgeslagen";
  bon.uitkomst = data || {};
  return "";
}

// Samenvatting van wat er van de opgeslagen bonnen bij de aankopen is gekomen
function uitkomstTekst(bonnen) {
  const tel = (veld) => bonnen.reduce((s, b) => s + (b.uitkomst[veld] || 0), 0);
  const delen = [`${tel("toegevoegd")} toegevoegd`];
  if (tel("gekoppeld")) delen.push(`${tel("gekoppeld")} gekoppeld aan een bestaande aankoop`);
  if (tel("overgeslagen")) delen.push(`${tel("overgeslagen")} overgeslagen omdat ze die dag al geteld zijn`);
  return delen.join(", ");
}

// ----- Het scherm "Bon controleren" -----
function openStapelBon(bon) {
  bonHuidig = bon;
  bonOpen = true;
  $("bon-lijst").textContent = currentList.name;
  $("bon-terug").textContent = bonStapel.length > 1 ? "Terug naar de bonnen" : "Annuleren";
  $("bon-opslaan").disabled = false;
  vulBon();
  show("bon");
}

// Velden en regels van de open bon op het scherm zetten
function vulBon() {
  const bon = bonHuidig;
  $("bon-supermarkt").value = bon.supermarkt;
  $("bon-datum").value = bon.datum;
  $("bon-totaal").value = bon.totaal;
  $("bon-dubbel").hidden = !bon.dubbel;
  renderBon();
  say("bon-msg", bon.status === "klaar" ? "" : bon.status === "fout" ? bon.melding : "Bon wordt gelezen...");
}

// Regeltje onder een bonregel als het product die dag al bij de aankopen staat
function toonKoppel(regel) {
  if (!regel.koppelVak) return;
  regel.koppelVak.replaceChildren();
  regel.koppelVak.hidden = !regel.koppel;
  if (!regel.koppel) return;
  const box = document.createElement("input");
  box.type = "checkbox";
  box.checked = regel.koppelAan;
  box.addEventListener("change", () => { regel.koppelAan = box.checked; });
  const tekst = document.createElement("span");
  tekst.textContent = regel.koppel.heeftBon
    ? `Staat die dag al op een andere bon als "${regel.koppel.naam}": telt niet opnieuw`
    : `Die dag al gekocht als "${regel.koppel.naam}": telt één keer, de prijs komt erbij`;
  regel.koppelVak.append(box, tekst);
}

function bonRij(regel) {
  const li = document.createElement("li");
  li.className = "bon-rij";

  const box = document.createElement("input");
  box.type = "checkbox";
  box.className = "bon-aan";
  box.checked = regel.aan;
  box.setAttribute("aria-label", "Opslaan als aankoop");
  box.addEventListener("change", () => { regel.aan = box.checked; toonBonSom(); });

  const naam = document.createElement("input");
  naam.type = "text";
  naam.value = regel.naam;
  naam.autocomplete = "off";
  naam.setAttribute("aria-label", "Product");
  naam.addEventListener("input", () => { regel.naam = naam.value; });
  naam.addEventListener("change", () => controleerBon());

  const aantal = document.createElement("input");
  aantal.type = "text";
  aantal.className = "bon-aantal";
  aantal.value = regel.aantal;
  aantal.placeholder = "1";
  aantal.autocomplete = "off";
  aantal.setAttribute("aria-label", "Aantal");
  aantal.addEventListener("input", () => { regel.aantal = aantal.value; });

  const prijs = document.createElement("input");
  prijs.type = "text";
  prijs.className = "bon-prijs";
  prijs.inputMode = "decimal";
  prijs.value = regel.prijs;
  prijs.placeholder = "0,00";
  prijs.autocomplete = "off";
  prijs.setAttribute("aria-label", "Prijs");
  prijs.addEventListener("input", () => { regel.prijs = prijs.value; toonBonSom(); });

  const info = document.createElement("p");
  info.className = "bon-info";
  info.textContent = "Op de bon: " + regel.bonNaam + (regel.korting ? `, € ${bedragTekst(regel.korting)} korting` : "");

  // <label>, zodat een tik op de tekst het vinkje omzet
  regel.koppelVak = document.createElement("label");
  regel.koppelVak.className = "bon-koppel";
  toonKoppel(regel);

  li.append(box, naam, aantal, prijs, info, regel.koppelVak);
  return li;
}

// Som van de aangevinkte regels naast het totaal van de bon: zo zie je of er iets mist of verkeerd is gelezen
function toonBonSom() {
  if (!bonHuidig) return say("bon-som", "");
  const som = bonSom(bonHuidig);
  const totaal = leesBedrag(bonHuidig.totaal);
  let tekst = `Som van de regels: € ${bedragTekst(som)}`;
  if (totaal !== null) {
    tekst += `, totaal op de bon: € ${bedragTekst(totaal)}.`;
    if (Math.abs(som - totaal) >= 0.005) tekst += " Een verschil kan komen door statiegeld of door regels die niet zijn meegenomen.";
  }
  say("bon-som", tekst);
}

function renderBon() {
  const regels = bonHuidig ? bonHuidig.regels : [];
  $("bon-regels").replaceChildren(...regels.map(bonRij));
  $("bon-inhoud").hidden = regels.length === 0;
  $("bon-opslaan").hidden = regels.length === 0;
  toonBonSom();
}

// Weg van "Bon controleren" zonder op te slaan: terug naar het overzicht van de stapel (de wijzigingen
// blijven daar staan), of bij een losse bon terug naar de aankopen en de bon weggooien
function sluitBon() {
  if (bonStapel.length > 1) return toonStapel();
  rondStapelAf();
}

$("bon-knop").addEventListener("click", () => $("bon-invoer").click());
$("bon-invoer").addEventListener("change", () => {
  const bestanden = [...$("bon-invoer").files];
  $("bon-invoer").value = ""; // zodat dezelfde foto daarna opnieuw gekozen kan worden
  if (bestanden.length && currentList) startStapel(bestanden);
});
$("bon-terug").addEventListener("click", sluitBon);
// De kopvelden schrijven hun waarde meteen in de open bon, zodat die bewaard blijft in de stapel
[["bon-supermarkt", "supermarkt"], ["bon-datum", "datum"], ["bon-totaal", "totaal"]].forEach(([id, veld]) => {
  $(id).addEventListener("input", () => { if (bonHuidig) bonHuidig[veld] = $(id).value; });
  $(id).addEventListener("change", () => {
    if (bonHuidig) bonHuidig[veld] = $(id).value;
    toonBonSom();
    controleerBon();
  });
});

$("bon-opslaan").addEventListener("click", async () => {
  const bon = bonHuidig;
  if (!bon || bon.status !== "klaar") return;
  const lijstId = currentList.id;
  const fout = bonFout(bon);
  if (fout) return say("bon-msg", fout);
  if (bon.dubbel && !confirm("Deze bon lijkt al te zijn toegevoegd. Toch opslaan?")) return;

  say("bon-msg", "Bezig...");
  $("bon-opslaan").disabled = true;
  const melding = await bewaarBon(bon);
  if (bonHuidig !== bon || !currentList || currentList.id !== lijstId) return;
  $("bon-opslaan").disabled = false;
  if (melding) return say("bon-msg", melding);
  naOpslaan();
});

// ----- Het overzicht "Bonnen controleren" -----
function toonStapel() {
  bonHuidig = null;
  bonOpen = false;
  $("stapel-lijst").textContent = currentList.name;
  say("stapel-msg", "");
  renderStapel();
  show("stapel");
}

// Na het opslaan van één of meer bonnen: klaar als alles is opgeslagen, anders verder met de rest.
// Die wordt opnieuw gecontroleerd, want een net opgeslagen bon kan een andere dubbel hebben gemaakt.
function naOpslaan() {
  if (bonStapel.every((b) => b.status === "opgeslagen")) return rondStapelAf();
  toonStapel();
  bonStapel.forEach((b) => controleerBon(b));
}

// Stapel leegmaken en terug naar de aankopen, met een samenvatting van wat er is opgeslagen
function rondStapelAf() {
  const klaar = bonStapel.filter((b) => b.status === "opgeslagen");
  const tekst = klaar.length
    ? (klaar.length === 1 ? "Bon verwerkt: " : `${klaar.length} bonnen verwerkt: `) + uitkomstTekst(klaar) + "."
    : "";
  leegStapel();
  renderAankopen();
  show("aankopen");
  say("aankopen-msg", tekst);
  loadAankopen();
}

// De stapel weggooien; antwoorden van bonnen die nog gelezen worden, worden daarna genegeerd
function leegStapel() {
  bonStapel = [];
  bonHuidig = null;
  bonOpen = false;
  stapelBezig = false;
  bonVraag++;
  renderStapel();
}

function stapelRij(bon) {
  const li = document.createElement("li");
  li.className = "stapel-rij";
  const gelezen = bon.status === "klaar" || bon.status === "opgeslagen";

  // Alleen een gelezen bon die nog niet is opgeslagen kun je openen
  const knop = document.createElement(bon.status === "klaar" ? "button" : "div");
  knop.className = "bonnen-open";
  if (bon.status === "klaar") {
    knop.type = "button";
    knop.disabled = stapelBezig;
    knop.addEventListener("click", () => openStapelBon(bon));
  }
  const kop = document.createElement("div");
  kop.className = "bonnen-kop";
  const winkel = document.createElement("span");
  winkel.textContent = gelezen ? bon.supermarkt.trim() || "Onbekende supermarkt" : bon.bestandsnaam;
  kop.append(winkel);
  if (gelezen && leesBedrag(bon.totaal) !== null) {
    const totaal = document.createElement("small");
    totaal.textContent = "€ " + bedragTekst(leesBedrag(bon.totaal));
    kop.append(totaal);
  }
  const info = document.createElement("p");
  info.className = "bonnen-info";
  if (bon.status === "wacht") info.textContent = "Wacht op lezen";
  else if (bon.status === "lezen") info.textContent = "Wordt gelezen...";
  else if (bon.status === "fout") info.textContent = bon.melding || "De bon kon niet worden gelezen.";
  else {
    const aantal = bon.regels.filter((r) => r.aan).length;
    info.textContent = (bon.datum ? datum(bon.datum) : "Geen datum") + `, ${aantal} ${aantal === 1 ? "regel" : "regels"}`;
  }
  knop.append(kop, info);
  li.append(knop);

  if (bon.status === "fout") {
    const opnieuw = document.createElement("button");
    opnieuw.type = "button";
    opnieuw.className = "link";
    opnieuw.textContent = "Opnieuw";
    opnieuw.disabled = stapelBezig;
    opnieuw.addEventListener("click", () => { bon.status = "wacht"; renderStapel(); leesVolgende(); });
    li.append(opnieuw);
  }
  if (bon.status !== "opgeslagen") {
    const del = document.createElement("button");
    del.className = "del";
    del.textContent = "×";
    del.disabled = stapelBezig;
    del.setAttribute("aria-label", "Bon uit de stapel halen");
    del.addEventListener("click", () => {
      bonStapel = bonStapel.filter((b) => b !== bon);
      if (bonStapel.length === 0 || bonStapel.every((b) => b.status === "opgeslagen")) return rondStapelAf();
      renderStapel();
      leesVolgende();
    });
    li.append(del);
  }

  if (bon.status === "opgeslagen") {
    const p = document.createElement("p");
    p.className = "stapel-goed";
    p.textContent = "Opgeslagen: " + uitkomstTekst([bon]) + ".";
    li.append(p);
  } else if (bon.status === "klaar") {
    const twijfels = bon.gecontroleerd ? bonTwijfels(bon) : [];
    if (twijfels.length) {
      const vak = document.createElement("div");
      vak.className = "waarschuwing stapel-twijfels";
      vak.append(...twijfels.map((t) => { const p = document.createElement("p"); p.textContent = t; return p; }));
      li.append(vak);
    } else {
      const p = document.createElement("p");
      p.className = "stapel-goed";
      p.textContent = bon.gecontroleerd ? "Geen bijzonderheden" : "Wordt gecontroleerd...";
      li.append(p);
    }
  }
  return li;
}

// Overzicht van de stapel, plus de knop bij de aankopen waarmee je er weer naartoe kunt
function renderStapel() {
  $("stapel").replaceChildren(...bonStapel.map(stapelRij));
  const open = bonStapel.filter((b) => b.status !== "opgeslagen").length;
  const goed = bonStapel.filter(zonderTwijfel).length;
  $("stapel-opslaan").hidden = goed === 0;
  $("stapel-opslaan").disabled = stapelBezig;
  $("stapel-opslaan").textContent = stapelBezig ? "Bezig..." : `Alles zonder bijzonderheden opslaan (${goed})`;
  $("stapel-terug").disabled = stapelBezig;
  $("stapel-leeg").disabled = stapelBezig;
  $("stapel-knop").hidden = open === 0;
  $("stapel-knop").textContent = `Bonnen controleren (${open})`;
}

// Alle bonnen zonder bijzonderheden één voor één opslaan
$("stapel-opslaan").addEventListener("click", async () => {
  if (stapelBezig || !currentList) return;
  const lijstId = currentList.id;
  const vraag = bonVraag;
  const weg = () => vraag !== bonVraag || !currentList || currentList.id !== lijstId;
  stapelBezig = true;
  say("stapel-msg", "");
  renderStapel();
  let melding = "", opgeslagen = 0;
  for (const bon of [...bonStapel]) {
    if (!zonderTwijfel(bon)) continue;
    // Vlak voor het opslaan opnieuw controleren: een bon die net is opgeslagen kan deze dubbel hebben gemaakt
    const gecontroleerd = await controleerBon(bon);
    if (weg()) return;
    if (!gecontroleerd || !zonderTwijfel(bon)) continue;
    melding = await bewaarBon(bon);
    if (weg()) return;
    if (melding) break;
    opgeslagen++;
  }
  stapelBezig = false;
  naOpslaan();
  if (bonStapel.length) say("stapel-msg", melding || `${opgeslagen} ${opgeslagen === 1 ? "bon" : "bonnen"} opgeslagen. De rest heeft nog een controle nodig.`);
});
$("stapel-knop").addEventListener("click", toonStapel);
// Terug naar de aankopen; de stapel blijft staan en het lezen loopt door
$("stapel-terug").addEventListener("click", () => {
  renderAankopen();
  show("aankopen");
  loadAankopen();
});
$("stapel-leeg").addEventListener("click", () => {
  const open = bonStapel.filter((b) => b.status !== "opgeslagen").length;
  if (open && !confirm(open === 1 ? "Er staat nog 1 bon die niet is opgeslagen. Weggooien?" : `Er staan nog ${open} bonnen die niet zijn opgeslagen. Weggooien?`)) return;
  rondStapelAf();
});

// ---------- Bonnen ----------
// Overzicht van de gescande bonnen van deze lijst. Het scherm hoort bij de aankopen:
// aankopenOpen blijft aan, zodat route() er niet van wegspringt.
function toonBonnen() {
  bonnen = null;
  bonInzien = null;
  bonInhoud = {};
  $("bonnen-lijst").textContent = currentList.name;
  say("bonnen-msg", "");
  renderBonnen();
  show("bonnen");
  loadBonnen();
}

async function loadBonnen() {
  if (!currentList) return;
  const lijstId = currentList.id;
  const { data, error } = await db
    .from("receipts")
    .select("id, list_id, store, receipt_date, total, added_by")
    .eq("list_id", lijstId)
    .order("receipt_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(200);
  if (!currentList || currentList.id !== lijstId) return;
  if (error) return say("bonnen-msg", error.message);
  bonnen = data;
  renderBonnen();
}

// De aankopen die bij een bon horen; pas ophalen als je de bon openklapt
async function loadBonInhoud(bon) {
  const { data, error } = await db
    .from("purchases")
    .select("id, name, quantity, receipt_name, price, discount")
    .eq("receipt_id", bon.id)
    .order("name", { ascending: true });
  if (!currentList || currentList.id !== bon.list_id) return;
  if (error) return say("bonnen-msg", error.message);
  bonInhoud[bon.id] = data;
  renderBonnen();
}

function bonnenRij(bon) {
  const li = document.createElement("li");
  const open = bonInzien === bon.id;

  const knop = document.createElement("button");
  knop.type = "button";
  knop.className = "bonnen-open";
  knop.setAttribute("aria-expanded", open);
  const kop = document.createElement("div");
  kop.className = "bonnen-kop";
  const winkel = document.createElement("span");
  winkel.textContent = bon.store;
  kop.append(winkel);
  if (bon.total != null) {
    const totaal = document.createElement("small");
    totaal.textContent = "€ " + bedragTekst(bon.total);
    kop.append(totaal);
  }
  const info = document.createElement("p");
  info.className = "bonnen-info";
  info.textContent = datum(bon.receipt_date) + (bon.added_by ? `, toegevoegd door ${namen[bon.added_by] || "iemand zonder naam"}` : "");
  knop.append(kop, info);
  knop.addEventListener("click", () => {
    bonInzien = open ? null : bon.id;
    renderBonnen();
    if (!open) loadBonInhoud(bon);
  });

  const del = document.createElement("button");
  del.className = "del";
  del.textContent = "×";
  del.setAttribute("aria-label", "Bon verwijderen");
  del.addEventListener("click", () => verwijderBon(bon));

  li.append(knop, del);
  if (!open) return li;

  const regels = document.createElement("div");
  regels.className = "bonnen-regels";
  const inhoud = bonInhoud[bon.id];
  if (!inhoud || inhoud.length === 0) {
    const p = document.createElement("p");
    p.textContent = inhoud ? "Van deze bon staan geen aankopen meer in de lijst." : "Bezig...";
    regels.append(p);
  } else {
    regels.append(...inhoud.map((a) => {
      const rij = document.createElement("div");
      rij.className = "bonnen-regel";
      const naam = document.createElement("span");
      naam.textContent = a.name + (a.quantity ? ` (${a.quantity})` : "");
      if (a.receipt_name) naam.title = a.receipt_name; // de tekst zoals die op de bon stond
      rij.append(naam);
      if (a.price != null) {
        const prijs = document.createElement("small");
        prijs.textContent = "€ " + bedragTekst(a.price - (a.discount || 0));
        rij.append(prijs);
      }
      return rij;
    }));
  }
  li.append(regels);
  return li;
}

function renderBonnen() {
  $("bonnen").replaceChildren(...(bonnen || []).map(bonnenRij));
  $("bonnen-uitleg").hidden = !bonnen || bonnen.length === 0;
  $("bonnen-leeg").hidden = !bonnen || bonnen.length > 0;
}

// Bon weghalen. De database haalt ook de aankopen weg die alleen van deze bon kwamen; een aankoop
// die al via de lijst als gekocht was gemarkeerd blijft staan en raakt alleen de bongegevens kwijt.
async function verwijderBon(bon) {
  if (!confirm(`Bon van ${bon.store} van ${datum(bon.receipt_date)} verwijderen? De aankopen van deze bon verdwijnen ook. Wat je al op de lijst als gekocht had gemarkeerd blijft staan, zonder prijs.`)) return;
  say("bonnen-msg", "");
  const { error } = await db.rpc("delete_receipt", { p_receipt: bon.id });
  if (!currentList || currentList.id !== bon.list_id) return;
  if (error) { say("bonnen-msg", error.message); return loadBonnen(); }
  bonnen = (bonnen || []).filter((b) => b.id !== bon.id);
  if (bonInzien === bon.id) bonInzien = null;
  renderBonnen();
}

$("bonnen-knop").addEventListener("click", toonBonnen);
$("bonnen-terug").addEventListener("click", () => {
  renderAankopen();
  show("aankopen");
  loadAankopen();
});

// ---------- PWA ----------
if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js");

init();
