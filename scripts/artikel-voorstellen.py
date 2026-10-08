#!/usr/bin/env python3
"""Stelt per artikel uit de aanbiedingen voor bij welk bestaand product het hoort (roadmap stap 5, niveau 2).

Niveau 1 kent alleen artikelen die op een eigen bon staan. Dit script beoordeelt de rest: artikelen zonder
status, en artikelen met "geen product" als er sindsdien producten zijn bijgekomen (alleen tegen die nieuwe).
Eerst een vaste regel: is de subcategorie van het artikel gelijk aan de naam van een product, dan is dat het
voorstel, met zekerheid hoog, behalve als de titel een variant als zero of decaf noemt. De rest gaat in porties naar de AI, met docs/productregels.md en de
kandidaat-producten erbij. Er wordt niets goedgekeurd: dat doet de beheerder in het scherm Producten.

Daarnaast krijgt elk artikel hooguit drie lijstnamen: de namen die iemand op een boodschappenlijst zou typen
("AH Andijvie fijngesneden 500 gram" wordt "andijvie"). Daarmee krijgt een item op de lijst het Bonus-label
zonder dat het product al bestaat of iets is goedgekeurd. Er worden geen producten voor aangemaakt.

Lezen en schrijven gaat alleen via article_link_work, save_article_proposals en save_article_names, die de
beheerdersrol controleren. Naar de AI gaan alleen productnamen en artikelgegevens, geen aankopen of gebruikers.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/artikel-voorstellen.py             proef: beoordeelt en telt, schrijft niets
  python3 scripts/artikel-voorstellen.py --max 100   proef met de eerste 100 artikelen (goedkoper)
  python3 scripts/artikel-voorstellen.py --echt      slaat de voorstellen op

Ook de proef roept de AI aan, anders valt er niets te tellen. Alle oordelen van de ronde komen in
data/artikel-voorstellen.json, om na te lezen. Je logt in met het e-mailadres en wachtwoord
van de beheerder. ANTHROPIC_API_KEY komt uit de omgeving of uit .env; zet hem nooit in de code.
"""
import getpass
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# De naam ah-importeren.py heeft een streepje en is dus niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)

REGELS = importeren.HOOFDMAP / "docs" / "productregels.md"
# Alle oordelen van de laatste ronde, om na te lezen (data/ staat niet in git)
UITVOER = importeren.HOOFDMAP / "data" / "artikel-voorstellen.json"
MODEL = "claude-opus-5-5"
# Zoveel artikelen per aanroep van de AI
PORTIE = 40
# Zoveel voorbeelden per soort in de telling
VOORBEELDEN = 5
ZEKERHEID = {"hoog": "high", "middel": "medium", "laag": "low"}
# Zoveel lijstnamen per artikel, gelijk aan de grens in save_article_names
NAMEN_MAX = 3
# Wat de AI als product teruggeeft als het artikel bij geen enkel kandidaat-product hoort
GEEN = "geen product"
# Titels waarbij de vaste regel niet geldt: een variant waar je niet tussen wisselt, of een starterset.
# De supermarkt zet die vaak in dezelfde subcategorie ("Fanta Orange zero sugar" onder "Sinas"); de AI beslist.
GEEN_VASTE_REGEL = re.compile(r"\b(zero|light|decaf|alcoholvrij|suikervrij|starterset|starterkit)\b|(?<![\d.,])0[.,]0(?![\d])|(?<![\d.,])0 ?%", re.I)

