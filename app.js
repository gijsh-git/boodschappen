const { SUPABASE_URL, SUPABASE_ANON_KEY } = window.CONFIG;
const db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const $ = (id) => document.getElementById(id);
const views = ["login", "setup", "list"];
let currentList = null;
let channel = null;
let items = [];

function show(view) {
  views.forEach((v) => ($("view-" + v).hidden = v !== view));
}

function say(id, text) {
  $(id).textContent = text || "";
}

// ---------- Start ----------
async function init() {
  if (SUPABASE_URL.includes("JOUW-PROJECT")) {
    show("login");
    say("login-msg", "Vul eerst config.js in met je Supabase-gegevens.");
    return;
  }
  const { data: { session } } = await db.auth.getSession();
  db.auth.onAuthStateChange((_e, s) => { if (s) route(); else show("login"); });
  if (session) route(); else show("login");
}

async function route() {
  const { data, error } = await db
    .from("list_members")
    .select("list_id, lists(id, name, invite_code)")
    .limit(1);
  if (error) { show("setup"); say("setup-msg", error.message); return; }
  if (data.length === 0) { show("setup"); return; }
  openList(data[0].lists);
}

// ---------- Inloggen ----------
$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  say("login-msg", "Bezig...");
  const { error } = await db.auth.signInWithOtp({
    email: $("email").value.trim(),
    // shouldCreateUser: false = alleen bestaande (uitgenodigde) accounts kunnen inloggen
    options: { emailRedirectTo: location.origin + location.pathname, shouldCreateUser: false }
  });
  if (error && /signups not allowed/i.test(error.message)) {
    return say("login-msg", "Dit e-mailadres is niet uitgenodigd. Vraag de beheerder om een uitnodiging.");
  }
  say("login-msg", error ? error.message : "Check je mail en open de link op dit toestel.");
});

async function logout() {
  await db.auth.signOut();
  if (channel) db.removeChannel(channel);
  currentList = null;
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
