#!/usr/bin/env python3
"""Laat de AI een lijst producttypes voorstellen, op basis van de huidige catalogus en de aanbiedingen.

Een producttype is het niveau waarop een koper wisselt bij een aanbieding (docs/productregels.md): "brood",
"pizza", "cola zero". De hoofdgroep is de hoofdcategorie van de supermarkt. De lijst vervangt later de
catalogus met samenvoegen; dit script doet alleen het voorstel.

In drie rondes:
  1. per hoofdgroep: de subcategorieën met voorbeeldartikelen, de lijstnamen en de catalogusproducten die
     daar volgens de bon of een goedgekeurde koppeling bij horen;
  2. de catalogusproducten zonder artikel: bij een type uit ronde 1, of een nieuw type;
  3. dubbele types over de hoofdgroepen heen samennemen.

Ronde 1 vult elke hoofdgroep aan met gangbare types waar nog geen artikel of catalogusproduct bij hoort;
die staan in het bestand als "toegevoegd zonder artikel". Ronde 2 geeft per catalogusproduct een zekerheid;
data/producttypes-nalezen.csv zet die koppelingen onder elkaar, de laagste zekerheid bovenaan.

Het script schrijft niets naar de database. Het resultaat komt in docs/producttypes.csv, dat de beheerder
naleest en bewerkt; daarna zet scripts/producttypes-laden.py de lijst in de database. Lezen gaat via
type_proposal_work, die de beheerdersrol controleert. Naar de AI gaan alleen productnamen, artikelgegevens
en losse termen, geen aankopen of gebruikers.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/producttypes-voorstellen.py                  de hele lijst
  python3 scripts/producttypes-voorstellen.py --groep Kaas     proef met één hoofdgroep (goedkoop), alleen ronde 1
  python3 scripts/producttypes-voorstellen.py --overschrijven  ook als docs/producttypes.csv al bestaat

Een proef met --groep komt in data/producttypes-proef.csv. Een koppeling uit het nalees-overzicht verbeter je
door de naam in docs/producttypes.csv naar de kolom bronproducten van het goede type te verplaatsen. Je logt in met het e-mailadres en wachtwoord van
de beheerder. ANTHROPIC_API_KEY komt uit de omgeving of uit .env; zet hem nooit in de code.
"""
import csv
import getpass
import importlib.util
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path

# De naam ah-importeren.py heeft een streepje en is dus niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)

REGELS = importeren.HOOFDMAP / "docs" / "productregels.md"
UITVOER = importeren.HOOFDMAP / "docs" / "producttypes.csv"
PROEF = importeren.HOOFDMAP / "data" / "producttypes-proef.csv"
# De koppelingen van ronde 2 om na te lezen, de laagste zekerheid bovenaan (data/ staat niet in git)
NALEZEN = importeren.HOOFDMAP / "data" / "producttypes-nalezen.csv"
MODEL = "claude-opus-5-5"
# De kolommen van het bestand; scripts/producttypes-laden.py leest dezelfde
KOLOMMEN = ["hoofdgroep", "type", "valt eronder", "valt er niet onder", "telt mee", "toegevoegd zonder artikel", "bronproducten"]
# Volgorde van het nalees-overzicht
ZEKERHEID = ["laag", "middel", "hoog"]
# Scheidt de bronproducten in één cel
TUSSEN = " | "
# De hoofdgroep voor wat geen boodschap is (draagtas, kleding); telt niet mee in het profiel
GEEN_BOODSCHAPPEN = "Geen boodschappen"
# Zoveel namen van een catalogusproduct gaan hooguit mee naar de AI
NAMEN_MAX = 12
# Zoveel catalogusproducten per aanroep in ronde 2
PORTIE = 120

