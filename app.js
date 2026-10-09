const { SUPABASE_URL, SUPABASE_ANON_KEY } = window.CONFIG;

// Links uit een mail (uitnodiging, wachtwoord vergeten) komen binnen met gegevens achter de #.
// Die lezen we hier uit, vóórdat Supabase de # opruimt.
const linkParams = new URLSearchParams(location.hash.slice(1));
const linkType = linkParams.get("type");
const linkError = linkParams.get("error_description");
// Na een uitnodiging of "wachtwoord vergeten" moet er eerst een wachtwoord gekozen worden.
let mustSetPassword = linkType === "invite" || linkType === "recovery";

// Uitnodigingslink (?uitnodiging=...): de code onthouden tot je bent ingelogd en uit de adresbalk halen
const UITNODIGING_SLEUTEL = "bonusbuddy-uitnodiging";
const uitnodiging = new URLSearchParams(location.search).get("uitnodiging");
if (uitnodiging) {
  try { localStorage.setItem(UITNODIGING_SLEUTEL, uitnodiging); } catch {}
  history.replaceState(null, "", location.pathname + location.hash);
}

Data.init(SUPABASE_URL, SUPABASE_ANON_KEY);

const $ = (id) => document.getElementById(id);
const views = ["login", "forgot", "sent", "password", "naam", "profiel", "setup", "nieuw", "list", "aankopen", "foto", "bon", "bonnen", "stapel", "producten", "voorjou"];
let resetEmail = "";
let userId = null;
let mijnNaam = null;   // weergavenaam; null = nog niet opgehaald of nog niet ingevuld
let naamOpen = false;  // het naam-scherm staat open
let naamBewerken = false; // naam-scherm is geopend vanuit het profiel (niet de eerste keer)
let profielOpen = false;  // het profiel-scherm (of het naam- of productenscherm daarbinnen) staat open
let beheerder = false; // je bent beheerder: je mag de koppelingen en de types beheren
let aankoopprofiel = null; // het antwoord van purchase_profile; null = nog niet opgehaald
let profielPeriode = "3m"; // gekozen periode van het aankoopprofiel: 4w, 3m, 12m of alles
let profielLijst = "";  // id van de lijst waarop het aankoopprofiel is gefilterd; leeg = alle lijsten
let profielVraag = 0;   // volgnummer, zodat een laat antwoord een nieuwere keuze niet overschrijft
let namen = {};        // user_id -> weergavenaam van jezelf en je lijstgenoten
let lijsten = [];      // de actieve lijsten waar je lid van bent
let archief = [];      // de gearchiveerde lijsten waar je lid van bent
let lijstenOpen = false;  // het overzicht van lijsten staat open
const LIJST_SLEUTEL = "bonusbuddy-lijst"; // localStorage: id van de laatst geopende lijst
const ARCHIEF_MELDING = "Deze lijst is gearchiveerd door de maker.";
const UITLEG_SLEUTEL = "bonusbuddy-veeguitleg"; // localStorage: "weg" als de uitleg over vegen is weggeklikt
let currentList = null;
let items = [];
let leden = [];        // deelnemers van de huidige lijst: { user_id, joined_at }
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
// regels: { bonNaam, naam, aantal, prijs, korting, aan, koppel, koppelAan, item, itemAan }
// item: { id, naam, zeker } = wat er bij deze regel nog op de lijst staat; itemAan: null zolang je niet zelf hebt gekozen
let bonStapel = [];
let bonNr = 0;         // volgnummer voor de bonnen in de stapel
let bonHuidig = null;  // de bon uit de stapel die in "Bon controleren" open staat
let bonVraag = 0;      // volgnummer van de stapel, zodat een antwoord na leegmaken genegeerd wordt
let stapelBezig = false; // "Alles zonder bijzonderheden opslaan" loopt
let slepen = 0;        // aantal rijen dat nu wordt versleept (of nog uitschuift)
let renderWacht = false;  // er is een render() overgeslagen tijdens het slepen
let laatsteVeeg = 0;   // tijdstip waarop de laatste veeg eindigde, om de klik erna te negeren
let itemOpen = null;   // id van het item waarbij is uitgeklapt wie het toevoegde
let ongedaan = null;   // laatste actie die nog terug te draaien is: { item, aankoopId }
let ongedaanTimer = null;
let zicht = null;      // het scherm dat nu in beeld is
let voorjouOpen = false; // het scherm "Voor jou" staat open
let tipProduct = null; // het product dat nu in de grote kaart van "Voor jou" staat
const TABS = { list: "lijst", setup: "lijst", voorjou: "voorjou", profiel: "profiel" }; // schermen met de onderbalk, en welke tab dan oranje is

function show(view) {
  views.forEach((v) => ($("view-" + v).hidden = v !== view));
  $("tabbalk").hidden = !TABS[view];
  for (const knop of $("tabbalk").children) {
    if (knop.dataset.tab === TABS[view]) knop.setAttribute("aria-current", "page"); else knop.removeAttribute("aria-current");
  }
  toonLijstMenu(false);
  // Een ander scherm begint bovenaan
  if (view !== zicht) window.scrollTo(0, 0);
  zicht = view;
}

// Eerste letter van een naam, voor het rondje van een deelnemer
function initiaal(naam) {
  return (naam || "?").trim().charAt(0).toUpperCase();
}

function hoofdletter(tekst) {
  return tekst.charAt(0).toUpperCase() + tekst.slice(1);
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
  const { data: { session } } = await Data.sessie();
  userId = session ? session.user.id : null;
  Data.bijSessieWijziging((event, s) => {
    if (event === "PASSWORD_RECOVERY") mustSetPassword = true;
    userId = s ? s.user.id : null;
    if (s) route(); else { mijnNaam = null; naamOpen = false; profielOpen = false; voorjouOpen = false; lijstenOpen = false; aankopenOpen = false; fotoOpen = false; leegStapel(); show("login"); }
  });
  if (session) route(); else show("login");
  if (linkError) say("login-msg", "De link is verlopen of al gebruikt. Vraag een nieuwe aan via 'Wachtwoord vergeten?'.");
}

async function route() {
  if (mustSetPassword) { naamOpen = false; profielOpen = false; voorjouOpen = false; lijstenOpen = false; aankopenOpen = false; fotoOpen = false; bonOpen = false; return show("password"); }
  // Supabase meldt de sessie opnieuw als de app terug in beeld komt; dan niet wegspringen van naam, profiel, voor jou, overzicht, aankopen, foto of bon
  if (naamOpen || profielOpen || voorjouOpen || lijstenOpen || aankopenOpen || fotoOpen || bonOpen) return;
  if (mijnNaam === null) {
    const { data: profiel, error: profielFout } = await Data.eigenNaam(userId);
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
  // Binnengekomen via een uitnodigingslink: aansluiten en die lijst openen
  const welkom = await verwerkUitnodiging();
  if (mustSetPassword) return show("password");
  if (welkom.lijst) return openList(welkom.lijst);
  if (welkom.fout) { toonOverzicht(); return say("setup-msg", welkom.fout); }
  if (lijsten.length === 0) return toonOverzicht();
  // De laatst geopende lijst weer openen; anders de eerste
  let laatste = null;
  try { laatste = localStorage.getItem(LIJST_SLEUTEL); } catch {}
  openList(lijsten.find((l) => l.id === laatste) || lijsten[0]);
}

// Sluit aan bij de lijst van een onthouden uitnodiging; geeft { lijst } of { fout } terug, of niets als er geen was
async function verwerkUitnodiging() {
  let code = null;
  try { code = localStorage.getItem(UITNODIGING_SLEUTEL); localStorage.removeItem(UITNODIGING_SLEUTEL); } catch {}
  if (!code) return {};
  const { data, error } = await Data.sluitAan(code);
  return error ? { fout: error.message } : { lijst: data };
}

// ---------- Inloggen ----------
$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  say("login-msg", "Bezig...");
  const { error } = await Data.logIn($("email").value.trim(), $("password").value);
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
  return Data.stuurHerstelMail(email, location.origin + location.pathname);
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
  const { error } = await Data.zetWachtwoord($("new-password").value);
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
  const { error } = await Data.bewaarNaam(userId, naam);
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
  voorjouOpen = false;
  $("profiel-naam").textContent = mijnNaam || "Nog niet ingevuld";
  $("profiel-avatar").textContent = initiaal(mijnNaam);
  Data.sessie().then(({ data }) => { $("profiel-email").textContent = data.session ? data.session.user.email : ""; });
  $("producten-knop").hidden = !beheerder;
  show("profiel");
  loadBeheerder();
  renderAankoopprofiel();
  loadAankoopprofiel();
  stopFavorietBewerken();
  renderFavorieten();
  loadFavorieten();
}

// De rol staat in de database; de knop is alleen een gemak, de functies controleren het zelf
async function loadBeheerder() {
  const { data } = await Data.isBeheerder();
  beheerder = data === true;
  $("producten-knop").hidden = !beheerder;
}

// ---------- Onderbalk ----------
// Lijst, Voor jou en Profiel. "Lijst" gaat naar het overzicht van je lijsten; heb je er maar één, dan meteen naar die lijst.
function naarLijst() {
  profielOpen = false;
  voorjouOpen = false;
  naamOpen = false;
  if (!currentList || lijsten.length !== 1) return toonLijsten();
  lijstenOpen = false;
  render();
  show("list");
}

$("tabbalk").addEventListener("click", (e) => {
  const knop = e.target.closest("button[data-tab]");
  if (!knop) return;
  if (knop.dataset.tab === "profiel") return toonProfiel();
  if (knop.dataset.tab === "voorjou") return toonVoorJou();
  naarLijst();
});

// ---------- Voor jou ----------
// Bovenaan de aanbiedingen die voor jou tellen: via je favorieten en via de vaste producten van het huishouden.
// Daaronder de vaste producten zelf: de top 10 van de laatste 3 maanden uit het aankoopprofiel.
// Het product dat volgens het koopritme het eerst weer nodig is staat in de grote kaart; één tik zet het op de open lijst.
function toonVoorJou() {
  voorjouOpen = true;
  profielOpen = false;
  naamOpen = false;
  $("voorjou-week").textContent = "Week " + weekNr();
  say("voorjou-msg", Logica.voorJou() ? "" : "Bezig...");
  renderVoorJou();
  show("voorjou");
  loadVoorJou();
  loadAanbod();
}

async function loadAanbod() {
  const antwoord = await Logica.laadAanbiedingen(() => voorjouOpen);
  if (!antwoord) return;
  if (antwoord.fout) return say("voorjou-msg", antwoord.fout);
  renderVoorJou();
}

async function loadVoorJou() {
  const antwoord = await Logica.laadVoorJou(() => voorjouOpen);
  if (!antwoord) return;
  if (antwoord.fout) return say("voorjou-msg", antwoord.fout);
  say("voorjou-msg", "");
  renderVoorJou();
}