OPDRACHT = """Je koppelt artikelen van een supermarkt aan de producten van een boodschappen-app. Een product is het niveau waarop een koper wisselt bij een aanbieding. Als een artikel in de aanbieding is, wil de app dat laten zien bij het product waar het bij hoort.

Kies per artikel het ene kandidaat-product waar het volgens de productregels bij hoort, of "geen product" als het bij geen enkel kandidaat-product hoort. Neem de naam van het product letterlijk over uit de lijst.

- Toets: zou iemand die dit product koopt bij een aanbieding dit artikel in plaats daarvan kopen? Zo ja, dan hoort het erbij, ook als het een ander merk, formaat, een andere smaak of biologisch is.
- Kijk naar wat het artikel is, niet naar losse woorden. Een woord uit de productnaam in de titel is geen bewijs: pompoensoep is geen pompoen, brood met pompoen is geen pompoen, douchegel met avocado is geen avocado, thee met honing is geen honing. De categorie van de supermarkt helpt daarbij.
- Staat het passende product niet in de lijst, geef dan "geen product". Kies geen product dat alleen in de buurt komt. De meeste artikelen horen bij geen enkel kandidaat-product.
- Staat achter een artikel "niet:" met productnamen, dan zijn die producten voor dat artikel al afgewezen. Kies ze niet.
- zekerheid: "hoog" als het er zonder twijfel bij hoort, "middel" als het waarschijnlijk klopt, "laag" bij echte twijfel over een variant van hetzelfde soort product, waarvan onduidelijk is of je ertussen wisselt. Bij "geen product" zegt de zekerheid hoe zeker je bent dat geen product past.
- "laag" is geen vangnet. Komt een artikel alleen in de buurt van een product (hetzelfde merk, dezelfde afdeling, een woord gemeen, iets wat erop lijkt), geef dan "geen product": een vanillestokje van Verstegen is geen "kruiden", een appelkruimelkoek is geen "appelkruimelgebak".
- reden: één korte zin in het Nederlands.

Geef daarnaast per artikel de lijstnamen: de namen die iemand op een boodschappenlijst zou typen om dit artikel te kopen. Minstens één en hooguit drie, van algemeen naar specifiek.

- De eerste naam is het product volgens de productregels, het niveau waarop je wisselt bij een aanbieding: "pizza" voor elke pizza, "kwark" voor elke kwark, "kipfilet" voor kipfiletreepjes, "andijvie" voor fijngesneden andijvie. Varianten waar je niet tussen wisselt krijgen hun eigen naam: "cola zero" is niet "cola", "halfvolle melk" is niet "melk".
- Daarna, alleen als mensen dat ook zo opschrijven, een of twee specifiekere namen of een gangbaar synoniem: "magere kwark", "pizza margherita", "baguette" naast "stokbrood".
- Schrijf zoals mensen het op een lijst zetten: kleine letters, meervoud waar dat gebruikelijk is ("eieren", "tomaten", "bananen", "crackers"), enkelvoud waar dat gebruikelijk is ("komkommer", "kipfilet", "melk").
- Zonder merk, huismerk, inhoud of verpakking. Een merk alleen als mensen het product zo noemen ("nutella").
- De lijstnamen staan los van de kandidaat-producten: geef ze ook bij "geen product", en neem de naam van een kandidaat-product alleen over als mensen het zo zouden typen.

Geef voor elk artikel precies één oordeel, met het nummer van het artikel."""

def maak_schema(namen):
    """De vaste uitvoer. Het product is een van de kandidaatnamen (of GEEN), zodat de AI geen product kan
    teruggeven dat niet bestaat. Eerder ging dit met nummers; toen koos de AI geregeld het product ernaast
    ("spekreepjes" werd "sperziebonen")."""
    return {
        "type": "object",
        "properties": {
            "oordelen": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "artikel": {"type": "integer", "description": "Het nummer van het artikel in het bericht"},
                        "product": {"type": "string", "enum": [GEEN] + namen,
                                    "description": "De naam van het kandidaat-product, letterlijk uit de lijst"},
                        "zekerheid": {"type": "string", "enum": list(ZEKERHEID)},
                        "reden": {"type": "string"},
                        "lijstnamen": {"type": "array", "items": {"type": "string"},
                                       "description": "Een tot drie namen zoals op een boodschappenlijst, van algemeen naar specifiek"},
                    },
                    "required": ["artikel", "product", "zekerheid", "reden", "lijstnamen"],
                    "additionalProperties": False,
                },
            },
        },
        "required": ["oordelen"],
        "additionalProperties": False,
    }


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