OPDRACHT = """Je stelt de vaste lijst producttypes op voor een boodschappen-app. Aan een type worden later automatisch artikelen van de supermarkt, getypte boodschappen en aankopen gekoppeld. Het aankoopprofiel rekent per type, en een aanbieding op een artikel van een type wordt getoond aan wie dat type koopt of op zijn lijst heeft.

Een type is het niveau waarop een koper wisselt bij een aanbieding, precies zoals "product" in de productregels hieronder. Toets: zou je bij een aanbieding het ene voor het andere kopen? Dan is het één type.

- Naam: zoals iemand het op een boodschappenlijst zet. Kleine letters, zonder merk, huismerk, inhoud of verpakking; meervoud waar dat gebruikelijk is ("eieren", "tomaten"), enkelvoud waar dat gebruikelijk is ("komkommer", "melk"). Een merk alleen als mensen het product zo noemen.
- De vastgestelde producten uit de productregels zijn types, met precies die naam en die afbakening.
- Merken, smaken, formaten, verpakkingen, rassen en biologisch horen bij hetzelfde type. Varianten waar je niet tussen wisselt zijn een eigen type: zero, light, suikervrij, 0%, decaf en alcoholvrij; halfvolle en volle melk; vers tegenover gedroogd of uit pot of blik; producten die alleen in een eigen apparaat of systeem werken.
- Niet te fijn en niet te grof. "tandpasta" is één type, niet per merk of werking. "Drogisterij" of "verzorging" is geen type. Een subcategorie van de supermarkt is vaak één type, soms meerdere, en soms horen meerdere subcategorieën bij één type. De indeling van de supermarkt helpt, maar is geen bewijs: wat de artikelen zijn gaat voor.
- valt_eronder: één korte zin over wat erbij hoort, met een paar voorbeelden. valt_er_niet_onder: wat er net niet bij hoort, met het type waar het wel hoort; leeg als er niets te verwarren valt.
- telt_mee: false voor wat geen boodschap is (draagtas, statiegeld, kleding, wenskaart). Anders true.
- bronproducten: de catalogusproducten uit het bericht die in dit type opgaan, met hun naam letterlijk overgenomen. Elk catalogusproduct hoort bij precies één type. De catalogus is met de hand samengesteld en nagelezen: wat daar één product is blijft samen, en wat daar apart staat blijft apart, tenzij de productregels iets anders zeggen. Een catalogusproduct met een merk in de naam gaat op in het type van de soort; de naam van het type is dan de soort, nooit het merk ("clemont rouge" gaat op in een type dat naar de soort kaas heet)."""

RONDE1 = """Stel de types op voor de hoofdgroep "{groep}". Hieronder staan de subcategorieën van de supermarkt met het aantal artikelen, voorbeeldtitels en de namen die er op een boodschappenlijst voor gebruikt worden (met het aantal artikelen), en daarna de catalogusproducten die bij deze hoofdgroep horen (met het aantal aankopen en hun andere namen).

Dek alle subcategorieën en alle catalogusproducten.

Vul de hoofdgroep daarna aan met de gangbare types die elke supermarkt in deze hoofdgroep verkoopt en waar hierboven nog geen artikel of catalogusproduct bij hoort (de artikelen zijn alleen wat de laatste weken in de aanbieding was). Op hetzelfde wisselniveau als de rest, en alleen wat veel huishoudens kopen, geen niche. Zet bij die types zonder_artikel op true en bronproducten leeg; bij alle andere zonder_artikel op false. Voeg geen type toe dat overlapt met een type dat je al hebt: valt het onder de afbakening van een bestaand type, dan is het geen nieuw type."""

RONDE2 = """Hieronder staan catalogusproducten waar nog geen type voor is, met het aantal aankopen en hun andere namen, en daarna de types die er al zijn, per hoofdgroep.

Geef voor elk catalogusproduct het type waar het in opgaat. Past een bestaand type, neem dan die naam letterlijk over en zet nieuw op false; hoofdgroep, valt_eronder en valt_er_niet_onder tellen dan niet. Past er geen, geef dan een nieuw type met nieuw op true, in de hoofdgroep waar de supermarkt het zou zetten. Meerdere catalogusproducten kunnen in hetzelfde nieuwe type opgaan: gebruik dan steeds exact dezelfde naam. Wat geen boodschap is komt in de hoofdgroep "{geen}".

Je hebt alleen de namen, geen artikelen. zekerheid: "hoog" als de naam zonder twijfel dit type is, "middel" als het waarschijnlijk klopt, "laag" als de naam onduidelijk is, meerdere dingen kan betekenen of het wisselniveau twijfelachtig is. reden: één korte zin."""

RONDE3 = """Hieronder staan alle types, per hoofdgroep. Ze zijn per hoofdgroep los van elkaar opgesteld, dus hetzelfde type kan onder twee namen of in twee hoofdgroepen voorkomen ("ijsthee" en "ice tea", "vaatwastabletten" en "vaatwastabs").

Noem de types die volgens de productregels hetzelfde type zijn: welk type blijft (houden) en welke daarin opgaan (vervalt), met de namen letterlijk overgenomen. Alleen bij hetzelfde wisselniveau; varianten waar je niet tussen wisselt blijven apart. Zijn er geen dubbele, geef dan een lege lijst."""

