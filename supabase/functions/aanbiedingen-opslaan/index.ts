// Edge Function: neemt de opgehaalde aanbiedingen van een supermarkt aan en slaat ze op via save_offers.
// Bedoeld voor het ophaalscript (scripts/ah-bonus-opslaan.py), niet voor de app: er is geen login, maar
// een eigen sleutel in de header x-aanbiedingen-sleutel, die gelijk moet zijn aan de secret
// AANBIEDINGEN_SLEUTEL. Zo hoeft de service role key Supabase niet uit: wie de sleutel heeft kan alleen
// aanbiedingen opslaan, niets lezen en niets anders schrijven.
import { createClient } from "npm:@supabase/supabase-js@2";

const KOP = "x-aanbiedingen-sleutel";
const MAX_TEKENS = 5_000_000; // een AH-week is ongeveer 1 MB
const MAX_AANBIEDINGEN = 2000;

function antwoord(inhoud: unknown, status = 200) {
  return new Response(JSON.stringify(inhoud), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Vergelijkt in constante tijd: eerst beide naar een hash van vaste lengte, dan alle bytes langs,
// zodat de duur niets zegt over de lengte van de sleutel of over hoeveel tekens er kloppen.
async function gelijk(a: string, b: string) {
  const tekst = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest("SHA-256", tekst.encode(a)),
    crypto.subtle.digest("SHA-256", tekst.encode(b)),
  ]);
  const p = new Uint8Array(x);
  const q = new Uint8Array(y);
  let verschil = 0;
  for (let i = 0; i < p.length; i++) verschil |= p[i] ^ q[i];
  return verschil === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return antwoord({ fout: "Alleen POST." }, 405);

  const geheim = Deno.env.get("AANBIEDINGEN_SLEUTEL") ?? "";
  if (geheim.length < 32) {
    return antwoord({ fout: "De secret AANBIEDINGEN_SLEUTEL is niet ingesteld (minstens 32 tekens)." }, 500);
  }
  if (!(await gelijk(req.headers.get(KOP) ?? "", geheim))) {
    return antwoord({ fout: "Geen toegang." }, 401);
  }

  // De lengte in de header is alleen een eerste zeef; daarna telt wat er echt binnenkomt
  if (Number(req.headers.get("content-length") ?? 0) > MAX_TEKENS) {
    return antwoord({ fout: "Te veel gegevens in één keer." }, 413);
  }
  const lezer = req.body?.getReader();
  if (!lezer) return antwoord({ fout: "Geen gegevens ontvangen." }, 400);
  const stukken: Uint8Array[] = [];
  let totaal = 0;
  while (true) {
    const { done, value } = await lezer.read();
    if (done) break;
    totaal += value.length;
    if (totaal > MAX_TEKENS) {
      await lezer.cancel();
      return antwoord({ fout: "Te veel gegevens in één keer." }, 413);
    }
    stukken.push(value);
  }

  let invoer: { supermarkt?: unknown; aanbiedingen?: unknown };
  try {
    invoer = JSON.parse(await new Blob(stukken).text());
  } catch {
    return antwoord({ fout: "De gegevens zijn geen geldige JSON." }, 400);
  }
  const { supermarkt, aanbiedingen } = invoer ?? {};
  if (typeof supermarkt !== "string" || !supermarkt.trim() || supermarkt.length > 40) {
    return antwoord({ fout: "Geen supermarkt opgegeven." }, 400);
  }
  if (!Array.isArray(aanbiedingen) || aanbiedingen.length === 0 || aanbiedingen.length > MAX_AANBIEDINGEN) {
    return antwoord({ fout: `Geef 1 tot ${MAX_AANBIEDINGEN} aanbiedingen mee.` }, 400);
  }

  // De service role komt uit de omgeving van de functie en wordt alleen voor deze ene aanroep gebruikt
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await db.rpc("save_offers", { p_supermarket: supermarkt.trim(), p_offers: aanbiedingen });
  if (error) {
    console.error("save_offers mislukt:", error.message);
    return antwoord({ fout: "Opslaan mislukt: " + error.message }, 500);
  }
  return antwoord(data);
});
