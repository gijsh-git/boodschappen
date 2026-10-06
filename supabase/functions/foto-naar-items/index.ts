// Edge Function: leest een foto of screenshot (recept, handgeschreven lijstje) en geeft
// de producten erop terug als boodschappen. De app toont ze eerst ter controle en voegt ze zelf toe.
// De API-sleutel staat alleen in Supabase secrets (ANTHROPIC_API_KEY), nooit in de app.
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

// Model dat de foto leest. Goedkoper kan met "claude-sonnet-5-5" of "claude-haiku-4-5".
const MODEL = "claude-opus-5-5";
// Wat bijna iedereen in huis heeft en dus niet op de lijst hoeft
const IN_HUIS = ["zout", "peper", "water"];
const TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"];
const MAX_TEKENS = 6_000_000; // base64; de app verkleint de foto, dit is alleen een vangnet

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const INSTRUCTIES = `Je krijgt een foto of screenshot, bijvoorbeeld van een recept of een handgeschreven boodschappenlijstje. Geef de producten die iemand daarvoor in de supermarkt moet kopen.

Regels:
- Maak van receptingrediënten gewone boodschappen. "2 el olijfolie" wordt "olijfolie"; "1 teentje knoflook, fijngehakt" wordt "knoflook"; "sap van een halve citroen" wordt "citroen".
- De naam is kort, in het Nederlands en in kleine letters: alleen het product, zonder bereidingswijze of toelichting. Een merk of soort dat er uitdrukkelijk bij staat mag blijven ("griekse yoghurt", "volkoren pasta").
- Geef een hoeveelheid alleen als die helpt bij het boodschappen doen: gewicht, inhoud of aantal stuks ("500 g", "1 blik", "2 stuks", "400 ml"). Kookmaten zoals eetlepels, theelepels, een snufje of een scheutje laat je weg: de hoeveelheid is dan null. Staat er geen hoeveelheid, dan ook null.
- Sla over wat bijna iedereen in huis heeft: ${IN_HUIS.join(", ")}.
- Komt een product meerdere keren voor, noem het dan één keer en tel de hoeveelheden op als dat kan.
- Is het al een boodschappenlijstje, neem de regels dan over zoals ze er staan (wel in kleine letters, hoeveelheid apart).
- Verzin niets: neem alleen producten op die echt op de afbeelding staan. Staan er geen producten op, geef dan een lege lijst.`;

const SCHEMA = {
  type: "object",
  properties: {
    producten: {
      type: "array",
      items: {
        type: "object",
        properties: {
          naam: { type: "string" },
          hoeveelheid: { type: ["string", "null"] },
        },
        required: ["naam", "hoeveelheid"],
        additionalProperties: false,
      },
    },
  },
  required: ["producten"],
  additionalProperties: false,
};

function antwoord(inhoud: unknown, status = 200) {
  return new Response(JSON.stringify(inhoud), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return antwoord({ fout: "Alleen POST." }, 405);

  // Alleen ingelogde gebruikers: anders kan iedereen met de publieke sleutel het Claude-tegoed opmaken
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const sleutel = Deno.env.get("SUPABASE_ANON_KEY") || req.headers.get("apikey") || "";
  const db = createClient(Deno.env.get("SUPABASE_URL")!, sleutel);
  const { data: gebruiker, error: loginFout } = await db.auth.getUser(token);
  if (loginFout || !gebruiker?.user) return antwoord({ fout: "Je bent niet ingelogd." }, 401);

  let afbeelding: unknown, type: unknown;
  try {
    ({ afbeelding, type } = await req.json());
  } catch {
    return antwoord({ fout: "Het verzoek is niet leesbaar." }, 400);
  }
  if (typeof afbeelding !== "string" || !afbeelding) return antwoord({ fout: "Er is geen foto meegestuurd." }, 400);
  if (typeof type !== "string" || !TYPES.includes(type)) return antwoord({ fout: "Dit soort afbeelding wordt niet ondersteund." }, 400);
  if (afbeelding.length > MAX_TEKENS) return antwoord({ fout: "De foto is te groot." }, 400);

  const apiSleutel = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiSleutel) {
    console.error("ANTHROPIC_API_KEY ontbreekt in de secrets");
    return antwoord({ fout: "De fotofunctie is nog niet ingesteld." }, 500);
  }
  const claude = new Anthropic({ apiKey: apiSleutel });

  try {
    const bericht = await claude.beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      // Weigert het model onterecht, dan probeert de API het zelf opnieuw met een ander model
      betas: ["server-side-fallback-2026-07-01"],
      // @ts-ignore: de "default"-vorm staat nog niet in alle versies van de SDK-types
      fallbacks: "default",
      output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
      system: INSTRUCTIES,
      messages: [{
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: type as "image/jpeg", data: afbeelding } },
          { type: "text", text: "Welke boodschappen staan er op deze afbeelding?" },
        ],
      }],
    });

    if (bericht.stop_reason === "refusal") return antwoord({ fout: "Deze foto kon niet worden verwerkt." }, 422);
    if (bericht.stop_reason === "max_tokens") return antwoord({ fout: "Er staat te veel op deze foto. Probeer een kleiner stuk." }, 422);

    const tekst = bericht.content.find((blok) => blok.type === "text");
    const uitkomst = JSON.parse(tekst && tekst.type === "text" ? tekst.text : "{}");
    const producten = (Array.isArray(uitkomst.producten) ? uitkomst.producten : [])
      .map((p: { naam?: unknown; hoeveelheid?: unknown }) => ({
        naam: typeof p.naam === "string" ? p.naam.trim() : "",
        hoeveelheid: typeof p.hoeveelheid === "string" && p.hoeveelheid.trim() ? p.hoeveelheid.trim() : null,
      }))
      .filter((p: { naam: string }) => p.naam);
    return antwoord({ producten });
  } catch (fout) {
    console.error("Foto lezen mislukt:", fout);
    if (fout instanceof Anthropic.AuthenticationError) return antwoord({ fout: "De API-sleutel van de fotofunctie klopt niet." }, 500);
    if (fout instanceof Anthropic.RateLimitError) return antwoord({ fout: "Het is even te druk. Probeer het over een minuut opnieuw." }, 429);
    if (fout instanceof Anthropic.APIError) return antwoord({ fout: "De foto kon niet worden gelezen. Probeer het opnieuw." }, 502);
    return antwoord({ fout: "Er ging iets mis bij het lezen van de foto." }, 500);
  }
});