TYPE_VELDEN = {
    "naam": {"type": "string", "description": "De naam van het type, zoals op een boodschappenlijst"},
    "valt_eronder": {"type": "string"},
    "valt_er_niet_onder": {"type": "string"},
    "telt_mee": {"type": "boolean"},
}
SCHEMA1 = {
    "type": "object",
    "properties": {"types": {"type": "array", "items": {
        "type": "object",
        "properties": {**TYPE_VELDEN, "zonder_artikel": {"type": "boolean"},
                       "bronproducten": {"type": "array", "items": {"type": "string"}}},
        "required": ["naam", "valt_eronder", "valt_er_niet_onder", "telt_mee", "zonder_artikel", "bronproducten"],
        "additionalProperties": False,
    }}},
    "required": ["types"],
    "additionalProperties": False,
}
SCHEMA3 = {
    "type": "object",
    "properties": {"dubbel": {"type": "array", "items": {
        "type": "object",
        "properties": {"houden": {"type": "string"}, "vervalt": {"type": "array", "items": {"type": "string"}},
                       "reden": {"type": "string"}},
        "required": ["houden", "vervalt", "reden"],
        "additionalProperties": False,
    }}},
    "required": ["dubbel"],
    "additionalProperties": False,
}


def schema2(groepen):
    return {
        "type": "object",
        "properties": {"toewijzingen": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "product": {"type": "integer", "description": "Het nummer van het catalogusproduct in het bericht"},
                "nieuw": {"type": "boolean"},
                "hoofdgroep": {"type": "string", "enum": groepen},
                **TYPE_VELDEN,
                "zekerheid": {"type": "string", "enum": ZEKERHEID},
                "reden": {"type": "string"},
            },
            "required": ["product", "nieuw", "hoofdgroep", "naam", "valt_eronder", "valt_er_niet_onder", "telt_mee",
                         "zekerheid", "reden"],
            "additionalProperties": False,
        }}},
        "required": ["toewijzingen"],
        "additionalProperties": False,
    }


def sleutel_van(naam):
    """De naam in sleutelvorm, zoals match_key in de database: kleine letters, zonder accenten, alleen letters en cijfers."""
    kaal = unicodedata.normalize("NFKD", str(naam)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", kaal)


def lees_sleutel():
    """ANTHROPIC_API_KEY uit de omgeving, anders uit .env in de hoofdmap."""
    sleutel = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    bestand = importeren.HOOFDMAP / ".env"
    if not sleutel and bestand.exists():
        for regel in bestand.read_text().splitlines():
            naam, _, waarde = regel.partition("=")
            if naam.strip() == "ANTHROPIC_API_KEY":
                sleutel = waarde.strip().strip("\"'")
    return sleutel


def vraag_ai(sleutel, systeem, bericht, schema, verbruik):
    """Eén aanroep van de Claude API met vaste uitvoer. Geeft het antwoord als dict terug en telt het verbruik op."""
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 32000,
        "output_config": {"effort": "medium", "format": {"type": "json_schema", "schema": schema}},
        # De opdracht en de regels zijn voor elke aanroep gelijk en komen na de eerste uit de cache
        "system": [{"type": "text", "text": systeem, "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": bericht}],
    }).encode()
    kop = {"x-api-key": sleutel, "anthropic-version": "2023-06-01", "content-type": "application/json"}
    for poging in range(4):
        verzoek = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, headers=kop)
        try:
            with urllib.request.urlopen(verzoek, timeout=600) as antwoord:
                uit = json.loads(antwoord.read().decode())
            break
        except urllib.error.HTTPError as fout:
            tekst = fout.read().decode()
            # Te druk of overbelast: even wachten en opnieuw
            if fout.code in (429, 500, 529) and poging < 3:
                time.sleep(10 * (poging + 1))
                continue
            try:
                melding = json.loads(tekst)["error"]["message"]
            except (ValueError, KeyError, TypeError):
                melding = tekst
            raise RuntimeError(f"{fout.code}: {melding}") from None
        except (urllib.error.URLError, TimeoutError) as fout:
            if poging < 3:
                time.sleep(10 * (poging + 1))
                continue
            raise RuntimeError(str(getattr(fout, "reason", fout))) from None
    if uit.get("stop_reason") != "end_turn":
        raise RuntimeError(f"de AI stopte met \"{uit.get('stop_reason')}\"")
    for soort in verbruik:
        verbruik[soort] += uit.get("usage", {}).get(soort) or 0
    tekst = next((blok["text"] for blok in uit.get("content", []) if blok.get("type") == "text"), "{}")
    return json.loads(tekst)


