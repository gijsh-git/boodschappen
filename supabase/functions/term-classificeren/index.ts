// Edge Function: geeft een term die op een lijst is getypt (of op een bon stond) en nergens voor staat een
// producttype. Aangeroepen door de database zelf: handle_unmatched_term() stuurt via pg_net een seintje zodra
// er een onbekende term is. Geen login, maar dezelfde sleutel als de andere functies voor aanbiedingen in de
// header x-aanbiedingen-sleutel (secret AANBIEDINGEN_SLEUTEL; de database leest hem uit Vault).
// De functie haalt de open termen op met term_work(), laat de AI per term een type uit de lijst kiezen (en
// het merk als de term er een noemt) en slaat dat op met save_term_judgments(): als naam met bron ai, zonder
// goedkeuring vooraf. Het label op de lijst verschijnt daarna vanzelf. Bij hetzelfde oordeel geeft de AI de
// variant die de term noemt ("tomaat" bij "tomatensoep"), voor de volgorde in het bonuspaneel. Met
// { "varianten": true } in het verzoek (het wekelijkse script) vult een aanroep ook de variant aan bij namen
// die al een type hebben; hun type blijft wat het is. Er gaan alleen de termen en de typelijst naar de AI,
// geen gebruikers of lijsten. De API-sleutel staat alleen in Supabase secrets.
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const KOP = "x-aanbiedingen-sleutel";
// Model dat de termen beoordeelt
const MODEL = "claude-opus-5-5";
// Zoveel termen per aanroep van de AI, en zo vaak achter elkaar als er intussen termen bijkomen
const PORTIE = 40;
const RONDES = 3;
// Wat de AI als type teruggeeft als de term bij geen enkel type hoort
const GEEN = "geen type";
const ZEKERHEID: Record<string, string> = { hoog: "high", middel: "medium", laag: "low" };

const INSTRUCTIES = `Je koppelt wat mensen op een boodschappenlijst typen aan de producttypes van een boodschappen-app. Een type is het niveau waarop een koper wisselt bij een aanbieding: is een artikel van een type in de aanbieding, dan krijgt wie dat type op zijn lijst heeft een label.

De termen zijn kort en slordig: tikfouten, afkortingen, enkelvoud of meervoud, soms een merk erbij, soms een bontekst. Kies per term het ene type waar hij voor staat, of "${GEEN}". Neem de naam van het type letterlijk over uit de lijst.

- Toets: zou iemand die dit opschrijft bij een aanbieding een artikel van dat type kopen?
- Lees de afbakening. "Niet:" zegt wat er net niet bij hoort en waar dat wel hoort. Varianten waar je niet tussen wisselt hebben een eigen type: zero, light, suikervrij, 0%, decaf en alcoholvrij; halfvolle en volle melk; vers tegenover gedroogd of uit pot of blik. Zonder "gedroogd", "pot" of "blik" in de term is het de verse variant.
- merk: noemt de term een merk naast de soort ("sensodyne tandpasta", "pasta van barilla"), geef dat merk dan zoals het op de verpakking staat. Anders een lege tekst. Een merk dat mensen als soortnaam gebruiken ("nutella" voor chocoladepasta) is geen merk hier.
- Een losse merknaam zonder soort krijgt "${GEEN}": het merk kan van alles zijn.
- Een term die te vaag is om één type te kiezen ("sap", "papier", "saus", "groenten", "iets lekkers") krijgt "${GEEN}". Gok niet: een fout type geeft een label op iets wat de koper niet zoekt.
- Geen boodschap, onleesbaar of een notitie ("niet vergeten", "bellen"): het type voor onleesbare invoer als dat bestaat, anders "${GEEN}".
- variant: het ene woord dat zegt welke smaak of soort binnen het type de term noemt: "tomaat" bij "tomatensoep", "kip" bij "kippensoep", "aardbei" bij "aardbeien yoghurt", "paprika" bij "chips paprika". Enkelvoud, kleine letters, geen merk, en niet wat de naam van het type al zegt. Noemt de term geen smaak of soort ("soep", "chips", "halfvolle melk"), of is het "${GEEN}", dan een lege tekst.
- voorstel: alleen bij "${GEEN}", als de term wel een gewone boodschap is maar het type in de lijst ontbreekt ("afwasborstel"): de naam die dat type zou hebben, zoals op een boodschappenlijst (kleine letters, zonder merk). Bij een vage term, een losse merknaam of een gekozen type een lege tekst.
- zekerheid: "hoog" als de term zonder twijfel dit type is, "middel" als het waarschijnlijk klopt, "laag" bij echte twijfel. Bij "${GEEN}" zegt de zekerheid hoe zeker je bent dat geen type past.
- reden: één korte zin in het Nederlands.

Geef voor elke term precies één oordeel, met het nummer van de term.`;

