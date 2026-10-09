// Edge Function: geeft artikelen uit de aanbiedingen een producttype.
// Bedoeld voor het ophaalscript (scripts/ah-bonus-opslaan.py), niet voor de app: er is geen login, maar
// dezelfde sleutel als bij aanbiedingen-opslaan in de header x-aanbiedingen-sleutel (secret
// AANBIEDINGEN_SLEUTEL). Per aanroep beoordeelt de AI een aantal artikelen die nog geen oordeel hebben, met
// titel, merk, inhoud en categorie als invoer en de hele typelijst erbij, en slaat dat op via
// save_article_types. Bij hetzelfde oordeel geeft de AI de variant (de smaak of soort binnen het type), die
// bepaalt bij welke term het artikel een Bonus-label geeft en de volgorde in het bonuspaneel; een artikel dat al een type had krijgt alleen die variant.
// Past er geen type, dan stelt de AI er een voor met hoofdgroep en afbakening, en maakt save_article_types het type
// meteen aan. Het antwoord zegt hoeveel er nog over zijn; het script roept opnieuw aan tot dat 0 is.
// Er gaan alleen artikelgegevens en de typelijst naar de AI. De API-sleutel staat alleen in Supabase
// secrets (ANTHROPIC_API_KEY).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const KOP = "x-aanbiedingen-sleutel";
// Model dat de artikelen beoordeelt
const MODEL = "claude-opus-5-5";
// Zoveel artikelen per aanroep van de AI, en zoveel aanroepen tegelijk per aanroep van deze functie
const PORTIE = 40;
const TEGELIJK = 3;
// Wat de AI als type teruggeeft als het artikel bij geen enkel type hoort
const GEEN = "geen type";
const ZEKERHEID: Record<string, string> = { hoog: "high", middel: "medium", laag: "low" };

const INSTRUCTIES = `Je koppelt artikelen van een supermarkt aan de producttypes van een boodschappen-app. Een type is het niveau waarop een koper wisselt bij een aanbieding: is een artikel van een type in de aanbieding, dan laat de app dat zien aan wie dat type koopt of op zijn lijst heeft.

Kies per artikel het ene type waar het bij hoort, of "${GEEN}". Neem de naam van het type letterlijk over uit de lijst.

- Toets: zou iemand die dit type koopt bij een aanbieding dit artikel in plaats daarvan kopen? Zo ja, dan hoort het erbij, ook als het een ander merk, formaat, een andere smaak of biologisch is.
- Kijk naar wat het artikel is, niet naar losse woorden. Een woord uit de typenaam in de titel is geen bewijs: pompoensoep is geen pompoen, brood met pompoen is geen pompoen, douchegel met avocado is geen avocado, thee met honing is geen honing.
- De categorie van de supermarkt helpt, maar is geen bewijs: wat de titel zegt gaat voor. De hoofdgroep van een type is de hoofdcategorie waar het meestal staat; een artikel mag bij een type uit een andere hoofdgroep horen.
- Lees de afbakening. "Niet:" zegt wat er net niet bij hoort en waar dat wel hoort. Varianten waar je niet tussen wisselt hebben een eigen type: zero, light, suikervrij, 0%, decaf en alcoholvrij tegenover gewoon; halfvolle en volle melk; vers tegenover gedroogd of uit pot of blik; wat alleen in een eigen apparaat of systeem werkt. Bestaat dat eigen type niet, kies dan "${GEEN}" en niet de gewone variant.
- Een apparaat, handvat of starterset, een cadeaupakket en een gemengde verpakking met meerdere soorten horen bij geen enkel type.
- Past er geen type, kies dan "${GEEN}". Kies geen type dat alleen in de buurt komt. Geef in voorstel dan de naam van het type dat in de lijst ontbreekt, zoals iemand het op een boodschappenlijst zet (kleine letters, zonder merk), of een lege tekst als het geen gewone boodschap is. Bij een gekozen type is voorstel leeg.
- variant: het ene woord dat zegt welke smaak of soort het artikel binnen zijn type is, zoals iemand het op een boodschappenlijst voor de soortnaam zet: "tomaat" bij tomatensoep, "kip" bij kippensoep, "aardbei" bij aardbeienyoghurt, "paprika" bij paprikachips, "naturel" bij chips naturel. Enkelvoud, kleine letters, het hoofdbestanddeel of de hoofdsmaak en geen bijzaak ("tomaat" bij Chinese tomatensoep). Geen merk, geen formaat, niet biologisch of huismerk, en niet wat de naam van het type al zegt. Valt er geen smaak of soort te noemen (halfvolle melk bij het type halfvolle melk, wc-papier), of is het "${GEEN}", dan een lege tekst.
- Bij een voorstel geef je ook voorstel_hoofdgroep (de hoofdgroep waar het type onder hoort, letterlijk een van de koppen uit de lijst), voorstel_eronder (één zin: wat valt eronder, ongeacht merk, met een of twee voorbeelden) en voorstel_niet (wat er net niet bij hoort en bij welk type dat wel hoort, of een lege tekst). Met een hoofdgroep erbij wordt het type meteen aangemaakt. Stel daarom een soort voor waar een koper binnen wisselt, geen merk, smaak of los artikel, en gebruik de naam die het meest voor de hand ligt, in het meervoud als de lijst dat bij zulke types ook doet. Twijfel je of het een eigen type verdient of toch bij een bestaand type hoort, laat voorstel_hoofdgroep dan leeg: het voorstel wacht dan op de beheerder. Zonder voorstel zijn deze drie een lege tekst.
- zekerheid: "hoog" als het er zonder twijfel bij hoort, "middel" als het waarschijnlijk klopt, "laag" bij echte twijfel over een variant. Bij "${GEEN}" zegt de zekerheid hoe zeker je bent dat geen type past.
- reden: één korte zin in het Nederlands.

Geef voor elk artikel precies één oordeel, met het nummer van het artikel.`;