def product_regel(p, nr=None):
    """Eén catalogusproduct voor de AI: naam, aantal aankopen en de andere namen die erin zitten."""
    andere = [n for n in p["namen"] if n != p["naam"].lower()]
    delen = [(f"{nr}. " if nr else "- ") + p["naam"], f"{p['aankopen']} aankopen"]
    if not p["telt_mee"]:
        delen.append("telt niet mee in het profiel")
    if andere:
        meer = f" en {len(andere) - NAMEN_MAX} meer" if len(andere) > NAMEN_MAX else ""
        delen.append("ook: " + ", ".join(andere[:NAMEN_MAX]) + meer)
    return " | ".join(delen)


def groep_bericht(groep, producten):
    regels = [RONDE1.format(groep=groep["naam"]), "", "# Subcategorieën", ""]
    for sub in groep["subcategorieen"]:
        regels.append(f"## {sub['naam'] or 'zonder subcategorie'} ({sub['artikelen']} artikelen)")
        regels.append("Voorbeelden: " + "; ".join(sub["voorbeelden"]))
        if sub["lijstnamen"]:
            regels.append("Op de lijst: " + ", ".join(f"{n['naam']} ({n['artikelen']})" for n in sub["lijstnamen"][:15]))
        regels.append("")
    regels += ["# Catalogusproducten", ""]
    regels += [product_regel(p) for p in producten] or ["Geen."]
    return "\n".join(regels)


def types_tekst(types):
    """Alle types per hoofdgroep, voor ronde 2 en 3."""
    regels = []
    for groep in sorted({t["hoofdgroep"] for t in types}):
        regels.append(f"## {groep}")
        regels += [f"- {t['naam']}: {t['valt_eronder']}" for t in types if t["hoofdgroep"] == groep]
        regels.append("")
    return "\n".join(regels)


def nieuw_type(groep, t):
    return {"hoofdgroep": groep, "naam": " ".join(str(t["naam"]).lower().split()),
            "valt_eronder": str(t.get("valt_eronder") or "").strip(),
            "valt_er_niet_onder": str(t.get("valt_er_niet_onder") or "").strip(),
            "telt_mee": bool(t.get("telt_mee", True)) and groep != GEEN_BOODSCHAPPEN,
            "zonder_artikel": False, "bron": []}


def schrijf(pad, types):
    pad.parent.mkdir(exist_ok=True)
    # utf-8-sig en puntkomma's: zo opent het bestand goed in Numbers en in een Nederlandse Excel
    with pad.open("w", newline="", encoding="utf-8-sig") as bestand:
        uit = csv.writer(bestand, delimiter=";")
        uit.writerow(KOLOMMEN)
        for t in sorted(types, key=lambda t: (t["hoofdgroep"].lower(), t["naam"])):
            uit.writerow([t["hoofdgroep"], t["naam"], t["valt_eronder"], t["valt_er_niet_onder"],
                          "ja" if t["telt_mee"] else "nee", "ja" if t["zonder_artikel"] and not t["bron"] else "",
                          TUSSEN.join(sorted(t["bron"], key=str.lower))])


def schrijf_nalezen(koppelingen, types):
    """De koppelingen van ronde 2, de laagste zekerheid bovenaan en daarbinnen de meeste aankopen eerst."""
    bestaat = {id(t) for t in types}
    NALEZEN.parent.mkdir(exist_ok=True)
    with NALEZEN.open("w", newline="", encoding="utf-8-sig") as bestand:
        uit = csv.writer(bestand, delimiter=";")
        uit.writerow(["zekerheid", "catalogusproduct", "aankopen", "type", "hoofdgroep", "nieuw type", "reden"])
        for k in sorted(koppelingen, key=lambda k: (ZEKERHEID.index(k["zekerheid"]), -k["product"]["aankopen"], k["product"]["naam"])):
            # Is het type in ronde 3 opgegaan in een ander, dan staat hier het type dat bleef
            t = k["type"] if id(k["type"]) in bestaat else next(x for x in types if k["product"]["naam"] in x["bron"])
            uit.writerow([k["zekerheid"], k["product"]["naam"], k["product"]["aankopen"], t["naam"], t["hoofdgroep"],
                          "ja" if k["nieuw"] else "", k["reden"]])


