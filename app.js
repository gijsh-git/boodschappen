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
const views = ["login", "forgot", "sent", "password", "naam", "profiel", "setup", "nieuw", "list"];
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
    if (s) route(); else { mijnNaam = null; naamOpen = false; profielOpen = false; lijstenOpen = false; show("login"); }
  });
  if (session) route(); else show("login");
  if (linkError) say("login-msg", "De link is verlopen of al gebruikt. Vraag een nieuwe aan via 'Wachtwoord vergeten?'.");
}

async function route() {
  if (mustSetPassword) { naamOpen = false; profielOpen = false; lijstenOpen = false; return show("password"); }
  // Supabase meldt de sessie opnieuw als de app terug in beeld komt; dan niet wegspringen van naam, profiel of overzicht
  if (naamOpen || profielOpen || lijstenOpen) return;
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
  lijsten = [];
  namen = {};
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
  if (!confirm(`Lijst "${lijst.name}" verwijderen? Alle items verdwijnen, ook voor de andere leden. Dit kan niet ongedaan worden gemaakt.`)) return;
  say("setup-msg", "");
  const { error } = await db.rpc("delete_list", { p_list: lijst.id });
  if (error) return say("setup-msg", error.message);
  lijsten = lijsten.filter((l) => l.id !== lijst.id);
  if (currentList && currentList.id === lijst.id) {
    if (channel) db.removeChannel(channel);
    channel = null;
    currentList = null;
    items = [];
    try { localStorage.removeItem(LIJST_SLEUTEL); } catch {}
  }
  renderLijsten();
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
  if (!lijsten.some((l) => l.id === list.id)) lijsten.push(list);
  try { localStorage.setItem(LIJST_SLEUTEL, list.id); } catch {}
  // Bij wisselen niet kort de items van de vorige lijst laten zien
  if (gewisseld) { items = []; infoId = null; say("status", ""); render(); }
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

async function loadItems() {
  loadNamen();
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
        } else if (p.eventType === "UPDATE") {
          items = items.map((i) => (i.id === p.new.id ? p.new : i));
        } else if (p.eventType === "DELETE") {
          items = items.filter((i) => i.id !== p.old.id);
        }
        render();
      })
    .subscribe();
}

// Als de app weer zichtbaar wordt (telefoon uit standby), opnieuw ophalen
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && currentList) loadItems();
});

function itemRow(item) {
  const li = document.createElement("li");
  li.className = item.checked ? "checked" : "";

  const label = document.createElement("label");
  const box = document.createElement("input");
  box.type = "checkbox";
  box.checked = item.checked;
  box.addEventListener("change", () => toggle(item, box.checked));

  const text = document.createElement("span");
  text.textContent = item.name;

  label.append(box, text);
  if (item.quantity) {
    const q = document.createElement("small");
    q.textContent = item.quantity;
    label.append(q);
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

  li.append(label, info, del);
  if (open) {
    const p = document.createElement("p");
    p.className = "item-info";
    p.textContent = itemInfo(item);
    li.append(p);
  }
  return li;
}

// Tekst onder een item: door wie en wanneer het is toegevoegd
function itemInfo(item) {
  const d = new Date(item.created_at);
  const dag = d.toLocaleDateString("nl-NL", { weekday: "short", day: "numeric", month: "long" });
  const tijd = d.toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" });
  const wie = namen[item.added_by] || "iemand zonder naam";
  return `Toegevoegd door ${wie} op ${dag} om ${tijd}`;
}

function render() {
  const open = items.filter((i) => !i.checked);
  const done = items.filter((i) => i.checked);
  $("items").replaceChildren(...open.map(itemRow));
  $("done-items").replaceChildren(...done.map(itemRow));
  $("done-title").hidden = done.length === 0;
  $("clear-done").hidden = done.length === 0;
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
});

async function toggle(item, checked) {
  item.checked = checked; // direct tonen, daarna opslaan
  render();
  const { error } = await db
    .from("items")
    .update({ checked, checked_at: checked ? new Date().toISOString() : null })
    .eq("id", item.id);
  if (error) { say("status", error.message); loadItems(); }
}

async function remove(item) {
  items = items.filter((i) => i.id !== item.id);
  render();
  const { error } = await db.from("items").delete().eq("id", item.id);
  if (error) { say("status", error.message); loadItems(); }
}

$("clear-done").addEventListener("click", async () => {
  const ids = items.filter((i) => i.checked).map((i) => i.id);
  items = items.filter((i) => !i.checked);
  render();
  const { error } = await db.from("items").delete().in("id", ids);
  if (error) { say("status", error.message); loadItems(); }
});

// ---------- PWA ----------
if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js");

init();
