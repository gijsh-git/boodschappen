// Edge Function: geeft de typelijst terug zoals ze in de database staat, voor docs/producttypes-export.csv.
// De database is de bron van de typelijst; het bestand in git is alleen een afdruk. Bedoeld voor
// scripts/producttypes-exporteren.py (dat de git-hook bij elke commit draait), niet voor de app: geen login,
// maar dezelfde sleutel als de andere functies voor aanbiedingen in de header x-aanbiedingen-sleutel.
// De functie leest alleen: namen van types, hun afbakening en aantallen. Geen aankopen of gebruikers.
import { createClient } from "npm:@supabase/supabase-js@2";

const KOP = "x-aanbiedingen-sleutel";

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

  // De service role komt uit de omgeving van de functie en wordt alleen voor deze ene aanroep gebruikt
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await db.rpc("product_types_export");
  if (error) {
    console.error("product_types_export mislukt:", error.message);
    return antwoord({ fout: "Lezen mislukt: " + error.message }, 500);
  }
  return antwoord({ types: data });
});
