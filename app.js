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
const views = ["login", "forgot", "sent", "password", "naam", "profiel", "setup", "nieuw", "list", "aankopen"];
let resetEmail = "";
let userId = null;
let mijnNaam = null;   // weergavenaam; null = nog niet opgehaald of nog niet ingevuld
let naamOpen = false;  // het naam-scherm staat open
let naamBewerken = false; // naam-scherm is geopend vanuit het profiel (niet de eerste keer)
let profielOpen = false;  // het profiel-scherm (of het naam-scherm daarbinnen) staat open
let namen = {};        // user_id -> weergavenaam van jezelf en je lijstgenoten
let infoId = null;     // item waarvan de info ("toegevoegd door") openstaat
let lijsten = [];      // alle lijsten waar je lid van bent
let lijstenOpen = false;  // het overzicht van lijsten staat open
const LIJST_SLEUTEL = "bonusbuddy-lijst"; // localStorage: id van de laatst geopende lijst
let currentList = null;
let channel = null;
let items = [];
let leden = [];        // deelnemers van de huidige lijst: { user_id, joined_at }
let deals = {};        // item-id -> [{ supermarkt, aantal }]: actuele aanbiedingen per item
let dealsVraag = 0;    // volgnummer, zodat een laat antwoord een nieuwer antwoord niet overschrijft
let aankopen = null;   // aankopen van de huidige lijst, nieuwste eerst; null = nog niet opgehaald
let aankopenOpen = false; // het scherm met aankopen staat open
let slepen = 0;        // aantal rijen dat nu wordt versleept (of nog uitschuift)
let renderWacht = false;  // er is een render() overgeslagen tijdens het slepen
let ongedaan = null;   // laatste actie die nog terug te draaien is: { item, aankoopId }
let ongedaanTimer = null;
let audio = null;      // AudioContext voor de geluidjes; pas aangemaakt na de eerste aanraking

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
    if (s) route(); else { mijnNaam = null; naamOpen = false; profielOpen = false; lijstenOpen = false; aankopenOpen = false; show("login"); }
  });
  if (session) route(); else show("login");
  if (linkError) say("login-msg", "De link is verlopen of al gebruikt. Vraag een nieuwe aan via 'Wachtwoord vergeten?'.");
}

async function route() {
  if (mustSetPassword) { naamOpen = false; profielOpen = false; lijstenOpen = false; aankopenOpen = false; return show("password"); }
  // Supabase meldt de sessie opnieuw als de app terug in beeld komt; dan niet wegspringen van naam, profiel, overzicht of aankopen
  if (naamOpen || profielOpen || lijstenOpen || aankopenOpen) return;
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
  show("profiel");
}