type Soort = { id: string; naam: string; hoofdgroep: string; valt_eronder: string | null; valt_er_niet_onder: string | null };
// alleen_variant: de naam heeft al een type en krijgt alleen nog een variant
type Term = { sleutel: string; term: string; alleen_variant?: boolean };
type Rij = { term: string; type_id: string | null; brand: string | null; variant: string | null; suggested_type: string | null; confidence: string; reason: string };

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

// De typelijst per hoofdgroep. Voor elke aanroep gelijk (vaste volgorde uit de database), zodat hij na de
// eerste keer uit de cache komt.
function typesTekst(types: Soort[]) {
  const regels: string[] = [];
  let groep = "";
  for (const t of types) {
    if (t.hoofdgroep !== groep) {
      groep = t.hoofdgroep;
      regels.push("", `## ${groep}`);
    }
    regels.push(`- ${t.naam}` + (t.valt_eronder ? `: ${t.valt_eronder}` : "") + (t.valt_er_niet_onder ? ` Niet: ${t.valt_er_niet_onder}` : ""));
  }
  return regels.join("\n");
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
  const apiSleutel = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiSleutel) return antwoord({ fout: "De secret ANTHROPIC_API_KEY is niet ingesteld." }, 500);

  // De service role komt uit de omgeving van de functie en wordt alleen voor deze twee functies gebruikt
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const claude = new Anthropic({ apiKey: apiSleutel });
  const vraag = await req.json().catch(() => ({}));
  const varianten = vraag?.varianten === true;
  // nog_varianten: namen met een type die nog op een variant wachten (alleen geteld met varianten)
  const telling = { beoordeeld: 0, met_type: 0, geen_type: 0, ongeldig: 0, items: 0, varianten: 0, nog_varianten: 0 };

  // Terwijl de AI bezig is kunnen er termen bijkomen (een foto met meerdere onbekende items geeft per item
  // een seintje, maar alleen de eerste aanroep pakt ze op): daarom een paar rondes achter elkaar.
  for (let ronde = 0; ronde < RONDES; ronde++) {
    const { data: werk, error: leesFout } = await db.rpc("term_work", { p_limit: PORTIE, p_variants: varianten });
    if (leesFout) {
      console.error("term_work mislukt:", leesFout.message);
      return antwoord({ fout: "Lezen mislukt: " + leesFout.message }, 500);
    }
    const termen: Term[] = werk.termen ?? [];
    const types: Soort[] = werk.types ?? [];
    telling.nog_varianten = werk.nog_varianten ?? 0;
    if (termen.length === 0) break;
    if (types.length === 0) return antwoord({ fout: "Er zijn nog geen producttypes; laad eerst de typelijst." }, 409);

    const perNaam = new Map(types.map((t) => [t.naam, t]));
    const schema = {
      type: "object",
      properties: {
        oordelen: {
          type: "array",
          items: {
            type: "object",
            properties: {
              term: { type: "integer", description: "Het nummer van de term in het bericht" },
              type: { type: "string", enum: [GEEN, ...perNaam.keys()], description: "De naam van het type, letterlijk uit de lijst" },
              merk: { type: "string", description: "Het merk dat de term naast de soort noemt, anders leeg" },
              variant: { type: "string", description: "De smaak of soort die de term binnen het type noemt in één woord, anders leeg" },
              voorstel: { type: "string", description: `Alleen bij "${GEEN}": het type dat in de lijst ontbreekt, anders leeg` },
              zekerheid: { type: "string", enum: Object.keys(ZEKERHEID) },
              reden: { type: "string" },
            },
            required: ["term", "type", "merk", "variant", "voorstel", "zekerheid", "reden"],
            additionalProperties: false,
          },
        },
      },
      required: ["oordelen"],
      additionalProperties: false,
    };

    let uit: { oordelen?: unknown };
    try {
      const bericht = await claude.beta.messages.create({
        model: MODEL,
        max_tokens: 16000,
        // Weigert het model onterecht, dan probeert de API het zelf opnieuw met een ander model
        betas: ["server-side-fallback-2026-07-01"],
        // @ts-ignore: de "default"-vorm staat nog niet in alle versies van de SDK-types
        fallbacks: "default",
        output_config: { effort: "low", format: { type: "json_schema", schema } },
        // De opdracht en de typelijst zijn voor elke aanroep gelijk en komen binnen vijf minuten uit de cache
        system: [{ type: "text", text: INSTRUCTIES + "\n\n# Producttypes\n" + typesTekst(types), cache_control: { type: "ephemeral" } }],
        messages: [{ role: "user", content: "Termen:\n" + termen.map((t, i) => `${i + 1}. ${t.term}`).join("\n") }],
      });
      if (bericht.stop_reason !== "end_turn") throw new Error(`de AI stopte met "${bericht.stop_reason}"`);
      const tekst = bericht.content.find((blok) => blok.type === "text");
      uit = JSON.parse(tekst && tekst.type === "text" ? tekst.text : "{}");
    } catch (fout) {
      // De termen blijven open; na een paar minuten pakt een volgende aanroep ze opnieuw op
      console.error("Beoordelen mislukt:", fout);
      if (fout instanceof Anthropic.RateLimitError) return antwoord({ ...telling, fout: "Het is even te druk bij de AI." }, 429);
      return antwoord({ ...telling, fout: "Beoordelen mislukt: " + (fout instanceof Error ? fout.message : String(fout)) }, 502);
    }

    const rijen: Rij[] = [];
    const alleenVariant: { term: string; variant: string | null }[] = [];
    const gezien = new Set<number>();
    for (const o of Array.isArray(uit.oordelen) ? uit.oordelen : []) {
      const nr = o?.term;
      if (!Number.isInteger(nr) || nr < 1 || nr > termen.length || gezien.has(nr) || !(o.zekerheid in ZEKERHEID)) continue;
      const soort = o.type === GEEN ? null : perNaam.get(o.type);
      // Een naam buiten de lijst: de term blijft open
      if (soort === undefined) continue;
      gezien.add(nr);
      const variant = soort ? String(o.variant ?? "").trim().toLowerCase() || null : null;
      if (termen[nr - 1].alleen_variant) {
        alleenVariant.push({ term: termen[nr - 1].term, variant });
        continue;
      }
      rijen.push({
        term: termen[nr - 1].term,
        type_id: soort ? soort.id : null,
        brand: soort ? String(o.merk ?? "").trim() || null : null,
        variant,
        suggested_type: soort ? null : String(o.voorstel ?? "").trim().toLowerCase() || null,
        confidence: ZEKERHEID[o.zekerheid],
        reason: String(o.reden ?? "").trim(),
      });
    }
    telling.ongeldig += termen.length - rijen.length - alleenVariant.length;
    if (rijen.length + alleenVariant.length === 0) break;

    const { data: opgeslagen, error: schrijfFout } = await db.rpc("save_term_judgments", { p_rows: rijen, p_variants: alleenVariant });
    if (schrijfFout) {
      console.error("save_term_judgments mislukt:", schrijfFout.message);
      return antwoord({ ...telling, fout: "Opslaan mislukt: " + schrijfFout.message }, 500);
    }
    telling.beoordeeld += rijen.length;
    telling.met_type += rijen.filter((r) => r.type_id).length;
    telling.geen_type += rijen.filter((r) => !r.type_id).length;
    telling.items += opgeslagen.items ?? 0;
    telling.varianten += opgeslagen.varianten ?? 0;
    telling.nog_varianten = Math.max(0, telling.nog_varianten - alleenVariant.length);
    // Aanvullen gaat één portie per aanroep: het script vraagt opnieuw tot er niets meer wacht
    if (termen.some((t) => t.alleen_variant)) break;
  }
  return antwoord(telling);
});