def vraag_ai(sleutel, systeem, bericht, schema):
    """Eén aanroep van de Claude API met vaste uitvoer. Geeft (oordelen, verbruik) terug."""
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 8000,
        "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": schema}},
        # De opdracht, de regels en de kandidaten zijn voor elke portie gelijk en komen na de eerste uit de cache
        "system": [{"type": "text", "text": systeem, "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": bericht}],
    }).encode()
    kop = {"x-api-key": sleutel, "anthropic-version": "2023-06-01", "content-type": "application/json"}
    for poging in range(4):
        verzoek = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, headers=kop)
        try:
            with urllib.request.urlopen(verzoek, timeout=300) as antwoord:
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
        except urllib.error.URLError as fout:
            if poging < 3:
                time.sleep(10 * (poging + 1))
                continue
            raise RuntimeError(str(fout.reason)) from None
    if uit.get("stop_reason") != "end_turn":
        raise RuntimeError(f"de AI stopte met \"{uit.get('stop_reason')}\"")
    tekst = next((blok["text"] for blok in uit.get("content", []) if blok.get("type") == "text"), "{}")
    return json.loads(tekst).get("oordelen", []), uit.get("usage", {})


def artikel_regel(nr, artikel, per_id):
    """Eén artikel voor het bericht aan de AI: titel, merk, inhoud, categorie en de afgewezen producten."""
    delen = [f"{nr}. {artikel['titel']}"]
    for kop, veld in (("merk", "merk"), ("inhoud", "inhoud"), ("categorie", "categorie")):
        if artikel.get(veld):
            delen.append(f"{kop}: {artikel[veld]}")
    niet = sorted(per_id[p]["naam"] for p in artikel["afgewezen"] if p in per_id)
    if niet:
        delen.append("niet: " + ", ".join(niet))
    return " | ".join(delen)


def oordeel(artikel, product, zekerheid, reden, bron, namen):
    return {"artikel": artikel, "product": product, "zekerheid": zekerheid, "reden": reden, "bron": bron, "namen": namen}


def nette_namen(namen):
    """De lijstnamen van de AI: kleine letters, zonder dubbele, hooguit NAMEN_MAX."""
    netjes = []
    for naam in namen if isinstance(namen, list) else []:
        naam = " ".join(str(naam).lower().split())
        if naam and len(naam) <= 60 and naam not in netjes:
            netjes.append(naam)
    return netjes[:NAMEN_MAX]


def als_rij(o):
    """Een oordeel in de vorm die save_article_proposals verwacht."""
    return {
        "supermarket": o["artikel"]["supermarket"], "article_id": o["artikel"]["article_id"],
        "product_id": o["product"]["id"] if o["product"] else None,
        "confidence": ZEKERHEID[o["zekerheid"]], "reason": o["reden"], "source": o["bron"],
    }


def toon(kop, oordelen):
    print(f"\n{kop}: {len(oordelen)}")
    for o in oordelen[:VOORBEELDEN]:
        a = o["artikel"]
        naar = f" → {o['product']['naam']}" if o["product"] else ""
        print(f"  {a['titel']} [{a.get('categorie') or 'geen categorie'}]{naar}: {o['reden']}")
        if a["naam_nodig"]:
            print(f"    op de lijst: {', '.join(o['namen'])}")