def main():
    alleen = None
    if "--groep" in sys.argv:
        try:
            alleen = sys.argv[sys.argv.index("--groep") + 1]
        except IndexError:
            sys.exit("Geef een hoofdgroep na --groep, bijvoorbeeld --groep Kaas.")
    uitvoer = PROEF if alleen else UITVOER
    if uitvoer == UITVOER and UITVOER.exists() and "--overschrijven" not in sys.argv:
        sys.exit(f"{UITVOER.relative_to(importeren.HOOFDMAP)} bestaat al en is misschien bewerkt. "
                 "Gebruik --overschrijven om een nieuw voorstel te maken.")
    sleutel = lees_sleutel()
    if not sleutel:
        sys.exit("ANTHROPIC_API_KEY is niet gezet (in de omgeving of in .env).")

    db = importeren.Supabase(*importeren.lees_config())
    try:
        db.login(input("E-mailadres van de beheerder: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
        werk = db.rpc("type_proposal_work")
    except RuntimeError as fout:
        sys.exit(f"Mislukt: {fout}")

    groepen = [g for g in werk["hoofdgroepen"] if g["naam"]]
    zonder_groep = [g for g in werk["hoofdgroepen"] if not g["naam"]]
    producten = werk["producten"]
    print(f"{len(groepen)} hoofdgroepen met {sum(g['artikelen'] for g in groepen)} artikelen, "
          f"{len(producten)} catalogusproducten ({sum(1 for p in producten if not p['hoofdgroep'])} zonder artikel), "
          f"{len(werk['termen'])} niet-gematchte termen.")
    if zonder_groep:
        print(f"{zonder_groep[0]['artikelen']} artikelen hebben geen hoofdcategorie; die doen niet mee aan het voorstel.")
    if alleen:
        groepen = [g for g in groepen if g["naam"].lower() == alleen.lower()]
        if not groepen:
            sys.exit(f"De hoofdgroep \"{alleen}\" bestaat niet. Kies uit: " + ", ".join(g["naam"] for g in werk["hoofdgroepen"] if g["naam"]))

    systeem = OPDRACHT + "\n\n" + REGELS.read_text()
    verbruik = {"input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 0}
    types = []          # { hoofdgroep, naam, valt_eronder, valt_er_niet_onder, telt_mee, bron: [productnaam] }
    geplaatst = set()   # namen van catalogusproducten die al in een type zitten
    koppelingen = []    # ronde 2: { product, type, nieuw, zekerheid, reden }
    mislukt = []

    # Ronde 1: per hoofdgroep
    for nr, groep in enumerate(groepen, 1):
        eigen = [p for p in producten if p["hoofdgroep"] == groep["naam"]]
        print(f"  {nr}/{len(groepen)} {groep['naam']}: {len(groep['subcategorieen'])} subcategorieën, {len(eigen)} catalogusproducten")
        try:
            antwoord = vraag_ai(sleutel, systeem, groep_bericht(groep, eigen), SCHEMA1, verbruik)
        except (RuntimeError, ValueError) as fout:
            mislukt.append(groep["naam"])
            print(f"    mislukt: {fout}")
            continue
        namen = {p["naam"] for p in eigen}
        for t in antwoord.get("types", []):
            if not sleutel_van(t.get("naam", "")):
                continue
            nieuw = nieuw_type(groep["naam"], t)
            # Alleen producten uit het bericht, en elk product maar bij één type
            nieuw["bron"] = [b for b in dict.fromkeys(t.get("bronproducten") or []) if b in namen and b not in geplaatst]
            geplaatst.update(nieuw["bron"])
            nieuw["zonder_artikel"] = bool(t.get("zonder_artikel")) and not nieuw["bron"]
            types.append(nieuw)

    # Ronde 2: catalogusproducten die nog nergens in zitten
    rest = [] if alleen else [p for p in producten if p["naam"] not in geplaatst]
    keuze = sorted({g["naam"] for g in groepen} | {GEEN_BOODSCHAPPEN})
    for i in range(0, len(rest), PORTIE):
        portie = rest[i:i + PORTIE]
        print(f"  catalogusproducten zonder type: {i + 1} tot {i + len(portie)} van {len(rest)}")
        bericht = (RONDE2.format(geen=GEEN_BOODSCHAPPEN) + "\n\n# Catalogusproducten\n\n"
                   + "\n".join(product_regel(p, n) for n, p in enumerate(portie, 1))
                   + "\n\n# Bestaande types\n\n" + types_tekst(types))
        try:
            antwoord = vraag_ai(sleutel, systeem, bericht, schema2(keuze), verbruik)
        except (RuntimeError, ValueError) as fout:
            mislukt.append(f"catalogusproducten {i + 1} tot {i + len(portie)}")
            print(f"    mislukt: {fout}")
            continue
        per_sleutel = {sleutel_van(t["naam"]): t for t in types}
        for o in antwoord.get("toewijzingen", []):
            nr = o.get("product")
            if not isinstance(nr, int) or not 1 <= nr <= len(portie) or not sleutel_van(o.get("naam", "")):
                continue
            p = portie[nr - 1]
            if p["naam"] in geplaatst:
                continue
            doel = per_sleutel.get(sleutel_van(o["naam"]))
            nieuw = not doel
            if nieuw:
                doel = nieuw_type(o["hoofdgroep"], o)
                types.append(doel)
                per_sleutel[sleutel_van(doel["naam"])] = doel
            doel["bron"].append(p["naam"])
            koppelingen.append({"product": p, "type": doel, "nieuw": nieuw, "reden": str(o.get("reden") or "").strip(),
                                "zekerheid": o.get("zekerheid") if o.get("zekerheid") in ZEKERHEID else "laag"})
            geplaatst.add(p["naam"])

    # Dezelfde naam in twee hoofdgroepen is zeker dubbel: het type met de meeste bronproducten blijft
    per_sleutel = {}
    for t in sorted(types, key=lambda t: -len(t["bron"])):
        eerste = per_sleutel.setdefault(sleutel_van(t["naam"]), t)
        if eerste is not t:
            eerste["bron"] += t["bron"]
            print(f"  dubbel: \"{t['naam']}\" stond in {eerste['hoofdgroep']} en {t['hoofdgroep']}; {eerste['hoofdgroep']} blijft")
    types = list(per_sleutel.values())

    # Ronde 3: dubbele types onder een andere naam
    if not alleen and types:
        print("  dubbele types zoeken")
        try:
            antwoord = vraag_ai(sleutel, systeem, RONDE3 + "\n\n" + types_tekst(types), SCHEMA3, verbruik)
            for d in antwoord.get("dubbel", []):
                houden = per_sleutel.get(sleutel_van(d.get("houden", "")))
                for naam in d.get("vervalt") or []:
                    weg = per_sleutel.get(sleutel_van(naam))
                    if houden in types and weg in types and weg is not houden:
                        houden["bron"] += weg["bron"]
                        types.remove(weg)
                        print(f"  samengenomen: \"{weg['naam']}\" ({weg['hoofdgroep']}) gaat op in \"{houden['naam']}\" ({houden['hoofdgroep']}): {d.get('reden', '')}")
        except (RuntimeError, ValueError) as fout:
            mislukt.append("dubbele types zoeken")
            print(f"    mislukt: {fout}")

    schrijf(uitvoer, types)
    if not alleen:
        schrijf_nalezen(koppelingen, types)
    los = [p["naam"] for p in producten if p["naam"] not in geplaatst]
    print(f"\n{len(types)} types in {len({t['hoofdgroep'] for t in types})} hoofdgroepen, "
          f"{len(geplaatst)} van {len(producten)} catalogusproducten ondergebracht.")
    print(f"{sum(1 for t in types if t['zonder_artikel'] and not t['bron'])} types zijn toegevoegd zonder artikel of catalogusproduct.")
    if koppelingen:
        print("Catalogusproducten zonder artikel: " + ", ".join(
            f"{sum(1 for k in koppelingen if k['zekerheid'] == z)} met zekerheid {z}" for z in ZEKERHEID)
            + f". Lees ze na in {NALEZEN.relative_to(importeren.HOOFDMAP)}, de laagste zekerheid staat bovenaan.")
    if los and not alleen:
        print(f"{len(los)} catalogusproducten zitten in geen enkel type: " + ", ".join(los[:20]) + (" ..." if len(los) > 20 else ""))
    if mislukt:
        print("Mislukt, draai het script opnieuw of vul met de hand aan: " + "; ".join(mislukt))
    print(f"Verbruik: {verbruik['input_tokens'] + verbruik['cache_creation_input_tokens']} tokens invoer, "
          f"{verbruik['cache_read_input_tokens']} uit de cache, {verbruik['output_tokens']} uitvoer.")
    print(f"\nHet voorstel staat in {uitvoer.relative_to(importeren.HOOFDMAP)}. Er is niets in de database gezet.")
    if not alleen:
        print("Lees het na en bewerk het; daarna: python3 scripts/producttypes-laden.py")


if __name__ == "__main__":
    main()
