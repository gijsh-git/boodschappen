// Edge Function: leest een foto of pdf van een kassabon en geeft de supermarkt, de datum, het totaal
// en de bonregels terug. De app toont ze eerst ter controle en slaat ze zelf op als aankopen.
// Het bestand wordt nergens bewaard. De API-sleutel staat alleen in Supabase secrets (ANTHROPIC_API_KEY).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

// Model dat de bon leest. Goedkoper kan met "claude-sonnet-5-5" of "claude-haiku-4-5".
const MODEL = "claude-opus-5-5";
const PDF = "application/pdf";
const TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif", PDF];
const MAX_TEKENS = 6_000_000; // base64; de app verkleint de foto, dit is alleen een vangnet

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const INSTRUCTIES = `Je krijgt een foto of pdf van een kassabon van een supermarkt. Geef de gegevens van de bon en de producten die erop staan.

Per bon:
- supermarkt: "AH" voor Albert Heijn, "PLUS" voor PLUS, en anders de naam zoals die op de bon staat. Niet te lezen: null.
- datum: de datum van de bon als JJJJ-MM-DD. Niet te lezen: null. Verzin geen datum.
- totaal: het bedrag dat betaald moest worden, in euro's. Niet te lezen: null.

Per product één regel:
- bon_naam: de tekst van de regel precies zoals die op de bon staat ("AH JB PLAKKEN 400G").
- naam: een leesbare, korte productnaam in het Nederlands en in kleine letters. Schrijf afkortingen uit en laat het huismerk en de verpakkingsgrootte weg: "AH JB PLAKKEN 400G" wordt "jong belegen kaas plakken", "HV MELK 1L" wordt "halfvolle melk". Een merk dat bij het product hoort mag blijven ("coca cola zero"). Weet je niet wat een afkorting betekent, blijf dan zo dicht mogelijk bij de tekst van de bon.
- aantal: hoeveel stuks er zijn gekocht. Bij producten die per gewicht zijn afgerekend is het aantal 1.
- prijs: het bedrag van de hele regel in euro's, vóór aftrek van korting (dus bij 2 stuks de prijs van beide samen). Niet te lezen: null.
- korting: de korting op dit product in euro's, als positief getal. Staat de korting apart op de bon (bijvoorbeeld onderaan in een blok met bonus- of actiekortingen), zet die dan bij het product waar ze bij hoort. Geen korting: null.

Regels:
- Staat hetzelfde product op meerdere regels, maak er dan één regel van en tel aantal, prijs en korting op.
- Sla alles over wat geen product is: statiegeld en emballage, zegels en spaaracties, subtotalen, btw, betaalwijze, wisselgeld en kortingen die niet bij één product horen.
- Bedragen zijn getallen met een punt als decimaalteken (1.99), zonder euroteken.
- Verzin niets: neem alleen op wat echt op de bon staat. Is het geen kassabon of staan er geen producten op, geef dan een lege lijst regels.`;

const SCHEMA = {
  type: "object",
  properties: {
    supermarkt: { type: ["string", "null"] },
    datum: { type: ["string", "null"] },
    totaal: { type: ["number", "null"] },
    regels: {
      type: "array",
      items: {
        type: "object",
        properties: {
          bon_naam: { type: "string" },
          naam: { type: "string" },
          aantal: { type: "number" },
          prijs: { type: ["number", "null"] },
          korting: { type: ["number", "null"] },
        },
        required: ["bon_naam", "naam", "aantal", "prijs", "korting"],
        additionalProperties: false,
      },
    },
  },
  required: ["supermarkt", "datum", "totaal", "regels"],
  additionalProperties: false,
};

function antwoord(inhoud: unknown, status = 200) {
  return new Response(JSON.stringify(inhoud), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// Bedrag in euro's, afgerond op centen; null als het geen bruikbaar getal is
function bedrag(waarde: unknown) {
  return typeof waarde === "number" && Number.isFinite(waarde) && waarde >= 0 ? Math.round(waarde * 100) / 100 : null;
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
  if (typeof type !== "string" || !TYPES.includes(type)) return antwoord({ fout: "Dit soort bestand wordt niet ondersteund." }, 400);
  if (afbeelding.length > MAX_TEKENS) return antwoord({ fout: "De foto is te groot." }, 400);

  const apiSleutel = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiSleutel) {
    console.error("ANTHROPIC_API_KEY ontbreekt in de secrets");
    return antwoord({ fout: "De bonfunctie is nog niet ingesteld." }, 500);
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
          type === PDF
            ? { type: "document", source: { type: "base64", media_type: PDF, data: afbeelding } }
            : { type: "image", source: { type: "base64", media_type: type as "image/jpeg", data: afbeelding } },
          { type: "text", text: "Wat staat er op deze kassabon?" },
        ],
      }],
    });

    if (bericht.stop_reason === "refusal") return antwoord({ fout: "Deze foto kon niet worden verwerkt." }, 422);
    if (bericht.stop_reason === "max_tokens") return antwoord({ fout: "Er staat te veel op deze foto. Probeer een kleiner stuk." }, 422);

    const tekst = bericht.content.find((blok) => blok.type === "text");
    const uitkomst = JSON.parse(tekst && tekst.type === "text" ? tekst.text : "{}");
    const regels = (Array.isArray(uitkomst.regels) ? uitkomst.regels : [])
      .map((r: { bon_naam?: unknown; naam?: unknown; aantal?: unknown; prijs?: unknown; korting?: unknown }) => ({
        bon_naam: typeof r.bon_naam === "string" ? r.bon_naam.trim() : "",
        naam: typeof r.naam === "string" ? r.naam.trim() : "",
        aantal: typeof r.aantal === "number" && Number.isFinite(r.aantal) && r.aantal > 0 ? r.aantal : 1,
        prijs: bedrag(r.prijs),
        korting: bedrag(r.korting) || null, // 0 is geen korting
      }))
      .filter((r: { naam: string }) => r.naam);
    return antwoord({
      bon: {
        supermarkt: typeof uitkomst.supermarkt === "string" && uitkomst.supermarkt.trim() ? uitkomst.supermarkt.trim() : null,
        datum: typeof uitkomst.datum === "string" && /^\d{4}-\d{2}-\d{2}$/.test(uitkomst.datum) ? uitkomst.datum : null,
        totaal: bedrag(uitkomst.totaal),
        regels,
      },
    });
  } catch (fout) {
    console.error("Bon lezen mislukt:", fout);
    if (fout instanceof Anthropic.AuthenticationError) return antwoord({ fout: "De API-sleutel van de bonfunctie klopt niet." }, 500);
    if (fout instanceof Anthropic.RateLimitError) return antwoord({ fout: "Het is even te druk. Probeer het over een minuut opnieuw." }, 429);
    if (fout instanceof Anthropic.APIError) return antwoord({ fout: "De bon kon niet worden gelezen. Probeer het opnieuw." }, 502);
    return antwoord({ fout: "Er ging iets mis bij het lezen van de bon." }, 500);
  }
});