// Weeknummer zoals op de kalender (ISO: de week van de eerste donderdag is week 1)
function weekNr() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7));
  const week1 = new Date(d.getFullYear(), 0, 4);
  return 1 + Math.round(((d - week1) / 864e5 - 3 + ((week1.getDay() + 6) % 7)) / 7);
}

// Het koopritme in gewone taal, bijv. "Koop je elke week"
function ritmeTekst(product) {
  const n = Number(product.om_de);
  if (product.om_de == null) return "Koop je vaak";
  if (n === 1) return "Koop je elke dag";
  if (n === 7) return "Koop je elke week";
  if (n % 7 === 0) return `Koop je elke ${n / 7} weken`;
  return `Koop je om de ${getal(n)} dagen`;
}

function voorjouRij(product) {
  const li = document.createElement("li");
  li.className = "voorjou-rij";
  const tekst = document.createElement("div");
  tekst.className = "item-tekst";
  const naam = document.createElement("span");
  naam.className = "item-naam";
  naam.textContent = hoofdletter(product.naam);
  const sub = document.createElement("span");
  sub.className = "item-sub";
  sub.textContent = Logica.bijnaOp(product) ? "Is bijna op, volgens je koopritme" : ritmeTekst(product);
  tekst.append(naam, sub);
  li.append(tekst);
  if (currentList) {
    const plus = document.createElement("button");
    plus.type = "button";
    plus.className = "plus";
    plus.setAttribute("aria-label", `${hoofdletter(product.naam)} op de lijst zetten`);
    plus.innerHTML = '<svg width="24" height="24" aria-hidden="true"><use href="#icon-plus"/></svg>';
    plus.addEventListener("click", () => zetOpLijst(product.naam));
    li.append(plus);
  }
  return li;
}

// Laatste geldige dag van een aanbieding, bijv. "zo 11 okt"
function totDatum(dag) {
  return new Date(dag).toLocaleDateString("nl-NL", { weekday: "short", day: "numeric", month: "short" }).replace(".", "");
}

// Alleen de dag van de week, voor op de lijst: "zo"
function totDag(dag) {
  return new Date(dag).toLocaleDateString("nl-NL", { weekday: "short" }).replace(".", "");
}

// Waarom de aanbieding hier staat: je favoriet, of een product dat jullie vaak kopen
function aanbodReden(aanbieding) {
  const favoriet = aanbieding.favorieten[0];
  if (favoriet) return "Favoriet: " + [favoriet.brand, favoriet.term].filter(Boolean).join(" ");
  return "Koop je vaak: " + aanbieding.producten.map((p) => p.naam).join(", ");
}

// Een aanbieding die voor jou telt: de korting, waar en tot wanneer, en één tik om het op de open lijst te zetten
function aanbodRij(aanbieding, opLijst) {
  const li = document.createElement("li");
  li.className = "voorjou-rij aanbod-rij";
  const tekst = document.createElement("div");
  tekst.className = "item-tekst";
  const korting = document.createElement("span");
  korting.className = "bonus-label";
  korting.textContent = aanbieding.korting || "Bonus";
  const naam = document.createElement("span");
  naam.className = "item-naam";
  naam.textContent = aanbieding.titel;
  const sub = document.createElement("span");
  sub.className = "item-sub";
  sub.textContent = `${Logica.winkelNaam(aanbieding.supermarkt)} · t/m ${totDatum(aanbieding.geldig_tot)}`;
  const reden = document.createElement("span");
  reden.className = "item-sub";
  const opDeLijst = Logica.aanbiedingNaam(aanbieding);
  const staatErAl = opLijst.has(opDeLijst.trim().toLowerCase()) || items.some((i) => i.offer_id === aanbieding.id);
  reden.textContent = aanbodReden(aanbieding) + (staatErAl ? " · staat op de lijst" : "");
  tekst.append(korting, naam, sub, reden);
  // Alleen voor jezelf, tot de aanbieding verloopt
  const acties = document.createElement("div");
  acties.className = "keuze-acties";
  acties.append(keuzeKnop("Niet deze week", "link", () => klikWegVoorMij(aanbieding)));
  tekst.append(acties);
  li.append(tekst);
  if (currentList && !staatErAl) {
    const plus = document.createElement("button");
    plus.type = "button";
    plus.className = "plus";
    plus.setAttribute("aria-label", `${hoofdletter(opDeLijst)} op de lijst zetten`);
    plus.innerHTML = '<svg width="24" height="24" aria-hidden="true"><use href="#icon-plus"/></svg>';
    plus.addEventListener("click", () => zetOpLijst(opDeLijst, aanbieding.id));
    li.append(plus);
  }
  return li;
}

async function klikWegVoorMij(aanbieding) {
  const antwoord = await Logica.klikWegVoorMij(aanbieding.id);
  if (antwoord.fout) return say("voorjou-msg", antwoord.fout);
  renderVoorJou();
}

function renderVoorJou() {
  const voorjou = Logica.voorJou();
  const over = Logica.voorJouOver(items);
  const aanbod = Logica.aanbiedingen() || [];
  const opLijst = new Set(items.map((i) => i.name.trim().toLowerCase()));
  $("aanbod-kop").hidden = aanbod.length === 0;
  $("aanbod-lijst").replaceChildren(...aanbod.map((a) => aanbodRij(a, opLijst)));
  const [eerste, ...rest] = over;
  tipProduct = eerste || null;
  $("tip-kaart").hidden = !eerste;
  if (eerste) {
    $("tip-ritme").textContent = ritmeTekst(eerste);
    $("tip-naam").textContent = hoofdletter(eerste.naam);
    $("tip-info").textContent = `Laatst gekocht op ${datum(eerste.laatste)}` + (Logica.bijnaOp(eerste) ? " · is bijna op, volgens je koopritme" : "");
    $("tip-toevoegen").hidden = !currentList;
  }
  $("voorjou-kop").hidden = rest.length === 0;
  $("voorjou-lijst").replaceChildren(...rest.map(voorjouRij));
  $("voorjou-leeg").hidden = !voorjou || over.length > 0;
  $("voorjou-leeg").textContent = voorjou && voorjou.length === 0
    ? "Nog te weinig aankopen om iets voor te stellen. Veeg producten naar rechts als je ze gekocht hebt, of scan een bon."
    : "Niets meer voor te stellen: je vaste producten staan op de lijst of je hebt ze overgeslagen.";
}

// Een voorgesteld product of een aanbieding op de open lijst zetten. Een aanbieding gaat via de database: die
// zet de titel op de lijst en onthoudt bij het item de aanbieding (voor het Bonus-label), het artikel en het
// product uit de catalogus.
async function zetOpLijst(naam, aanbiedingId) {
  if (!currentList) return;
  const lijst = currentList;
  const { data, error } = aanbiedingId
    ? await Data.zetAanbiedingOpLijst(lijst.id, aanbiedingId)
    : await Data.voegItemToe({ list_id: lijst.id, name: hoofdletter(naam) });
  if (error) return say("voorjou-msg", error.message);
  if (currentList && currentList.id === lijst.id) {
    if (!items.some((i) => i.id === data.id)) items.push(data);
    render();
    loadDeals();
  }
  if (!voorjouOpen) return;
  renderVoorJou();
  say("voorjou-msg", `"${data.name}" staat op ${lijst.name}.`);
}

$("tip-toevoegen").addEventListener("click", () => { if (tipProduct) zetOpLijst(tipProduct.naam); });
$("tip-nietnu").addEventListener("click", () => {
  if (!tipProduct) return;
  Logica.slaOver(tipProduct.naam);
  say("voorjou-msg", "");
  renderVoorJou();
});

// ---------- Aankoopprofiel ----------
// De database rekent alles uit (purchase_profile); hier wordt het alleen getoond
async function loadAankoopprofiel() {
  const vraag = ++profielVraag;
  say("ap-msg", aankoopprofiel ? "" : "Bezig...");
  const { data, error } = await Data.aankoopprofiel(profielPeriode, profielLijst || null);
  if (vraag !== profielVraag || !profielOpen) return;
  if (error) return say("ap-msg", error.message);
  // De gekozen lijst telt niet meer mee of is weg: terug naar alle lijsten
  if (profielLijst && !data.lijsten.some((l) => l.id === profielLijst)) {
    profielLijst = "";
    return loadAankoopprofiel();
  }
  aankoopprofiel = data;
  say("ap-msg", "");
  renderAankoopprofiel();
}

// Bedrag met euroteken, bijv. "€ 1.234,56"
function euro(bedrag) {
  return Number(bedrag).toLocaleString("nl-NL", { style: "currency", currency: "EUR" });
}

function getal(n) {
  return Number(n).toLocaleString("nl-NL");
}

// Rij in de top 10: plaats, product met ritme en laatste aankoop, en het aantal aankoopdagen
function topRij(product, i) {
  const li = document.createElement("li");
  const rang = document.createElement("span");
  rang.className = "ap-rang";
  rang.textContent = i + 1 + ".";
  const blok = document.createElement("div");
  blok.className = "ap-product";
  const naam = document.createElement("span");
  naam.textContent = product.naam;
  const info = document.createElement("p");
  const ritme = product.om_de == null ? "te weinig data"
    : product.om_de === 1 ? "elke dag"
    : `om de ${getal(product.om_de)} dagen`;
  info.textContent = `${ritme} · laatst ${datum(product.laatste)}`;
  blok.append(naam, info);
  const dagen = document.createElement("small");
  dagen.textContent = product.dagen === 1 ? "1 dag" : product.dagen + " dagen";
  li.append(rang, blok, dagen);
  return li;
}

// Eén staafje: naam, staaf als deel van de grootste, en de waarde als tekst erachter
function staafRij(naam, deel, waarde, soort, onder) {
  const li = document.createElement("li");
  if (soort) li.className = soort;
  const label = document.createElement("span");
  label.className = "ap-staaf-naam";
  label.textContent = naam;
  if (onder) {
    const klein = document.createElement("small");
    klein.textContent = onder;
    label.append(klein);
  }
  const baan = document.createElement("span");
  baan.className = "ap-staaf-baan";
  if (deel > 0) {
    const staaf = document.createElement("i");
    staaf.style.width = Math.round(deel * 100) + "%";
    baan.append(staaf);
  }
  const tekst = document.createElement("span");
  tekst.className = "ap-staaf-waarde";
  tekst.textContent = waarde;
  li.append(label, baan, tekst);
  return li;
}