def main():
    echt = "--echt" in sys.argv
    maximum = None
    if "--max" in sys.argv:
        try:
            maximum = int(sys.argv[sys.argv.index("--max") + 1])
        except (IndexError, ValueError):
            sys.exit("Geef een aantal na --max, bijvoorbeeld --max 100.")
    sleutel = lees_sleutel()
    if not sleutel:
        sys.exit("ANTHROPIC_API_KEY is niet gezet (in de omgeving of in .env).")
    print("ECHT: de voorstellen worden opgeslagen." if echt else "PROEF: er wordt niets opgeslagen (gebruik --echt om op te slaan).")

    db = importeren.Supabase(*importeren.lees_config())
    try:
        db.login(input("\nE-mailadres van de beheerder: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
        werk = db.rpc("article_link_work")
    except RuntimeError as fout:
        sys.exit(f"Mislukt: {fout}")

    producten = werk["producten"]
    artikelen = werk["artikelen"]
    opnieuw = sum(1 for a in artikelen if a["nieuwe_producten"] is not None)
    alleen_naam = sum(1 for a in artikelen if not a["product_nodig"])
    print(f"{len(artikelen)} artikelen te beoordelen ({opnieuw} opnieuw, tegen nieuwe producten; {alleen_naam} alleen voor de lijstnamen), "
          f"{len(producten)} kandidaat-producten.")
    if maximum is not None:
        artikelen = artikelen[:maximum]
        print(f"Beperkt tot de eerste {len(artikelen)}.")
    if not artikelen:
        print("Niets te doen.")
        return
    if not producten:
        sys.exit("Er zijn geen kandidaat-producten.")

    per_id = {p["id"]: p for p in producten}
    per_zoek = {p["zoek"]: p for p in producten if p["zoek"]}
    oordelen = []
    opgeslagen = {}
    mislukt = ongeldig = 0
    verbruik = {"input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 0}

    def bewaar(nieuw):
        oordelen.extend(nieuw)
        if not echt or not nieuw:
            return
        namen = [{"supermarket": o["artikel"]["supermarket"], "article_id": o["artikel"]["article_id"], "names": o["namen"]}
                 for o in nieuw if o["artikel"]["naam_nodig"] and o["namen"]]
        if namen:
            opgeslagen["namen"] = opgeslagen.get("namen", 0) + db.rpc("save_article_names", p_rows=namen)
        rijen = [als_rij(o) for o in nieuw if o["artikel"]["product_nodig"]]
        if rijen:
            uit = db.rpc("save_article_proposals", p_rows=rijen, p_judged_at=werk["gelezen_op"])
            for soort, aantal in uit.items():
                opgeslagen[soort] = opgeslagen.get(soort, 0) + aantal

    # Vaste regel, vóór de AI: de subcategorie is gelijk aan de productnaam (beide via normalize_search in de database)
    via_regel, voor_ai = [], {}
    for a in artikelen:
        mag = set(per_id) if a["nieuwe_producten"] is None else set(a["nieuwe_producten"]) & set(per_id)
        mag -= set(a["afgewezen"])
        p = per_zoek.get(a["subcategorie_zoek"] or "")
        if a["product_nodig"] and p and p["id"] in mag and not GEEN_VASTE_REGEL.search(a["titel"] or ""):
            sub = (a["categorie"] or "").split("/", 1)[-1]
            # De productnaam is hier ook wat je op de lijst typt; de AI komt er niet aan te pas
            via_regel.append(oordeel(a, p, "hoog", f"De subcategorie \"{sub}\" is gelijk aan de productnaam.", "rule", [p["naam"].lower()]))
        else:
            # Artikelen met dezelfde kandidaten gaan samen in een portie: alle producten, of alleen de nieuwe
            groep = None if a["nieuwe_producten"] is None else tuple(sorted(set(a["nieuwe_producten"]) & set(per_id)))
            voor_ai.setdefault(groep, []).append(a)
    try:
        for i in range(0, len(via_regel), 200):
            bewaar(via_regel[i:i + 200])
    except RuntimeError as fout:
        sys.exit(f"Opslaan mislukt: {fout}")

    regels_tekst = REGELS.read_text()
    porties = sum(-(-len(lijst) // PORTIE) for lijst in voor_ai.values())
    print(f"{len(via_regel)} via de vaste regel, {len(artikelen) - len(via_regel)} naar de AI in {porties} porties.")
    nr_portie = 0
    for groep, lijst in voor_ai.items():
        kandidaten = producten if groep is None else [per_id[p] for p in groep]
        if not kandidaten:
            continue
        # Twee producten met dezelfde naam zijn niet uit elkaar te houden; die doen niet mee
        telling = {}
        for p in kandidaten:
            telling[p["naam"]] = telling.get(p["naam"], 0) + 1
        per_naam = {p["naam"]: p for p in kandidaten if telling[p["naam"]] == 1 and p["naam"] != GEEN}
        if not per_naam:
            continue
        schema = maak_schema(list(per_naam))
        systeem = (OPDRACHT + "\n\n" + regels_tekst + "\n\n# Kandidaat-producten\n\n"
                   + "\n".join(f"- {naam}" for naam in per_naam))
        for i in range(0, len(lijst), PORTIE):
            portie = lijst[i:i + PORTIE]
            nr_portie += 1
            bericht = "Artikelen:\n" + "\n".join(artikel_regel(n, a, per_id) for n, a in enumerate(portie, 1))
            try:
                antwoord, gebruikt = vraag_ai(sleutel, systeem, bericht, schema)
                for soort in verbruik:
                    verbruik[soort] += gebruikt.get(soort) or 0
                nieuw, gezien = [], set()
                for o in antwoord:
                    nr, naam = o.get("artikel"), o.get("product")
                    if not isinstance(nr, int) or not 1 <= nr <= len(portie) or nr in gezien or o.get("zekerheid") not in ZEKERHEID:
                        continue
                    a = portie[nr - 1]
                    namen = nette_namen(o.get("lijstnamen"))
                    if a["naam_nodig"] and not namen:
                        continue
                    if naam == GEEN or not a["product_nodig"]:
                        # Staat het artikel al op een bon of heeft het al een oordeel, dan gaat het alleen om de namen
                        product = None
                    elif naam in per_naam and per_naam[naam]["id"] not in a["afgewezen"]:
                        product = per_naam[naam]
                    else:
                        # Een naam buiten de lijst of een afgewezen combinatie: het artikel blijft onbeoordeeld
                        continue
                    gezien.add(nr)
                    nieuw.append(oordeel(a, product, o["zekerheid"], str(o.get("reden") or "").strip(), "ai", namen))
                ongeldig += len(portie) - len(nieuw)
                bewaar(nieuw)
            except (RuntimeError, ValueError) as fout:
                mislukt += len(portie)
                print(f"Portie {nr_portie} mislukt: {fout}")
            if nr_portie % 5 == 0:
                print(f"  {nr_portie} van {porties} porties")

    # Alles in een bestand, ook "geen product": de telling hieronder toont maar een paar voorbeelden
    UITVOER.parent.mkdir(exist_ok=True)
    UITVOER.write_text(json.dumps([{
        "titel": o["artikel"]["titel"], "merk": o["artikel"].get("merk"), "inhoud": o["artikel"].get("inhoud"),
        "categorie": o["artikel"].get("categorie"), "product": o["product"]["naam"] if o["product"] else None,
        "zekerheid": o["zekerheid"], "reden": o["reden"], "bron": o["bron"],
        "lijstnamen": o["namen"], "alleen_naam": not o["artikel"]["product_nodig"],
    } for o in oordelen], ensure_ascii=False, indent=1))

    met_oordeel = [o for o in oordelen if o["artikel"]["product_nodig"]]
    voorstellen = [o for o in met_oordeel if o["product"]]
    print(f"\n{len(oordelen)} artikelen beoordeeld, {len(voorstellen)} voorstellen.")
    toon("Voorstellen via de vaste regel (zekerheid hoog)", [o for o in voorstellen if o["bron"] == "rule"])
    for zekerheid in ZEKERHEID:
        toon(f"Voorstellen van de AI met zekerheid {zekerheid}", [o for o in voorstellen if o["bron"] == "ai" and o["zekerheid"] == zekerheid])
    toon("Geen product", [o for o in met_oordeel if not o["product"]])
    toon("Alleen lijstnamen (artikel staat op een bon of had al een oordeel)", [o for o in oordelen if not o["artikel"]["product_nodig"]])
    if ongeldig or mislukt:
        print(f"\n{ongeldig} artikelen kregen geen bruikbaar oordeel en {mislukt} zaten in een mislukte portie; die blijven onbeoordeeld.")
    print(f"\nAlle oordelen staan in {UITVOER.relative_to(importeren.HOOFDMAP)}.")
    print(f"\nVerbruik: {verbruik['input_tokens'] + verbruik['cache_creation_input_tokens']} tokens invoer, "
          f"{verbruik['cache_read_input_tokens']} uit de cache, {verbruik['output_tokens']} uitvoer.")
    if echt:
        print(f"Lijstnamen opgeslagen bij {opgeslagen.get('namen', 0)} artikelen.")
        print(f"Opgeslagen: {opgeslagen.get('voorstellen', 0)} voorstellen en {opgeslagen.get('geen_product', 0)} keer geen product. "
              f"Overgeslagen: {opgeslagen.get('op_bon', 0)} op een bon, {opgeslagen.get('bestaand', 0)} met een bestaand voorstel, "
              f"{opgeslagen.get('afgewezen', 0)} afgewezen combinaties, {opgeslagen.get('onbekend', 0)} onbekend.")
        print("Keur de voorstellen goed in de app: Profiel > Producten beheren.")
    else:
        print("PROEF: er is niets opgeslagen.")


if __name__ == "__main__":
    main()