$("profiel-knop").addEventListener("click", toonProfiel);
$("profiel-terug").addEventListener("click", () => {
  profielOpen = false;
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
  lijsten = [];
  leden = [];
  deals = {};
  aankopen = null;
  namen = {};
  verbergOngedaan();
  show("login");
}
$("logout").addEventListener("click", logout);
$("logout-setup").addEventListener("click", logout);

// ---------- Overzicht van lijsten ----------
// Haalt al je lijsten op; geeft de fout terug als het misgaat
async function loadLijsten() {
  const { data, error } = await db
    .from("list_members")
    .select("list_id, lists(id, name, invite_code, counts_for_profile, created_by)")
    // Alleen je eigen lidmaatschappen: je mag ook die van lijstgenoten zien, en dan staat een lijst er dubbel
    .eq("user_id", userId)
    .order("joined_at", { ascending: true });
  if (error) return error;
  lijsten = data.map((m) => m.lists).filter(Boolean);
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
  // Verwijderen kan alleen de maker; de database controleert dat ook
  if (lijst.created_by === userId) {
    const weg = document.createElement("button");
    weg.type = "button";
    weg.className = "link lijst-weg";
    weg.textContent = "Lijst verwijderen";
    weg.addEventListener("click", () => verwijderLijst(lijst));
    li.append(weg);
  }
  return li;
}

async function verwijderLijst(lijst) {
  if (!confirm(`Lijst "${lijst.name}" verwijderen? Alle items en aankopen verdwijnen, ook voor de andere leden. Dit kan niet ongedaan worden gemaakt.`)) return;
  say("setup-msg", "");
  // Vooraf loslaten: anders meldt realtime ons eigen verdwenen lidmaatschap als "je bent verwijderd"
  if (currentList && currentList.id === lijst.id) sluitLijst();
  const { error } = await db.rpc("delete_list", { p_list: lijst.id });
  if (error) return say("setup-msg", error.message);
  lijsten = lijsten.filter((l) => l.id !== lijst.id);
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
  verbergOngedaan();
  try { localStorage.removeItem(LIJST_SLEUTEL); } catch {}
}

// Je bent geen lid meer van de open lijst (verwijderd door de maker, of de lijst is weg): terug naar het overzicht
async function verlaatLijst() {
  const id = currentList.id;
  sluitLijst();
  lijsten = lijsten.filter((l) => l.id !== id);
  naamOpen = false;
  profielOpen = false;
  await toonLijsten();
  say("setup-msg", "Je bent uit een lijst verwijderd, of de lijst bestaat niet meer.");
}

function renderLijsten() {
  $("lijsten-leeg").hidden = lijsten.length > 0;
  $("lijsten").replaceChildren(...lijsten.map(lijstRij));
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
  if (!lijsten.some((l) => l.id === list.id)) lijsten.push(list);
  try { localStorage.setItem(LIJST_SLEUTEL, list.id); } catch {}
  // Bij wisselen niet kort de items van de vorige lijst laten zien
  if (gewisseld) { items = []; leden = []; deals = {}; aankopen = null; infoId = null; verbergOngedaan(); say("status", ""); render(); }
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

async function loadItems() {
  loadNamen();
  loadLeden();
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
      { event: "*", schema: "public", table: "purchases", filter: `list_id=eq.${currentList.id}` },
      (p) => {
        // Nog niet opgehaald: dan komt alles straks mee met loadAankopen()
        if (!currentList || !aankopen) return;
        if (p.eventType === "INSERT") {
          if (p.new.list_id !== currentList.id) return;
          if (!aankopen.some((a) => a.id === p.new.id)) aankopen.unshift(p.new);
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

// Datum en tijd in gewone taal, bijv. "di 6 oktober om 14:32"
function datumTijd(iso) {
  const d = new Date(iso);
  const opmaak = { weekday: "short", day: "numeric", month: "long" };
  if (d.getFullYear() !== new Date().getFullYear()) opmaak.year = "numeric";
  const dag = d.toLocaleDateString("nl-NL", opmaak);
  const tijd = d.toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" });
  return `${dag} om ${tijd}`;
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
  geluidKassa();
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
  geluidWeg();
  const { error } = await db.from("items").delete().eq("id", item.id);
  if (!currentList || currentList.id !== item.list_id) return;
  if (error) { say("status", error.message); return loadItems(); }
  toonOngedaan(`"${item.name}" verwijderd`, item, null);
}

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

// ---------- Geluid ----------
// Browsers laten pas geluid toe na een aanraking of toets, dus dan maken we de AudioContext klaar
function wekGeluid() {
  try {
    audio ||= new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state === "suspended") audio.resume();
  } catch {}
}
["pointerdown", "touchend", "click", "keydown"].forEach((soort) => document.addEventListener(soort, wekGeluid));

// Eén toon die uitsterft; met eindFreq glijdt de toonhoogte daarheen
function toon(freq, start, duur, volume, type = "sine", eindFreq = null) {
  const t = audio.currentTime + start;
  const osc = audio.createOscillator();
  const gain = audio.createGain();
  osc.type = type;
  osc.frequency.setValueAtTime(freq, t);
  if (eindFreq) osc.frequency.exponentialRampToValueAtTime(eindFreq, t + duur);
  gain.gain.setValueAtTime(volume, t);
  gain.gain.exponentialRampToValueAtTime(0.001, t + duur);
  osc.connect(gain);
  gain.connect(audio.destination);
  osc.start(t);
  osc.stop(t + duur);
}

// Kassa: een droge tik van de la, daarna een rinkelend belletje
function geluidKassa() {
  if (!audio) return;
  try {
    toon(190, 0, 0.07, 0.25, "square", 80);
    toon(2093, 0.08, 0.9, 0.2);
    toon(2120, 0.08, 0.9, 0.12); // net ernaast: geeft het rinkelen
    toon(2637, 0.08, 0.7, 0.12);
    toon(3136, 0.08, 0.5, 0.06);
  } catch {}
}

// Verwijderen: een korte toon die omlaag zakt
function geluidWeg() {
  if (!audio) return;
  try { toon(420, 0, 0.2, 0.2, "triangle", 130); } catch {}
}

// ---------- Aankopen ----------
function toonAankopen() {
  aankopenOpen = true;
  aankopen = null;
  $("aankopen-lijst").textContent = currentList.name;
  $("aankopen-uitleg").hidden = currentList.counts_for_profile !== false;
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
    .select("id, list_id, name, quantity, bought_by, bought_at")
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

  const naam = document.createElement("span");
  naam.textContent = aankoop.name;
  li.append(naam);
  if (aankoop.quantity) {
    const q = document.createElement("small");
    q.textContent = aankoop.quantity;
    li.append(q);
  }

  // Bij aankopen uit oude afgestreepte items is niet bekend wie het kocht
  const wie = aankoop.bought_by ? ` door ${namen[aankoop.bought_by] || "iemand zonder naam"}` : "";
  const p = document.createElement("p");
  p.className = "aankoop-info";
  p.textContent = `Gekocht${wie} op ${datumTijd(aankoop.bought_at)}`;
  li.append(p);
  return li;
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

// ---------- PWA ----------
if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js");

init();