function renderAankoopprofiel() {
  for (const knop of $("ap-periode").children) knop.setAttribute("aria-pressed", knop.dataset.periode === profielPeriode);
  const p = aankoopprofiel;
  $("ap-inhoud").hidden = !p;
  $("ap-lijst").hidden = !p;
  if (!p) return;

  const alle = document.createElement("option");
  alle.value = "";
  alle.textContent = "Alle lijsten";
  $("ap-lijst").replaceChildren(alle, ...p.lijsten.map((l) => {
    const o = document.createElement("option");
    o.value = l.id;
    o.textContent = l.gearchiveerd ? `${l.name} (gearchiveerd)` : l.name;
    return o;
  }));
  $("ap-lijst").value = profielLijst;

  $("ap-bereik").textContent = p.van ? `Vanaf ${datum(p.van)} tot en met vandaag.`
    : p.eerste ? `Alles sinds de eerste aankoop op ${datum(p.eerste)}.` : "";
  $("ap-aankopen").textContent = getal(p.aankopen);
  $("ap-producten").textContent = getal(p.producten);
  $("ap-uitgegeven").textContent = euro(p.uitgegeven);
  $("ap-bespaard").textContent = euro(p.bespaard);
  $("ap-prijs").textContent = p.rijen === 0 ? ""
    : `Prijs bekend bij ${Math.round((p.met_prijs / p.rijen) * 100)}% van de aankopen (${getal(p.met_prijs)} van ${getal(p.rijen)}).`;

  $("ap-top").replaceChildren(...p.top.map(topRij));
  $("ap-top-leeg").hidden = p.top.length > 0;

  const meeste = Math.max(1, ...p.winkels.map((w) => w.aankopen));
  $("ap-winkels").replaceChildren(...p.winkels.map((w) =>
    staafRij(w.winkel || "onbekend", w.aankopen / meeste,
      w.bedrag == null ? getal(w.aankopen) : `${getal(w.aankopen)} · ${euro(w.bedrag)}`)));

  const hoogste = Math.max(1, ...p.maanden.map((m) => Number(m.bedrag) || 0));
  $("ap-maanden").replaceChildren(...p.maanden.map((m) => {
    const naam = new Date(m.maand + "-01").toLocaleDateString("nl-NL", { month: "short", year: "2-digit" });
    const onder = m.lopend ? "tot nu toe" : "";
    if (m.bedrag == null) return staafRij(naam, 0, "geen prijsdata", "leeg", onder);
    return staafRij(naam, m.bedrag / hoogste, euro(m.bedrag), m.lopend ? "lopend" : "", onder);
  }));
}

$("ap-periode").addEventListener("click", (e) => {
  const knop = e.target.closest("button[data-periode]");
  if (!knop) return;
  profielPeriode = knop.dataset.periode;
  renderAankoopprofiel();
  loadAankoopprofiel();
});
$("ap-lijst").addEventListener("change", () => {
  profielLijst = $("ap-lijst").value;
  loadAankoopprofiel();
});

// ---------- Favorieten ----------
// De sectie "Mijn favorieten" op het profiel. De favorieten zelf en de regels staan in logica.js;
// hier alleen het tonen en het formulier.
let favBewerk = null;    // de favoriet die in het formulier staat om te wijzigen; null = een nieuwe toevoegen
let favSuggestie = null; // de gekozen suggestie voor de term ({ term, category }); bepaalt de categorie bij het opslaan
const favTimers = {};    // per veld de wachttijd voordat de suggesties worden opgehaald

async function loadFavorieten() {
  const { fout } = await Logica.laadFavorieten();
  if (!profielOpen) return;
  if (fout) return say("fav-msg", fout);
  renderFavorieten();
}

function renderFavorieten() {
  const lijst = Logica.favorieten();
  $("fav-lijst").replaceChildren(...(lijst || []).map(favorietRij));
  $("fav-leeg").hidden = !lijst || lijst.length > 0;
}

function favorietRij(favoriet) {
  const li = document.createElement("li");
  li.className = "aankoop-rij fav-rij";

  const tekst = document.createElement("div");
  tekst.className = "aankoop-tekst";
  const kop = document.createElement("div");
  kop.className = "aankoop-kop";
  const naam = document.createElement("span");
  naam.textContent = favoriet.term || favoriet.brand;
  kop.append(naam);
  const info = document.createElement("p");
  info.className = "aankoop-info";
  const merk = !favoriet.term ? "Alles van dit merk" : favoriet.brand ? "Alleen " + favoriet.brand : "Elk merk";
  info.textContent = favoriet.category ? `${merk} · in ${favoriet.category}` : merk;
  tekst.append(kop, info);

  const wijzig = document.createElement("button");
  wijzig.type = "button";
  wijzig.className = "del";
  wijzig.setAttribute("aria-label", "Favoriet wijzigen");
  wijzig.innerHTML = '<svg width="18" height="18" aria-hidden="true"><use href="#icon-potlood"/></svg>';
  wijzig.addEventListener("click", () => bewerkFavoriet(favoriet));

  const del = document.createElement("button");
  del.type = "button";
  del.className = "del";
  del.textContent = "×";
  del.setAttribute("aria-label", "Favoriet verwijderen");
  del.addEventListener("click", async () => {
    if (favBewerk && favBewerk.id === favoriet.id) stopFavorietBewerken();
    const klaar = Logica.verwijderFavoriet(favoriet.id);
    renderFavorieten();
    const { fout } = await klaar;
    say("fav-msg", fout || "");
    if (fout) renderFavorieten();
  });

  li.append(tekst, wijzig, del);
  return li;
}

// Zet een favoriet in het formulier om hem te wijzigen
function bewerkFavoriet(favoriet) {
  favBewerk = favoriet;
  favSuggestie = favoriet.term ? { term: favoriet.term, category: favoriet.category } : null;
  $("fav-term").value = favoriet.term || "";
  $("fav-merk").value = favoriet.brand || "";
  $("fav-bewaar").textContent = "Opslaan";
  $("fav-annuleer").hidden = false;
  sluitSuggesties();
  say("fav-msg", "");
  $("fav-term").focus();
}

// Formulier leeg, terug naar "Toevoegen"
function stopFavorietBewerken() {
  favBewerk = null;
  favSuggestie = null;
  $("fav-form").reset();
  $("fav-bewaar").textContent = "Toevoegen";
  $("fav-annuleer").hidden = true;
  sluitSuggesties();
  say("fav-msg", "");
}

function sluitSuggesties() {
  for (const soort of ["term", "merk"]) {
    clearTimeout(favTimers[soort]);
    Logica.stopSuggesties(soort);
    $(`fav-${soort}-sug`).replaceChildren();
  }
}

// Haalt de suggesties voor één veld op, even nadat het typen stopt
function vraagSuggesties(soort) {
  clearTimeout(favTimers[soort]);
  favTimers[soort] = setTimeout(async () => {
    const veld = $(`fav-${soort}`);
    const gevonden = await Logica.favorietSuggesties(soort, veld.value);
    if (gevonden === null || !profielOpen) return;
    // Staat er al precies wat de enige suggestie is, dan valt er niets te kiezen
    const getypt = Logica.zoekvorm(veld.value);
    const zinloos = soort === "merk" && gevonden.length === 1 && Logica.zoekvorm(gevonden[0].brand) === getypt;
    $(`fav-${soort}-sug`).replaceChildren(...(zinloos ? [] : gevonden).map((s) => suggestieRij(soort, s)));
  }, 250);
}

function suggestieRij(soort, suggestie) {
  const li = document.createElement("li");
  const knop = document.createElement("button");
  knop.type = "button";
  knop.className = "fav-kies";
  const naam = document.createElement("span");
  naam.textContent = soort === "term" ? suggestie.term : suggestie.brand;
  knop.append(naam);
  if (soort === "term" && suggestie.category) {
    const categorie = document.createElement("small");
    categorie.textContent = suggestie.category;
    knop.append(categorie);
  }
  knop.addEventListener("click", () => {
    $(`fav-${soort}`).value = naam.textContent;
    if (soort === "term") favSuggestie = { term: suggestie.term, category: suggestie.category };
    Logica.stopSuggesties(soort);
    $(`fav-${soort}-sug`).replaceChildren();
    $(soort === "term" ? "fav-merk" : "fav-bewaar").focus();
  });
  li.append(knop);
  return li;
}

$("fav-term").addEventListener("input", () => vraagSuggesties("term"));
$("fav-merk").addEventListener("input", () => vraagSuggesties("merk"));
$("fav-annuleer").addEventListener("click", stopFavorietBewerken);
$("fav-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  sluitSuggesties();
  const { fout } = await Logica.bewaarFavoriet(favBewerk ? favBewerk.id : null, {
    term: $("fav-term").value, merk: $("fav-merk").value, suggestie: favSuggestie
  });
  if (fout) return say("fav-msg", fout);
  stopFavorietBewerken();
  renderFavorieten();
});

async function logout() {
  await Data.logUit();
  Data.stopVolgen();
  currentList = null;
  mustSetPassword = false;
  mijnNaam = null;
  naamOpen = false;
  profielOpen = false;
  voorjouOpen = false;
  Logica.vergeetVoorJou();
  lijstenOpen = false;
  aankopenOpen = false;
  fotoOpen = false;
  leegStapel();
  lijsten = [];
  archief = [];
  leden = [];
  Logica.vergeetDeals();
  aankopen = null;
  namen = {};
  beheerder = false;
  Logica.vergeetKoppelingen();
  aankoopprofiel = null;
  profielLijst = "";
  profielVraag++;
  Logica.vergeetFavorieten();
  verbergOngedaan();
  show("login");
}
$("logout").addEventListener("click", logout);

// ---------- Overzicht van lijsten ----------
// Haalt al je lijsten op; geeft de fout terug als het misgaat
async function loadLijsten() {
  const { data, error } = await Data.lijstenVanGebruiker(userId);
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
  } else {
    // Iedereen behalve de maker kan de lijst verlaten; de database controleert dat ook
    const verlaat = document.createElement("button");
    verlaat.type = "button";
    verlaat.className = "link lijst-weg";
    verlaat.textContent = "Lijst verlaten";
    verlaat.addEventListener("click", () => lijstVerlaten(lijst));
    li.append(verlaat);
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
  const { data, error } = await Data.archiveerLijst(lijst.id, true);
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
  const { error } = await Data.verwijderLijst(lijst.id);
  if (error) return say("setup-msg", error.message);
  lijsten = lijsten.filter((l) => l.id !== lijst.id);
  renderLijsten();
}

// Jezelf uit een lijst halen: de items en aankopen blijven bij de anderen, jouw aankoopprofiel telt de lijst niet meer mee
async function lijstVerlaten(lijst) {
  if (!confirm(`Lijst "${lijst.name}" verlaten? Je ziet de lijst niet meer en de aankopen op deze lijst tellen niet meer mee in jouw aankoopprofiel. Je kunt alleen terugkomen met een nieuwe uitnodiging.`)) return;
  say("setup-msg", "");
  // Vooraf loslaten: anders meldt realtime ons eigen verdwenen lidmaatschap als "je bent verwijderd"
  if (currentList && currentList.id === lijst.id) sluitLijst();
  const { error } = await Data.verlaatLijst(lijst.id);
  if (error) return say("setup-msg", error.message);
  lijsten = lijsten.filter((l) => l.id !== lijst.id);
  renderLijsten();
}

