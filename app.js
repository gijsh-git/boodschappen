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
const views = ["login", "password", "setup", "list"];
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
  if (/rate limit|security purposes/i.test(m)) return "Er zijn te veel mails verstuurd. Probeer het over een tijdje opnieuw.";
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
  db.auth.onAuthStateChange((event, s) => {
    if (event === "PASSWORD_RECOVERY") mustSetPassword = true;
    if (s) route(); else show("login");
  });
  if (session) route(); else show("login");
  if (linkError) say("login-msg", "De link is verlopen of al gebruikt. Vraag een nieuwe aan via 'Wachtwoord vergeten?'.");
}

async function route() {
  if (mustSetPassword) return show("password");
  const { data, error } = await db
    .from("list_members")
    .select("list_id, lists(id, name, invite_code)")
    .limit(1);
  if (mustSetPassword) return show("password");
  if (error) { show("setup"); say("setup-msg", error.message); return; }
  if (data.length === 0) { show("setup"); return; }
  openList(data[0].lists);
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

// Wachtwoord vergeten: stuurt een mail met een link naar het scherm "Kies je wachtwoord"
$("forgot").addEventListener("click", async () => {
  const email = $("email").value.trim();
  if (!email) { $("email").focus(); return say("login-msg", "Vul eerst je e-mailadres in."); }
  say("login-msg", "Bezig...");
  const { error } = await db.auth.resetPasswordForEmail(email, {
    redirectTo: location.origin + location.pathname
  });
  say("login-msg", error ? nl(error) : "Als dit adres bekend is, krijg je een mail met een link. Open die op dit toestel.");
});

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

async function logout() {
  await db.auth.signOut();
  if (channel) db.removeChannel(channel);
  currentList = null;
  mustSetPassword = false;
  show("login");
}
$("logout").addEventListener("click", logout);
$("logout-setup").addEventListener("click", logout);

// ---------- Lijst maken / aansluiten ----------
$("create-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const { data, error } = await db.rpc("create_list", { p_name: $("list-name").value.trim() });
  if (error) return say("setup-msg", error.message);
  openList(data);
});

$("join-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const { data, error } = await db.rpc("join_list", { p_code: $("join-code").value });
  if (error) return say("setup-msg", error.message);
  openList(data);
});

// ---------- De lijst ----------
async function openList(list) {
  currentList = list;
  $("list-title").textContent = list.name;
  $("invite-code").textContent = list.invite_code;
  show("list");
  await loadItems();
  subscribe();
}

async function loadItems() {
  const { data, error } = await db
    .from("items")
    .select("*")
    .eq("list_id", currentList.id)
    .order("created_at", { ascending: true });
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

  li.append(label, del);
  return li;
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