type Soort = { id: string; naam: string; hoofdgroep: string; valt_eronder: string | null; valt_er_niet_onder: string | null };
type Artikel = { supermarket: string; article_id: string; titel: string; merk: string | null; inhoud: string | null; categorie: string | null };
type Rij = { supermarket: string; article_id: string; type_id: string | null; variant: string | null; suggested_type: string | null; suggested_group: string | null; suggested_scope: string | null; suggested_excludes: string | null; confidence: string; reason: string };

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

function artikelRegel(nr: number, a: Artikel) {
  const delen = [`${nr}. ${a.titel}`];
  if (a.merk) delen.push(`merk: ${a.merk}`);
  if (a.inhoud) delen.push(`inhoud: ${a.inhoud}`);
  if (a.categorie) delen.push(`categorie: ${a.categorie}`);
  return delen.join(" | ");
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
  const { data: werk, error: leesFout } = await db.rpc("article_type_work", { p_limit: PORTIE * TEGELIJK });
  if (leesFout) {
    console.error("article_type_work mislukt:", leesFout.message);
    return antwoord({ fout: "Lezen mislukt: " + leesFout.message }, 500);
  }
  const types: Soort[] = werk.types ?? [];
  const artikelen: Artikel[] = werk.artikelen ?? [];
  if (types.length === 0) return antwoord({ fout: "Er zijn nog geen producttypes; laad eerst de typelijst." }, 409);
  if (artikelen.length === 0) return antwoord({ beoordeeld: 0, met_type: 0, geen_type: 0, variant: 0, ongeldig: 0, mislukt: 0, nog: 0, nieuwe_types: 0 });

  // Twee types met dezelfde naam kunnen niet voorkomen (unieke sleutel), dus de naam wijst het type aan
  const perNaam = new Map(types.map((t) => [t.naam, t]));
  // Een nieuw type komt in een hoofdgroep die al bestaat; wat geen boodschap is krijgt nooit vanzelf een type
  const hoofdgroepen = [...new Set(types.map((t) => t.hoofdgroep))].filter((g) => g !== "Geen boodschappen");
  const schema = {
    type: "object",
    properties: {
      oordelen: {
        type: "array",
        items: {
          type: "object",
          properties: {
            artikel: { type: "integer", description: "Het nummer van het artikel in het bericht" },
            type: { type: "string", enum: [GEEN, ...perNaam.keys()], description: "De naam van het type, letterlijk uit de lijst" },
            variant: { type: "string", description: "De smaak of soort binnen het type in één woord, anders leeg" },
            voorstel: { type: "string", description: `Alleen bij "${GEEN}": het type dat in de lijst ontbreekt, anders leeg` },
            voorstel_hoofdgroep: { type: "string", enum: ["", ...hoofdgroepen], description: "Bij een voorstel: de hoofdgroep van het nieuwe type, anders leeg" },
            voorstel_eronder: { type: "string", description: "Bij een voorstel: wat er onder het nieuwe type valt, anders leeg" },
            voorstel_niet: { type: "string", description: "Bij een voorstel: wat er net niet onder valt en waar dat hoort, anders leeg" },
            zekerheid: { type: "string", enum: Object.keys(ZEKERHEID) },
            reden: { type: "string" },
          },
          required: ["artikel", "type", "variant", "voorstel", "voorstel_hoofdgroep", "voorstel_eronder", "voorstel_niet", "zekerheid", "reden"],
          additionalProperties: false,
        },
      },
    },
    required: ["oordelen"],
    additionalProperties: false,
  };
  const systeem = INSTRUCTIES + "\n\n# Producttypes\n" + typesTekst(types);
  const claude = new Anthropic({ apiKey: apiSleutel });

  // Eén portie naar de AI; geeft de geldige oordelen terug
  async function beoordeel(portie: Artikel[]): Promise<Rij[]> {
    const bericht = await claude.beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      // Weigert het model onterecht, dan probeert de API het zelf opnieuw met een ander model
      betas: ["server-side-fallback-2026-07-01"],
      // @ts-ignore: de "default"-vorm staat nog niet in alle versies van de SDK-types
      fallbacks: "default",
      output_config: { effort: "low", format: { type: "json_schema", schema } },
      system: [{ type: "text", text: systeem, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: "Artikelen:\n" + portie.map((a, i) => artikelRegel(i + 1, a)).join("\n") }],
    });
    if (bericht.stop_reason !== "end_turn") throw new Error(`de AI stopte met "${bericht.stop_reason}"`);
    const tekst = bericht.content.find((blok) => blok.type === "text");
    const uit = JSON.parse(tekst && tekst.type === "text" ? tekst.text : "{}");
    const rijen: Rij[] = [];
    const gezien = new Set<number>();
    for (const o of Array.isArray(uit.oordelen) ? uit.oordelen : []) {
      const nr = o?.artikel;
      if (!Number.isInteger(nr) || nr < 1 || nr > portie.length || gezien.has(nr) || !(o.zekerheid in ZEKERHEID)) continue;
      const soort = o.type === GEEN ? null : perNaam.get(o.type);
      // Een naam buiten de lijst: het artikel blijft onbeoordeeld
      if (soort === undefined) continue;
      gezien.add(nr);
      const a = portie[nr - 1];
      rijen.push({
        supermarket: a.supermarket,
        article_id: a.article_id,
        type_id: soort ? soort.id : null,
        variant: soort ? String(o.variant ?? "").trim().toLowerCase() || null : null,
        suggested_type: soort ? null : String(o.voorstel ?? "").trim().toLowerCase() || null,
        suggested_group: soort ? null : String(o.voorstel_hoofdgroep ?? "").trim() || null,
        suggested_scope: soort ? null : String(o.voorstel_eronder ?? "").trim() || null,
        suggested_excludes: soort ? null : String(o.voorstel_niet ?? "").trim() || null,
        confidence: ZEKERHEID[o.zekerheid],
        reason: String(o.reden ?? "").trim(),
      });
    }
    return rijen;
  }

  const porties: Artikel[][] = [];
  for (let i = 0; i < artikelen.length; i += PORTIE) porties.push(artikelen.slice(i, i + PORTIE));
  const uitkomsten = await Promise.allSettled(porties.map(beoordeel));
  const rijen: Rij[] = [];
  let mislukt = 0;
  let melding = "";
  uitkomsten.forEach((u, i) => {
    if (u.status === "fulfilled") {
      rijen.push(...u.value);
    } else {
      mislukt += porties[i].length;
      melding = u.reason instanceof Error ? u.reason.message : String(u.reason);
      console.error("Portie mislukt:", u.reason);
    }
  });
  // Niets gelukt: laat het script stoppen met de melding van de AI in plaats van eindeloos opnieuw te vragen
  if (rijen.length === 0) return antwoord({ fout: "Beoordelen mislukt: " + (melding || "geen bruikbaar oordeel") }, 502);

  const { data: telling, error: schrijfFout } = await db.rpc("save_article_types", { p_rows: rijen, p_judged_at: werk.gelezen_op });
  if (schrijfFout) {
    console.error("save_article_types mislukt:", schrijfFout.message);
    return antwoord({ fout: "Opslaan mislukt: " + schrijfFout.message }, 500);
  }
  // variant: artikelen die al een type hadden en nu alleen een variant kregen
  const opgeslagen = telling.met_type + telling.geen_type + (telling.variant ?? 0);
  return antwoord({
    beoordeeld: opgeslagen,
    met_type: telling.met_type,
    nieuwe_types: telling.nieuwe_types ?? 0,
    geen_type: telling.geen_type,
    variant: telling.variant ?? 0,
    // Artikelen zonder bruikbaar oordeel en artikelen in een mislukte portie blijven onbeoordeeld
    ongeldig: artikelen.length - mislukt - rijen.length,
    mislukt,
    // Na een nieuw type wachten er weer artikelen: het artikel zelf op zijn variant, en wat geen type had op een
    // nieuw oordeel. De volgende aanroep telt ze precies.
    nog: (telling.nieuwe_types ?? 0) > 0 ? Math.max(1, werk.nog - opgeslagen) : werk.nog - opgeslagen,
  });
});