async function zetLijstTerug(lijst) {
  say("setup-msg", "");
  const { data, error } = await Data.archiveerLijst(lijst.id, false);
  if (error) return say("setup-msg", error.message);
  archief = archief.filter((l) => l.id !== lijst.id);
  if (!lijsten.some((l) => l.id === lijst.id)) lijsten.push(data);
  renderLijsten();
}

// De huidige lijst loslaten: geen live updates meer en niet meer onthouden als laatst geopend
function sluitLijst() {
  Data.stopVolgen();
  currentList = null;
  items = [];
  leden = [];
  Logica.vergeetDeals();
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
  voorjouOpen = false;
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
  const { error } = await Data.zetLijstProfiel(lijst.id, aan);
  if (error) {
    await loadLijsten();
    renderLijsten();
    say("setup-msg", error.message);
  }
}

// Het lijstmenu achter de lijstnaam: naar "Mijn lijsten", de deelnemers en (maker en beheerders) uitnodigen
function toonLijstMenu(open) {
  $("lijst-menu").hidden = !open;
  $("lijsten-knop").setAttribute("aria-expanded", open);
}
$("lijsten-knop").addEventListener("click", () => toonLijstMenu($("lijst-menu").hidden));
$("menu-lijsten").addEventListener("click", toonLijsten);
$("menu-leden").addEventListener("click", () => toonLedenPaneel(true));
// Een keuze, een tik ernaast of Escape sluit het menu
document.addEventListener("click", (e) => { if (!e.target.closest("#lijsten-knop")) toonLijstMenu(false); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape") toonLijstMenu(false); });

// ---------- Lijst maken / aansluiten ----------
$("create-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const { data, error } = await Data.maakLijst($("list-name").value.trim());
  if (error) return say("nieuw-msg", error.message);
  $("list-name").value = "";
  openList(data);
});

$("join-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  // Je mag de hele link plakken of alleen de code erin
  const invoer = $("join-code").value.trim();
  const code = (invoer.match(/uitnodiging=([0-9a-z]+)/i) || [null, invoer])[1];
  const { data, error } = await Data.sluitAan(code);
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
  if (gewisseld) { leegStapel(); items = []; itemOpen = null; leden = []; Logica.vergeetDeals(); aankopen = null; toonBonusPaneel(false); toonLedenPaneel(false); $("uitnodig-blok").hidden = true; say("leden-msg", ""); verbergOngedaan(); say("status", ""); render(); }
  $("list-title").textContent = list.name;
  show("list");
  await loadItems();
  subscribe();
}

// Namen van jezelf en je lijstgenoten ophalen (de database geeft alleen die profielen terug)
async function loadNamen() {
  const { data, error } = await Data.namen();
  if (error) return;
  namen = Object.fromEntries(data.map((p) => [p.user_id, p.display_name]));
  render();
}

// Deelnemers van de huidige lijst ophalen
async function loadLeden() {
  const lijstId = currentList.id;
  const { data, error } = await Data.leden(lijstId);
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

  const rol = lid.user_id === currentList.created_by ? "maker" : lid.is_manager ? "beheerder" : "";
  if (rol) {
    const klein = document.createElement("small");
    klein.textContent = rol;
    li.append(klein);
  }
  // Beheerder maken en verwijderen kan alleen de maker; de database controleert dat ook
  if (currentList.created_by === userId && lid.user_id !== userId) {
    const beheer = document.createElement("button");
    beheer.type = "button";
    beheer.className = "link";
    beheer.textContent = lid.is_manager ? "Geen beheerder meer" : "Beheerder maken";
    beheer.addEventListener("click", () => zetBeheerder(lid, !lid.is_manager));
    const weg = document.createElement("button");
    weg.type = "button";
    weg.className = "link";
    weg.textContent = "Verwijderen";
    weg.addEventListener("click", () => verwijderLid(lid));
    li.append(beheer, weg);
  }
  return li;
}

// Uitnodigen mag de maker, en wie de maker beheerder heeft gemaakt
function magUitnodigen() {
  return !!currentList && (currentList.created_by === userId || leden.some((l) => l.user_id === userId && l.is_manager));
}

function renderLeden() {
  if (!currentList) return;
  // Bovenaan de lijst: een rondje met de eerste letter per deelnemer (hooguit drie, daarna "+2")
  const rondjes = leden.slice(0, 3).map((lid) => {
    const rondje = document.createElement("span");
    rondje.textContent = initiaal(namen[lid.user_id]);
    return rondje;
  });
  if (leden.length > 3) {
    const meer = document.createElement("span");
    meer.textContent = "+" + (leden.length - 3);
    rondjes.push(meer);
  }
  $("leden-knop").replaceChildren(...rondjes);
  $("uitnodig-knop").hidden = !magUitnodigen();
  $("leden").replaceChildren(...leden.map(lidRij));
}

// Paneel met de deelnemers en de code om te delen, onder de kop van de lijst
function toonLedenPaneel(open) {
  $("leden-paneel").hidden = !open;
  $("leden-knop").setAttribute("aria-expanded", open);
}
$("leden-knop").addEventListener("click", () => toonLedenPaneel($("leden-paneel").hidden));

// ---------- Uitnodigen ----------
// "Iemand uitnodigen" in het lijstmenu maakt een link voor één persoon (7 dagen geldig) en zet hem in het paneel;
// "Delen" opent het deelmenu van de telefoon, of kopieert de link als dat er niet is.
$("uitnodig-delen").textContent = navigator.share ? "Delen" : "Kopiëren";
$("uitnodig-knop").addEventListener("click", async () => {
  const lijstId = currentList.id;
  toonLedenPaneel(true);
  $("uitnodig-blok").hidden = true;
  say("leden-msg", "Link maken...");
  const { data, error } = await Data.maakUitnodiging(lijstId);
  if (!currentList || currentList.id !== lijstId) return;
  if (error) return say("leden-msg", error.message);
  say("leden-msg", "");
  $("uitnodig-link").value = `${location.origin}${location.pathname}?uitnodiging=${data}`;
  $("uitnodig-blok").hidden = false;
});
$("uitnodig-delen").addEventListener("click", async () => {
  const url = $("uitnodig-link").value;
  if (navigator.share) {
    // Afbreken van het deelmenu is geen fout
    try { await navigator.share({ title: "BonusBuddy", text: `Doe mee met de lijst "${currentList.name}" in BonusBuddy`, url }); } catch {}
    return;
  }
  try {
    await navigator.clipboard.writeText(url);
    say("leden-msg", "Link gekopieerd.");
  } catch {
    $("uitnodig-link").select();
    say("leden-msg", "Kopiëren lukte niet. Selecteer de link en kopieer hem zelf.");
  }
});

async function zetBeheerder(lid, aan) {
  const lijstId = currentList.id;
  lid.is_manager = aan; // direct tonen, daarna opslaan
  say("leden-msg", "");
  renderLeden();
  const { error } = await Data.zetBeheerder(lijstId, lid.user_id, aan);
  if (!currentList || currentList.id !== lijstId) return;
  if (error) { say("leden-msg", error.message); loadLeden(); }
}

async function verwijderLid(lid) {
  const naam = namen[lid.user_id] || "Deze deelnemer";
  if (!confirm(`${naam} uit de lijst verwijderen?`)) return;
  const lijstId = currentList.id;
  say("leden-msg", "");
  const { error } = await Data.verwijderLid(lijstId, lid.user_id);
  if (!currentList || currentList.id !== lijstId) return;
  if (error) { say("leden-msg", error.message); return loadLeden(); }
  leden = leden.filter((m) => m.user_id !== lid.user_id);
  renderLeden();
}

// Heeft de maker de open lijst intussen gearchiveerd? (realtime mist dat als de telefoon in standby stond)
async function controleerArchief() {
  const lijstId = currentList.id;
  const { data } = await Data.lijstGearchiveerdOp(lijstId);
  if (!currentList || currentList.id !== lijstId) return;
  if (data && data.archived_at) verlaatLijst(ARCHIEF_MELDING);
}

async function loadItems() {
  loadNamen();
  loadLeden();
  controleerArchief();
  const lijstId = currentList.id;
  // Eerst: een gekozen aanbieding die is verlopen gaat van het item af
  await Logica.zetVerlopenKeuzesTerug(lijstId);
  if (!currentList || currentList.id !== lijstId) return;
  const { data, error } = await Data.items(lijstId);
  // Intussen van lijst gewisseld (of uitgelogd)? Dan dit antwoord negeren.
  if (!currentList || currentList.id !== lijstId) return;
  if (error) return say("status", error.message);
  items = data;
  render();
  loadDeals();
}

// Aanbiedingen bij de items van deze lijst ophalen en de labels bijwerken
async function loadDeals() {
  if (!currentList) return;
  const lijstId = currentList.id;
  const gelukt = await Logica.laadDeals(lijstId);
  if (!gelukt || !currentList || currentList.id !== lijstId) return;
  render();
  if (!$("bonus-paneel").hidden) loadBonusDetails();
}

// Het paneel onder de groene chip: wat er precies in de aanbieding is bij de items op de lijst
function toonBonusPaneel(open) {
  $("bonus-paneel").hidden = !open;
  $("bonus-balk").setAttribute("aria-expanded", open);
  if (!open) return;
  say("bonus-msg", Logica.dealDetails() ? "" : "Bezig...");
  renderBonusDetails();
  loadBonusDetails();
}
$("bonus-balk").addEventListener("click", () => toonBonusPaneel($("bonus-paneel").hidden));

async function loadBonusDetails() {
  if (!currentList) return;
  const antwoord = await Logica.laadDealDetails(currentList.id);
  if (!antwoord) return;
  say("bonus-msg", antwoord.fout || "");
  renderBonusDetails();
}

// Een weggeklikte aanbieding in het blok onderaan het paneel: wat, voor welk item, door wie, en terughalen
function wegRij(detail) {
  const item = items.find((i) => i.id === detail.item_id);
  const li = kpEl("li", "bonus-rij");
  const kop = kpEl("div", "bonus-kop");
  const tekst = kpEl("span", "bonus-tekst");
  const wie = namen[detail.weggeklikt_door];
  const sub = [(detail.korting || "").toLowerCase(), item && "voor " + item.name, wie ? "weggeklikt door " + wie : "weggeklikt"].filter(Boolean).join(" · ");
  tekst.append(kpEl("span", "item-naam", detail.titel), kpEl("span", "item-sub", sub));
  kop.append(tekst, keuzeKnop("Terughalen", "link", () => haalTerug(detail)));
  li.append(kop);
  return li;
}

// Wegklikken en terughalen gelden voor de hele lijst; de labels en het paneel daarna opnieuw ophalen
async function klikWeg(detail) {
  say("bonus-msg", "");
  const antwoord = await Logica.klikWeg(detail.item_id, detail.id);
  if (antwoord.fout) return say("bonus-msg", antwoord.fout);
  loadDeals();
}

async function haalTerug(detail) {
  say("bonus-msg", "");
  const antwoord = await Logica.haalTerug(detail.item_id, detail.id);
  if (antwoord.fout) return say("bonus-msg", antwoord.fout);
  loadDeals();
}

// Eén aanbieding bij één item, als rij: de titel met rechts de korting, eronder voor welk item en tot wanneer.
// Een tik op de rij klapt de artikelen uit om te kiezen; bij een gekozen aanbieding staat de keuze eronder.
function bonusDetailRij(detail) {
  const item = items.find((i) => i.id === detail.item_id);
  const regel = Logica.paneelRegel(detail, item);
  const open = Logica.keuzeOpen();
  const uit = !!open && !!item && open.itemId === item.id && open.aanbiedingId === detail.id;
  const kiesbaar = !!item && !regel.gekozen;
  const li = kpEl("li", "bonus-rij");
  const kop = kpEl(kiesbaar ? "button" : "div", "bonus-kop");
  if (kiesbaar) {
    kop.type = "button";
    kop.setAttribute("aria-expanded", uit);
    kop.addEventListener("click", () => {
      if (!uit) return openKeuze(detail);
      Logica.sluitKeuze();
      renderBonusDetails();
    });
  }
  const tekst = kpEl("span", "bonus-tekst");
  const meta = [regel.voor && "voor " + regel.voor, regel.winkel, "t/m " + totDag(detail.geldig_tot)].filter(Boolean).join(" · ");
  tekst.append(kpEl("span", "item-naam", detail.titel), kpEl("span", "item-sub", meta));
  kop.append(tekst, kpEl("span", "bonus-label", regel.label));
  li.append(kop);
  if (regel.gekozen) {
    const keuze = kpEl("div", "bonus-gekozen");
    keuze.append(kpEl("span", "", "✓ " + regel.gekozen), keuzeKnop("Wissen", "link", () => wisKeuze(item)));
    li.append(keuze);
  }
  if (uit) li.append(keuzeBlok(detail, item));
  return li;
}

// Onder een uitgeklapte aanbieding: de artikelen om aan te vinken, en de knoppen. Een item dat vanuit Voor jou
// op de lijst staat ís de aanbieding al: wel kiezen, niet wegklikken.
function keuzeBlok(detail, item) {
  const blok = document.createElement("div");
  blok.className = "keuze";
  const open = Logica.keuzeOpen();
  if (!open.opties) {
    blok.append(kpEl("p", "item-sub", "Bezig..."));
    return blok;
  }
  const zichtbaar = Logica.keuzeZichtbaar();
  const lijst = document.createElement("div");
  lijst.className = "keuze-lijst";
  zichtbaar.forEach((optie) => {
    const rij = document.createElement("div");
    rij.className = "keuze-rij";
    const label = document.createElement("label");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = open.aan.has(optie.artikel_id);
    // Opnieuw tekenen: het aantal staat alleen bij een aangevinkt artikel
    box.addEventListener("change", () => { Logica.zetKeuzeArtikel(optie.artikel_id, box.checked); renderBonusDetails(); });
    const titel = document.createElement("span");
    titel.textContent = optie.titel;
    if (optie.zelfde) titel.className = "zelfde-variant";
    label.append(box, titel);
    rij.append(label);
    if (box.checked) rij.append(keuzeAantal(optie));
    lijst.append(rij);
  });
  blok.append(lijst);
  const meer = open.opties.length - zichtbaar.length;
  if (meer > 0) {
    blok.append(keuzeKnop(`+ ${meer} ${meer === 1 ? "ander artikel" : "andere artikelen"}`, "link", () => { Logica.toonAlleKeuzes(); renderBonusDetails(); }));
  }
  blok.append(kpEl("p", "item-sub", "Niets aangevinkt = hele aanbieding"));
  const aangevinkt = Logica.keuzeAangevinkt();
  const acties = document.createElement("div");
  acties.className = "keuze-acties";
  acties.append(
    keuzeKnop(aangevinkt ? `Zet op de lijst (${aangevinkt})` : "Zet op de lijst", "", bevestigKeuze),
    keuzeKnop("Annuleren", "link", () => { Logica.sluitKeuze(); renderBonusDetails(); }));
  if (Logica.kanWegklikken(detail, item)) acties.append(keuzeKnop("Niet deze week", "link keuze-weg", () => klikWeg(detail)));
  blok.append(acties);
  return blok;
}

// Het aantal bij een aangevinkt artikel: min, het getal, plus
function keuzeAantal(optie) {
  const aantal = Logica.keuzeAantal(optie.artikel_id);
  const blok = document.createElement("div");
  blok.className = "keuze-aantal";
  const stap = (teken, naam, verschil) => {
    const knop = keuzeKnop(teken, "wit", () => { Logica.zetKeuzeAantal(optie.artikel_id, aantal + verschil); renderBonusDetails(); });
    knop.setAttribute("aria-label", `${naam} ${optie.titel}`);
    return knop;
  };
  const min = stap("−", "Minder", -1);
  min.disabled = aantal <= 1;
  const getal = kpEl("span", "", aantal + "×");
  getal.setAttribute("aria-live", "polite");
  blok.append(min, getal, stap("+", "Meer", 1));
  return blok;
}

function keuzeKnop(tekst, soort, actie) {
  const knop = document.createElement("button");
  knop.type = "button";
  if (soort) knop.className = soort;
  knop.textContent = tekst;
  knop.addEventListener("click", actie);
  return knop;
}

async function openKeuze(detail) {
  say("bonus-msg", "");
  const wacht = Logica.openKeuze(detail.item_id, detail.id);
  renderBonusDetails();
  const antwoord = await wacht;
  if (!antwoord) return;
  say("bonus-msg", antwoord.fout || "");
  renderBonusDetails();
}

// Na kiezen of wissen: het item is veranderd en er kunnen items bij of af zijn (één per gekozen artikel),
// dus de lijst en de labels opnieuw ophalen
function neemItemOver(antwoord) {
  if (antwoord.fout) return say("bonus-msg", antwoord.fout);
  const nieuw = antwoord.item;
  if (!currentList || !nieuw || nieuw.list_id !== currentList.id) return;
  items = items.map((i) => (i.id === nieuw.id ? nieuw : i));
  render();
  loadItems();
}

async function bevestigKeuze() {
  say("bonus-msg", "");
  const antwoord = await Logica.bevestigKeuze();
  // Gekozen: het paneel klapt dicht, zodat je de lijst met de keuze erop ziet
  if (!antwoord.fout) toonBonusPaneel(false);
  neemItemOver(antwoord);
}

async function wisKeuze(item) {
  say("bonus-msg", "");
  neemItemOver(await Logica.wisKeuze(item.id));
}

function renderBonusDetails() {
  if ($("bonus-paneel").hidden) return;
  // Alleen bij items die nog op de lijst staan: een gekocht of verwijderd item valt meteen weg
  const details = (Logica.dealDetails() || []).filter((d) => items.some((i) => i.id === d.item_id));
  $("bonus-details").replaceChildren(...details.filter((d) => !d.weggeklikt_door).map(bonusDetailRij));
  // Onderaan, ingeklapt: wat is weggeklikt, om terug te halen
  const weg = details.filter((d) => d.weggeklikt_door);
  $("bonus-weg").hidden = weg.length === 0;
  $("bonus-weg-kop").textContent = `Weggeklikt (${weg.length})`;
  $("bonus-weg-lijst").replaceChildren(...weg.map(wegRij));
}

// Groene chip in de kop: hoeveel producten op de lijst in de aanbieding zijn, en waar. Tikken klapt de aanbiedingen uit.
function renderBonus() {
  const metDeal = items.filter((i) => Logica.dealsVan(i.id));
  // Is alles weggeklikt, dan blijft de chip staan: in het paneel haal je het terug
  const weg = Logica.aantalWeggeklikt(items);
  $("bonus-balk").hidden = metDeal.length === 0 && weg === 0;
  if (metDeal.length === 0 && weg === 0) return toonBonusPaneel(false);
  renderBonusDetails();
  if (metDeal.length === 0) return say("bonus-aantal", weg === 1 ? "1 aanbieding weggeklikt" : `${weg} aanbiedingen weggeklikt`);
  const winkels = Logica.dealWinkels(metDeal.flatMap((i) => Logica.dealsVan(i.id))).join(" en ");
  say("bonus-aantal", `${metDeal.length} in de bonus bij ${winkels}`);
}

function subscribe() {
  Data.volgLijst(currentList.id, {
    item: (p) => {
      if (p.eventType === "INSERT") {
        if (!items.some((i) => i.id === p.new.id)) items.push(p.new);
        loadDeals();
      } else if (p.eventType === "UPDATE") {
        const oud = items.find((i) => i.id === p.new.id);
        items = items.map((i) => (i.id === p.new.id ? p.new : i));
        // De AI heeft de term een type gegeven, of de naam is gewijzigd: het label kan nu anders zijn
        if (oud && (oud.type_id !== p.new.type_id || oud.name !== p.new.name)) loadDeals();
      } else if (p.eventType === "DELETE") {
        // Dit bericht komt van alle lijsten: alleen verder als het item op deze lijst stond
        if (!items.some((i) => i.id === p.old.id)) return;
        items = items.filter((i) => i.id !== p.old.id);
      }
      render();
    },
    lid: (p) => {
      if (!currentList) return;
      if (p.eventType === "INSERT") {
        // Iemand sluit aan: leden en de naam van de nieuwkomer ophalen
        loadLeden();
        loadNamen();
      } else if (p.eventType === "UPDATE") {
        // De maker heeft iemand beheerder gemaakt, of juist niet meer
        loadLeden();
      } else if (p.eventType === "DELETE") {
        // Bij verwijderen zelf controleren om welke lijst het gaat
        if (p.old.list_id !== currentList.id) return;
        if (p.old.user_id === userId) return verlaatLijst();
        leden = leden.filter((m) => m.user_id !== p.old.user_id);
        renderLeden();
      }
    },
    // Iemand heeft een aanbieding weggeklikt of teruggehaald: de labels en het paneel kloppen niet meer
    weggeklikt: () => { if (currentList) loadDeals(); },
    lijst: (p) => {
      // De maker heeft de lijst gearchiveerd terwijl jij hem open had
      if (currentList && p.new.id === currentList.id && p.new.archived_at) verlaatLijst(ARCHIEF_MELDING);
    },
    aankoop: (p) => {
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
        // Bij verwijderen stuurt de database alleen de id mee, van alle lijsten: alleen verder als de aankoop hier stond
        if (!aankopen.some((a) => a.id === p.old.id)) return;
        aankopen = aankopen.filter((a) => a.id !== p.old.id);
      }
      renderAankopen();
    }
  });
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

  // Het rondje doet hetzelfde als naar rechts vegen
  const koopKnop = document.createElement("button");
  koopKnop.className = "koop";
  koopKnop.setAttribute("aria-label", "Gekocht");
  koopKnop.addEventListener("click", () => koop(item));

  // Het aantal vóór de titel, met eronder één metaregel: waar het voor was en tot wanneer de aanbieding loopt
  const regel = Logica.itemRegel(item);
  const tekst = document.createElement("div");
  tekst.className = "item-tekst";
  if (regel.aantal) {
    const aantal = document.createElement("span");
    aantal.className = "item-aantal";
    aantal.textContent = regel.aantal;
    tekst.append(aantal);
  }
  const inhoud = document.createElement("div");
  inhoud.className = "item-inhoud";
  const naam = document.createElement("span");
  naam.className = "item-naam";
  naam.textContent = item.name;
  inhoud.append(naam);
  const meta = [
    regel.voor && "voor " + regel.voor,
    regel.geldigTot && "t/m " + totDag(regel.geldigTot),
    regel.nodig && regel.nodig + " nodig voor de korting"
  ].filter(Boolean).join(" · ");
  if (meta) {
    const sub = document.createElement("span");
    sub.className = "item-sub";
    sub.textContent = meta;
    inhoud.append(sub);
  }
  // Een tik op de tekst klapt uit wie het item toevoegde en wanneer
  const wie = namen[item.added_by];
  if (itemOpen === item.id) {
    const door = document.createElement("span");
    door.className = "item-sub";
    door.textContent = ["toegevoegd" + (wie ? " door " + wie : ""), datumKort(item.created_at)].join(" · ");
    door.title = "Toegevoegd op " + datumTijd(item.created_at);
    inhoud.append(door);
  }
  tekst.append(inhoud);
  tekst.addEventListener("click", () => {
    // De klik die op het loslaten na vegen volgt telt niet
    if (Date.now() - laatsteVeeg < 400) return;
    itemOpen = itemOpen === item.id ? null : item.id;
    render();
  });
  voor.append(koopKnop, tekst);

  // Rechts het bonuslabel, met eronder de initiaal van wie het toevoegde als dat een ander was
  const ander = item.added_by && item.added_by !== userId;
  if (regel.label || ander) {
    const rechts = document.createElement("div");
    rechts.className = "item-rechts";
    if (regel.label) {
      const label = document.createElement("span");
      label.className = "bonus-label";
      label.textContent = regel.label;
      rechts.append(label);
    }
    if (ander) {
      const door = document.createElement("span");
      door.className = "item-door";
      door.textContent = initiaal(wie);
      door.title = "Toegevoegd door " + (wie || "iemand zonder naam");
      rechts.append(door);
    }
    voor.append(rechts);
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
    laatsteVeeg = Date.now();
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

// Korte datum voor in een rij: "vandaag", "gisteren", de weekdag ("ma") binnen een week,
// daarna "3 okt", met het jaar erbij als dat een ander jaar is
function datumKort(iso) {
  const d = new Date(iso);
  const nu = new Date();
  const middernacht = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate());
  const dagen = Math.round((middernacht(nu) - middernacht(d)) / 864e5);
  if (dagen <= 0) return "vandaag";
  if (dagen === 1) return "gisteren";
  if (dagen < 7) return d.toLocaleDateString("nl-NL", { weekday: "short" });
  const opmaak = { day: "numeric", month: "short" };
  if (d.getFullYear() !== nu.getFullYear()) opmaak.year = "numeric";
  // Sommige browsers schrijven de korte maand met een punt ("okt.")
  return d.toLocaleDateString("nl-NL", opmaak).replace(".", "");
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

function render() {
  // Niet opnieuw opbouwen terwijl er een rij wordt versleept: die zou onder je vinger verdwijnen
  if (slepen > 0) { renderWacht = true; return; }
  renderWacht = false;
  $("items").replaceChildren(...items.map(itemRow));
  renderBonus();
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
  const { data, error } = await Data.voegItemToe({ list_id: currentList.id, name, quantity });
  if (error) return say("status", error.message);
  if (!items.some((i) => i.id === data.id)) items.push(data);
  render();
  loadDeals();
});

// Gekocht: het item gaat van de lijst en de database bewaart het als aankoop
async function koop(item) {
  items = items.filter((i) => i.id !== item.id); // direct tonen, daarna opslaan
  render();
  const { data, error } = await Data.koopItem(item.id);
  if (!currentList || currentList.id !== item.list_id) return;
  if (error) { say("status", error.message); return loadItems(); }
  // Geen aankoop: de ander was net eerder, dus er valt niets terug te draaien
  if (!data) return;
  toonOngedaan(`"${item.name}" gekocht`, item, data);
}

async function remove(item) {
  items = items.filter((i) => i.id !== item.id);
  render();
  const { error } = await Data.verwijderItem(item.id);
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
    ? await Data.maakAankoopOngedaan(aankoopId)
    : await Data.zetItemTerug(item);
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
  say("aankopen-msg", "");
  renderAankopen();
  show("aankopen");
  loadAankopen();
}

async function loadAankopen() {
  if (!currentList) return;
  const lijstId = currentList.id;
  const { data, error } = await Data.aankopen(lijstId);
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
  const { error } = await Data.verwijderAankoop(aankoop.id);
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
    const { data, error } = await Data.fotoNaarItems({ afbeelding, type: "image/jpeg" });
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
  const { data, error } = await Data.voegItemsToe(rijen);
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
    const { data, error } = await Data.leesBon(await leesBonBestand(bon.bestand));
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
      aan: true, koppel: null, koppelAan: true, item: null, itemAan: null
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

// Vraagt de database of deze bon al eens is toegevoegd, welke regels lijken op een aankoop
// van dezelfde dag en welke op iets dat nog op de lijst staat. Opnieuw na het wijzigen van supermarkt, datum, totaal of een productnaam,
// en na het opslaan van een andere bon uit de stapel. Geeft false als de controle is ingehaald of afgebroken.
async function controleerBon(bon = bonHuidig) {
  if (!bon || bon.status !== "klaar" || !currentList) return false;
  const lijstId = currentList.id;
  const vraag = ++bon.controle;
  const winkel = bon.supermarkt.trim();
  let dubbel = false, koppels = [], opLijst = [], fout = false;
  if (bon.datum) {
    const namen = bon.regels.map((r) => r.naam);
    const [bestaat, gevonden, lijst] = await Promise.all([
      winkel
        ? Data.bonBestaat(lijstId, winkel, bon.datum, leesBedrag(bon.totaal))
        : { data: false },
      Data.zoekAankopenBijBonregels(lijstId, bon.datum, namen),
      Data.zoekItemsBijBonregels(lijstId, bon.datum, namen)
    ]);
    if (vraag !== bon.controle || bon.status !== "klaar" || !bonStapel.includes(bon) || !currentList || currentList.id !== lijstId) return false;
    fout = Boolean(bestaat.error || gevonden.error || lijst.error);
    dubbel = !bestaat.error && bestaat.data === true;
    koppels = gevonden.error ? [] : gevonden.data;
    opLijst = lijst.error ? [] : lijst.data;
  }
  bon.dubbel = dubbel;
  bon.controleFout = fout;
  bon.gecontroleerd = true;
  if (bonHuidig === bon) $("bon-dubbel").hidden = !dubbel;
  const perRegel = {};
  koppels.forEach((k) => { perRegel[k.regel - 1] = { id: k.purchase_id, naam: k.name, heeftBon: k.has_receipt }; });
  // Alleen het regeltje over de koppeling bijwerken: de rij opnieuw opbouwen zou je uit een invoerveld gooien
  const itemPerRegel = {};
  opLijst.forEach((k) => { itemPerRegel[k.regel - 1] = { id: k.item_id, naam: k.name, zeker: k.zeker }; });
  bon.regels.forEach((regel, i) => {
    regel.koppel = perRegel[i] || null;
    const item = itemPerRegel[i] || null;
    // Een ander item dan eerst: dan geldt je eerdere keuze niet meer
    if (!item || !regel.item || item.id !== regel.item.id) regel.itemAan = null;
    regel.item = item;
    toonKoppel(regel);
  });
  renderStapel();
  return true;
}

// Het item dat bij deze bonregel nog op de lijst staat, als de regel niet al bij een aankoop van die dag hoort
function lijstItem(regel) {
  return regel.koppel ? null : regel.item;
}

// Gaat dat item bij het opslaan van de lijst? Hetzelfde product wel, een gelijkende naam alleen als je dat aanvinkt.
function vanLijst(regel) {
  const item = lijstItem(regel);
  return Boolean(item) && (regel.itemAan === null ? item.zeker : regel.itemAan);
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
  // Hetzelfde product gaat vanzelf van de lijst; bij een gelijkende naam moet je eerst zelf kiezen
  const lijktOp = aan.filter((r) => lijstItem(r) && !lijstItem(r).zeker && r.itemAan === null).length;
  if (lijktOp) twijfels.push(lijktOp === 1 ? "1 regel lijkt op iets dat nog op de lijst staat." : `${lijktOp} regels lijken op iets dat nog op de lijst staat.`);
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
// Wat daarbij nog op de lijst staat gaat in dezelfde stap van de lijst. Geeft de foutmelding terug, of "" als het is gelukt.
async function bewaarBon(bon) {
  const fout = bonFout(bon);
  if (fout) return fout;
  const regels = bon.regels.filter((r) => r.aan && r.naam.trim()).map((r) => ({
    name: r.naam.trim(), receipt_name: r.bonNaam, quantity: r.aantal.trim() || null,
    price: leesBedrag(r.prijs), discount: r.korting,
    purchase_id: r.koppel && r.koppelAan ? r.koppel.id : null,
    item_id: vanLijst(r) ? r.item.id : null
  }));
  const { data, error } = await Data.bewaarBon(currentList.id, bon.supermarkt.trim(), bon.datum, leesBedrag(bon.totaal), regels);
  if (error) return error.message;
  bon.status = "opgeslagen";
  bon.uitkomst = data || {};
  // De lijst zelf loopt mee via realtime; dit vangt een gemiste melding op
  if (bon.uitkomst.van_lijst) loadItems();
  return "";
}

// Samenvatting van wat er van de opgeslagen bonnen bij de aankopen is gekomen
function uitkomstTekst(bonnen) {
  const tel = (veld) => bonnen.reduce((s, b) => s + (b.uitkomst[veld] || 0), 0);
  const delen = [`${tel("toegevoegd")} toegevoegd`];
  if (tel("van_lijst")) delen.push(`${tel("van_lijst")} van de lijst gehaald`);
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

// Regeltje onder een bonregel als het product die dag al bij de aankopen staat, of nog op de lijst
function toonKoppel(regel) {
  if (!regel.koppelVak) return;
  const item = lijstItem(regel);
  regel.koppelVak.replaceChildren();
  regel.koppelVak.hidden = !regel.koppel && !item;
  if (!regel.koppel && !item) return;
  const box = document.createElement("input");
  box.type = "checkbox";
  const tekst = document.createElement("span");
  if (regel.koppel) {
    box.checked = regel.koppelAan;
    box.addEventListener("change", () => { regel.koppelAan = box.checked; });
    tekst.textContent = regel.koppel.heeftBon
      ? `Staat die dag al op een andere bon als "${regel.koppel.naam}": telt niet opnieuw`
      : `Die dag al gekocht als "${regel.koppel.naam}": telt één keer, de prijs komt erbij`;
  } else {
    box.checked = vanLijst(regel);
    box.addEventListener("change", () => { regel.itemAan = box.checked; });
    tekst.textContent = item.zeker
      ? `Staat op de lijst als "${item.naam}": gaat van de lijst`
      : `Lijkt op "${item.naam}" op de lijst: vink aan om dat van de lijst te halen`;
  }
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
  const { data, error } = await Data.bonnen(lijstId);
  if (!currentList || currentList.id !== lijstId) return;
  if (error) return say("bonnen-msg", error.message);
  bonnen = data;
  renderBonnen();
}

// De aankopen die bij een bon horen; pas ophalen als je de bon openklapt
async function loadBonInhoud(bon) {
  const { data, error } = await Data.bonInhoud(bon.id);
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
  const { error } = await Data.verwijderBon(bon.id);
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

// ---------- Koppelingen ----------
// Alleen voor de beheerder; state en acties staan in logica.js. Het scherm hoort bij het profiel:
// profielOpen blijft aan, zodat route() het niet wegklapt als de app terugkomt op de voorgrond.
function toonKoppelingen() {
  Logica.vergeetKoppelingen();
  $("producten-zoek").value = "";
  say("producten-msg", "Bezig...");
  say("koppel-msg", "");
  renderKoppelingen();
  show("producten");
  loadKoppelingen();
}

async function loadKoppelingen() {
  const uit = await Logica.laadKoppelingen();
  if (!profielOpen) return;
  say("producten-msg", uit.fout || "");
  renderKoppelingen();
}

// De namen en artikelen van een type; pas ophalen als je het type openklapt
async function loadTypeDetails(typeId) {
  const uit = await Logica.laadTypeDetails(typeId);
  if (!profielOpen) return;
  if (uit.fout) return say("producten-msg", uit.fout);
  renderKoppelingen();
}

function kpEl(soort, klasse, tekst) {
  const el = document.createElement(soort);
  if (klasse) el.className = klasse;
  if (tekst != null) el.textContent = tekst;
  return el;
}

// Een tekstknop in een rij. Tijdens de actie staan alle knoppen van die rij uit.
function kpKnop(tekst, actie) {
  const knop = kpEl("button", "link", tekst);
  knop.type = "button";
  knop.addEventListener("click", () => actie(knop));
  return knop;
}

// Voert een actie uit Logica uit, toont de fout of de melding en tekent het scherm opnieuw
async function kpDoe(knop, actie, melding) {
  const knoppen = knop ? [...knop.parentElement.querySelectorAll("button")] : [];
  knoppen.forEach((k) => { k.disabled = true; });
  say("koppel-msg", "Bezig...");
  const uit = await actie();
  if (!profielOpen) return;
  say("koppel-msg", uit.fout || (typeof melding === "function" ? melding(uit) : melding) || "");
  if (uit.fout) knoppen.forEach((k) => { k.disabled = false; });
  renderKoppelingen();
  // Het opengeklapte type heeft na een wijziging andere namen en artikelen
  if (!uit.fout && Logica.typeOpen()) loadTypeDetails(Logica.typeOpen());
}

// De keuzelijst "Ander type": een zoekveld met daaronder de types die passen. Eén tegelijk open.
// `zonder` is het type dat de rij al heeft; `kies` krijgt het gekozen type.
function kpKiezer(anker, zonder, kies) {
  const open = anker.querySelector(".type-kiezer");
  document.querySelectorAll(".type-kiezer").forEach((k) => k.remove());
  if (open) return;
  const blok = kpEl("div", "type-kiezer");
  const veld = kpEl("input");
  veld.type = "text";
  veld.placeholder = "Zoek een type";
  veld.autocomplete = "off";
  veld.setAttribute("aria-label", "Zoek een type");
  const lijst = kpEl("div", "type-kiezer-lijst");
  const toon = () => {
    const types = Logica.zoekTypes(veld.value, zonder);
    lijst.replaceChildren(...types.map((t) => {
      const knop = kpEl("button", "link");
      knop.type = "button";
      knop.append(kpEl("span", "", t.naam), kpEl("small", "", t.hoofdgroep));
      knop.addEventListener("click", () => kies(t, knop));
      return knop;
    }));
    if (veld.value.trim() && types.length === 0) lijst.append(kpEl("p", "bonnen-info", "Geen type gevonden."));
  };
  veld.addEventListener("input", toon);
  blok.append(veld, lijst);
  anker.append(blok);
  veld.focus();
}

function kpArtikelInfo(artikel) {
  return [artikel.merk, artikel.inhoud, artikel.categorie].filter(Boolean).join(" · ");
}

function kpOordeel(rij) {
  return (rij.zekerheid ? `Zekerheid ${Logica.zekerheidNaam(rij.zekerheid)}` : "") + (rij.zekerheid && rij.reden ? " · " : "") + (rij.reden || "");
}

// Eén term die de AI heeft beoordeeld: wat er getypt is, waar het voor staat en waarom
function kpTermRij(term, metKlopt) {
  const rij = kpEl("div", "voorstel");
  const staatVoor = term.type ? term.type + (term.merk ? ` van ${term.merk}` : "") : "geen type";
  rij.append(kpEl("p", "", `${term.term} → ${staatVoor}`));
  const info = [kpOordeel(term), term.op ? datumKort(term.op) : ""].filter(Boolean).join(" · ");
  if (info) rij.append(kpEl("p", "bonnen-info", info));
  const acties = kpEl("div", "voorstel-acties");
  if (metKlopt) acties.append(kpKnop("Klopt", (k) => kpDoe(k, () => Logica.klopt([term], []))));
  acties.append(kpKnop("Ander type", () => kpKiezer(rij, term.type_id, (t, k) =>
    kpDoe(k, () => Logica.zetTermType(term, t.id), `"${term.term}" staat nu voor ${t.naam}.`))));
  if (term.type_id) acties.append(kpKnop("Geen type", (k) => kpDoe(k, () => Logica.zetTermType(term, null))));
  rij.append(acties);
  return rij;
}

// Eén artikel. `klopt` zet de knop "Klopt" erbij; `geenType` de knop "Geen type" (alleen als het een type heeft).
function kpArtikelRij(artikel, typeId, { klopt = false, geenType = false, oordeel = true } = {}) {
  const rij = kpEl("div", "voorstel");
  rij.append(kpEl("p", "", artikel.titel));
  if (kpArtikelInfo(artikel)) rij.append(kpEl("p", "bonnen-info", kpArtikelInfo(artikel)));
  if (oordeel && kpOordeel(artikel)) rij.append(kpEl("p", "bonnen-info", kpOordeel(artikel)));
  const acties = kpEl("div", "voorstel-acties");
  if (klopt) acties.append(kpKnop("Klopt", (k) => kpDoe(k, () => Logica.klopt([], [artikel]))));
  acties.append(kpKnop("Ander type", () => kpKiezer(rij, typeId, (t, k) =>
    kpDoe(k, () => Logica.zetArtikelType(artikel, t.id), `"${artikel.titel}" hoort nu bij ${t.naam}.`))));
  if (geenType) acties.append(kpKnop("Geen type", (k) => kpDoe(k, () => Logica.zetArtikelType(artikel, null))));
  rij.append(acties);
  return rij;
}

// De artikelen om na te kijken bij één type
function kpArtikelGroep(groep) {
  const blok = kpEl("div", "voorstel-groep");
  const kop = kpEl("div", "voorstel-kop");
  kop.append(kpEl("strong", "", groep.type));
  kop.append(kpKnop(groep.rijen.length > 1 ? `Alles klopt (${groep.rijen.length})` : "Klopt", (k) => {
    if (groep.rijen.length > 1 && !confirm(`Kloppen alle ${groep.rijen.length} artikelen bij "${groep.type}"?`)) return;
    kpDoe(k, () => Logica.klopt([], groep.rijen));
  }));
  blok.append(kop, ...groep.rijen.map((a) => kpArtikelRij(a, groep.type_id, { geenType: true })));
  return blok;
}

// Naam, hoofdgroep, afbakening en de vlag van een type: voor een nieuw type en voor een bestaand
function kpTypeFormulier(begin, knopTekst, bewaar) {
  const form = kpEl("form", "type-formulier");
  const veld = (soort, waarde, label, max) => {
    const el = kpEl(soort);
    if (soort === "input") el.type = "text";
    el.value = waarde || "";
    if (max) el.maxLength = max;
    el.setAttribute("aria-label", label);
    el.placeholder = label;
    return el;
  };
  const naam = veld("input", begin.naam, "Naam van het type", 80);
  const hoofdgroep = kpEl("select");
  hoofdgroep.setAttribute("aria-label", "Hoofdgroep");
  hoofdgroep.append(new Option("Kies een hoofdgroep", ""), ...Logica.hoofdgroepen().map((g) => new Option(g, g)));
  hoofdgroep.value = begin.hoofdgroep || "";
  const eronder = veld("textarea", begin.valtEronder, "Wat valt eronder?");
  const nietEronder = veld("textarea", begin.valtErNietOnder, "Wat valt er niet onder, en waar hoort dat wel?");
  eronder.rows = nietEronder.rows = 2;
  const label = kpEl("label", "product-telt");
  const telt = kpEl("input", "schakelaar");
  telt.type = "checkbox";
  telt.setAttribute("role", "switch");
  telt.checked = begin.teltMee !== false;
  label.append(kpEl("span", "", "Telt mee in aankoopprofiel"), telt);
  const opslaan = kpEl("button", "", knopTekst);
  opslaan.type = "submit";
  form.append(naam, hoofdgroep, eronder, nietEronder, label, opslaan);
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    bewaar({ naam: naam.value.trim(), hoofdgroep: hoofdgroep.value, valtEronder: eronder.value.trim(),
             valtErNietOnder: nietEronder.value.trim(), teltMee: telt.checked }, opslaan);
  });
  return form;
}

// Wat de AI nergens kwijt kon, bij één voorgesteld type (of zonder voorstel: geen gewone boodschap)
function kpOntbreekGroep(groep) {
  const blok = kpEl("div", "voorstel-groep");
  const kop = kpEl("div", "voorstel-kop");
  const aantal = groep.artikelen.length + groep.termen.length;
  kop.append(kpEl("strong", "", groep.voorstel ? `${groep.voorstel} (${aantal})` : `Zonder voorstel (${aantal})`));
  if (groep.voorstel) {
    kop.append(kpKnop("Type aanmaken", () => {
      const open = blok.querySelector(".type-formulier");
      if (open) return open.remove();
      kop.after(kpTypeFormulier(
        { naam: groep.voorstel, hoofdgroep: Logica.hoofdgroepVan(groep.artikelen) }, "Type aanmaken",
        (velden, knop) => kpDoe(knop, () => Logica.maakType(velden, groep.voorstel), (uit) =>
          `Het type "${uit.nieuw.naam}" is aangemaakt: ${uit.nieuw.artikelen} artikelen en ${uit.nieuw.termen} termen horen erbij.`)));
    }));
  }
  // Klopt het dat hier geen type bij hoort, dan verdwijnt de groep uit de lijst
  kop.append(kpKnop(groep.voorstel ? "Geen type nodig" : "Klopt", (k) => {
    if (aantal > 1 && !confirm(`Blijven deze ${aantal} zonder type?`)) return;
    kpDoe(k, () => Logica.klopt(groep.termen, groep.artikelen));
  }));
  blok.append(kop, ...groep.artikelen.map((a) => kpArtikelRij(a, null)), ...groep.termen.map((t) => kpTermRij(t, false)));
  return blok;
}

// Een type dat de AI zelf aanmaakte: wat het is, en nakijken, openen of verwijderen
function kpNieuwType(type) {
  const regel = kpEl("div", "voorstel");
  regel.append(kpEl("p", "", type.naam),
    kpEl("p", "bonnen-info", `${type.hoofdgroep} · ${type.artikelen} art.` + (type.valt_eronder ? ` · ${type.valt_eronder}` : "")));
  const acties = kpEl("div", "voorstel-acties");
  acties.append(
    kpKnop("Klopt", (k) => kpDoe(k, () => Logica.typeKlopt(type))),
    // Openen in de lijst onderaan: daar staan wijzigen, samenvoegen en de artikelen
    kpKnop("Bekijken", () => {
      $("producten-zoek").value = type.naam;
      Logica.openType(type.id);
      renderKoppelingen();
      if (!Logica.detailsVan(type.id)) loadTypeDetails(type.id);
      $("producten-zoek").scrollIntoView({ behavior: "smooth", block: "start" });
    }),
    kpKnop("Verwijderen", (k) => {
      if (!confirm(`"${type.naam}" verwijderen? De artikelen en namen blijven zonder type achter. Hoort het bij een ander type, voeg het dan samen via "Bekijken".`)) return;
      kpDoe(k, () => Logica.verwijderType(type), `"${type.naam}" is verwijderd.`);
    }));
  regel.append(acties);
  return regel;
}

// Eén type in de lijst onderaan. Opengeklapt: wijzigen, samenvoegen, en zijn namen en artikelen.
function kpTypeRij(type) {
  const li = document.createElement("li");
  const open = Logica.typeOpen() === type.id;
  const knop = kpEl("button", "bonnen-open");
  knop.type = "button";
  knop.setAttribute("aria-expanded", open);
  const kop = kpEl("div", "bonnen-kop");
  kop.append(kpEl("span", "", type.naam), kpEl("small", "", `${type.artikelen} art. · ${type.aankopen}×`));
  knop.append(kop, kpEl("p", "bonnen-info", type.hoofdgroep + (type.telt_mee ? "" : " · telt niet mee in het aankoopprofiel")));
  knop.addEventListener("click", () => {
    Logica.openType(open ? null : type.id);
    renderKoppelingen();
    if (!open && !Logica.detailsVan(type.id)) loadTypeDetails(type.id);
  });
  li.append(knop);
  if (!open) return li;

  const blok = kpEl("div", "bonnen-regels");
  blok.append(kpTypeFormulier(
    { naam: type.naam, hoofdgroep: type.hoofdgroep, valtEronder: type.valt_eronder, valtErNietOnder: type.valt_er_niet_onder, teltMee: type.telt_mee },
    "Opslaan", (velden, k) => kpDoe(k, () => Logica.wijzigType(type, velden), "Opgeslagen.")));

  // Samenvoegen: dit type gaat op in een ander. Dat is niet terug te draaien.
  const samen = kpEl("div", "voorstel");
  const acties = kpEl("div", "voorstel-acties");
  acties.append(kpKnop("Samenvoegen met een ander type", () => kpKiezer(samen, type.id, (doel, k) => {
    if (!confirm(`"${type.naam}" laten opgaan in "${doel.naam}"? Alle artikelen en namen verhuizen mee en "${type.naam}" blijft werken als naam van "${doel.naam}". Dit kun je niet terugdraaien.`)) return;
    kpDoe(k, () => Logica.voegTypesSamen(type, doel), `"${type.naam}" is opgegaan in "${doel.naam}".`);
  })));
  samen.append(acties);
  blok.append(samen);

  const details = Logica.detailsVan(type.id);
  if (!details) {
    blok.append(kpEl("p", "", "Bezig..."));
  } else {
    blok.append(kpEl("p", "type-tussenkop", `Namen (${details.namen.length})`));
    blok.append(...details.namen.map((n) => {
      const regel = kpEl("div", "voorstel");
      const bron = n.bron === "ai" ? "AI" : n.bron === "manual" ? "zelf gezet" : "catalogus";
      regel.append(kpEl("p", "", n.term + (n.merk ? ` (merk ${n.merk})` : "")), kpEl("p", "bonnen-info", bron + (n.nagekeken ? " · nagekeken" : "")));
      const a = kpEl("div", "voorstel-acties");
      const term = { term: n.term, sleutel: n.sleutel, merk: n.merk, type_id: type.id };
      a.append(
        kpKnop("Ander type", () => kpKiezer(regel, type.id, (t, k) => kpDoe(k, () => Logica.zetTermType(term, t.id), `"${n.term}" staat nu voor ${t.naam}.`))),
        kpKnop("Geen type", (k) => kpDoe(k, () => Logica.zetTermType(term, null))));
      regel.append(a);
      return regel;
    }));
    blok.append(kpEl("p", "type-tussenkop", `Artikelen (${details.artikelen.length})`));
    blok.append(...details.artikelen.map((a) => kpArtikelRij(a, type.id, { geenType: true, oordeel: false })));
  }
  li.append(blok);
  return li;
}

function renderKoppelingen() {
  const alles = Logica.koppelingen();
  const termen = alles ? alles.termen : [];
  const groepen = Logica.artikelGroepen();
  const ontbreekt = Logica.ontbrekend();
  const nieuw = Logica.nieuweTypes();
  const tel = (lijst, per) => lijst.reduce((n, x) => n + per(x), 0);

  $("kp-nieuw").replaceChildren(...nieuw.map(kpNieuwType));
  $("kp-nieuw-kop").textContent = `Nieuwe types (${nieuw.length})`;
  $("kp-nieuw-blok").hidden = nieuw.length === 0;
  $("kp-termen").replaceChildren(...termen.map((t) => kpTermRij(t, true)));
  $("kp-artikelen").replaceChildren(...groepen.map(kpArtikelGroep));
  $("kp-zonder").replaceChildren(...ontbreekt.map(kpOntbreekGroep));
  $("kp-termen-kop").textContent = `Termen (${termen.length})`;
  $("kp-artikelen-kop").textContent = `Artikelen om na te kijken (${tel(groepen, (g) => g.rijen.length)})`;
  $("kp-zonder-kop").textContent = `Geen type (${tel(ontbreekt, (g) => g.artikelen.length + g.termen.length)})`;
  $("kp-termen-blok").hidden = termen.length === 0;
  $("kp-artikelen-blok").hidden = groepen.length === 0;
  $("kp-zonder-blok").hidden = ontbreekt.length === 0;
  $("koppel-blokken").hidden = nieuw.length === 0 && termen.length === 0 && groepen.length === 0 && ontbreekt.length === 0;
  $("koppel-leeg").hidden = !alles || !$("koppel-blokken").hidden;

  const zoek = $("producten-zoek").value.trim();
  const types = Logica.gefilterdeTypes(zoek);
  const totaal = alles ? alles.types.length : 0;
  $("producten").replaceChildren(...types.map(kpTypeRij));
  $("producten-telling").textContent = !alles ? ""
    : types.length === 0 ? "Geen types gevonden."
    : zoek ? `${types.length} van ${totaal} types` : `${totaal} types`;
}

$("producten-knop").addEventListener("click", toonKoppelingen);
$("producten-zoek").addEventListener("input", renderKoppelingen);
$("producten-terug").addEventListener("click", toonProfiel);

// ---------- Terugvegen ----------
// Op schermen met een terugknop bovenaan (data-terug) brengt naar rechts vegen je ook terug.
// Het scherm schuift mee met je vinger; ver genoeg en loslaten is hetzelfde als op de terugknop tikken.
function maakTerugveegbaar(sectie) {
  const knop = $(sectie.dataset.terug);
  let startX = 0, startY = 0, dx = 0;
  let pointer = null;
  let bezig = false; // vinger is neer
  let vast = false;  // de beweging is herkend als naar rechts vegen

  sectie.addEventListener("pointerdown", (e) => {
    // Alleen aanraken: met de muis wil je tekst kunnen selecteren
    if (bezig || e.pointerType === "mouse" || e.target.closest("input, select, textarea")) return;
    pointer = e.pointerId;
    startX = e.clientX;
    startY = e.clientY;
    dx = 0;
    bezig = true;
  });

  sectie.addEventListener("pointermove", (e) => {
    if (!bezig || e.pointerId !== pointer) return;
    const x = e.clientX - startX;
    const y = e.clientY - startY;
    if (!vast) {
      // Omhoog, omlaag of naar links: geen terugveeg
      if ((Math.abs(y) > 10 && Math.abs(y) > Math.abs(x)) || x < -10) { bezig = false; return; }
      if (x < 10) return;
      vast = true;
      try { sectie.setPointerCapture(pointer); } catch {}
      sectie.style.transition = "none";
    }
    dx = Math.max(0, x);
    sectie.style.transform = `translateX(${dx}px)`;
  });

  function einde(e, afgebroken) {
    if (!bezig || e.pointerId !== pointer) return;
    bezig = false;
    if (!vast) return;
    vast = false;
    sectie.style.transition = "";
    sectie.style.transform = "";
    if (!afgebroken && dx > Math.min(120, sectie.offsetWidth * 0.3)) knop.click();
    // De tik die de browser na het loslaten nog stuurt mag niets aanklikken
    const slik = (klik) => { klik.stopPropagation(); klik.preventDefault(); };
    sectie.addEventListener("click", slik, true);
    setTimeout(() => sectie.removeEventListener("click", slik, true), 300);
  }
  sectie.addEventListener("pointerup", (e) => einde(e, false));
  sectie.addEventListener("pointercancel", (e) => einde(e, true));
}
document.querySelectorAll("section[data-terug]").forEach(maakTerugveegbaar);

// ---------- PWA ----------
if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js");

init();
