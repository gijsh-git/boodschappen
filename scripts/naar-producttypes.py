#!/usr/bin/env python3
"""Koppelt de bestaande catalogus aan de producttypes (overstap naar producttypes, fase 3).

Wat er gebeurt:
  1. Catalogusproducten: docs/producttypes.csv zegt in de kolom bronproducten welk product in welk type opgaat.
     Elke naam van zo'n product (product_aliases) wordt een naam van dat type, met bron catalog.
  2. Catalogusproducten die in geen enkel type staan (bewust weggelaten, of bijgekomen na het voorstel)
     beoordeelt de AI: een type uit de lijst, of geen type voor een losse merknaam of een te vage naam. Die
     namen krijgen bron ai, zodat ze later in het beheerscherm na te kijken zijn.
  3. Lijstnamen (article_names): een lijstnaam wordt een naam van een type als alle artikelen met die naam
     hetzelfde type hebben. De rest vervalt.
  4. Artikelen die in de oude catalogus bij een product horen (op een bon, of een goedgekeurde koppeling):
     is het type van dat product gelijk aan het oordeel van de AI, dan geldt het als nagekeken. Bij een
     verschil beslist de kolom keuze in data/producttypes-verschillen.csv ("catalogus" of "ai").

Aankopen hoeven niet omgezet: hun type volgt uit het artikel of de naam. Er zijn nog geen favorieten.
De app merkt hier niets van: tot fase 4 rekent alles nog op de oude catalogus.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/naar-producttypes.py           proef: telt en schrijft de verslagen, niets naar de database
  python3 scripts/naar-producttypes.py --echt    slaat de koppelingen op

Ook de proef roept de AI aan voor stap 2. De verslagen komen in data/ (niet in git):
  producttypes-namen.csv         elke naam met zijn type en bron
  producttypes-verschillen.csv   artikelen waar de catalogus en de AI een ander type geven; pas de kolom
                                 keuze aan en draai opnieuw, je keuzes blijven bewaard
Opnieuw draaien kan altijd. Je logt in met het e-mailadres en wachtwoord van de beheerder.
"""
import csv
import getpass
import importlib.util
import sys
from pathlib import Path


def laad(naam):
    """Een script met een streepje in de naam is niet gewoon te importeren."""
    spec = importlib.util.spec_from_file_location(naam.replace("-", "_"), Path(__file__).with_name(naam + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


laden = laad("producttypes-laden")
voorstellen = laden.voorstellen
importeren = voorstellen.importeren
sleutel_van = voorstellen.sleutel_van

NAMEN = importeren.HOOFDMAP / "data" / "producttypes-namen.csv"
VERSCHILLEN = importeren.HOOFDMAP / "data" / "producttypes-verschillen.csv"
KOLOMMEN_VERSCHIL = ["keuze", "titel", "categorie", "catalogus", "ai", "zekerheid ai", "bron", "supermarkt", "artikel"]
# Wat er gebeurt met een verschil waar nog geen keuze bij staat
KEUZE_STANDAARD = "catalogus"
KEUZES = ("catalogus", "ai")
GEEN = "geen type"
ZEKERHEID = {"hoog": "high", "middel": "medium", "laag": "low"}
BRON = {"receipt": "bon", "catalog": "koppeling"}
# Zoveel catalogusproducten per aanroep van de AI, en zoveel rijen per aanroep van de database
PORTIE = 100
BLOK = 400
VOORBEELDEN = 15

OPDRACHT = f"""Je koppelt namen uit een boodschappen-app aan producttypes. Een naam is wat iemand op een boodschappenlijst heeft getypt of wat op een kassabon stond. Een type is het niveau waarop een koper wisselt bij een aanbieding.

Kies per naam het ene type waar hij bij hoort, of "{GEEN}". Neem de naam van het type letterlijk over uit de lijst.

- Toets: zou iemand die dit op zijn lijst zet bij een aanbieding een artikel van dat type kopen?
- Lees de afbakening. "Niet:" zegt wat er net niet bij hoort en waar dat wel hoort.
- Een losse merknaam zonder product ("zaanse hoeve", "nivea") krijgt "{GEEN}": het merk kan van alles zijn.
- Een naam die te vaag is om één type te kiezen ("sap", "papier", "deeg", "saus", "groenten") krijgt "{GEEN}". Gok niet.
- Onleesbare tekst krijgt het type voor onleesbare invoer als dat bestaat, anders "{GEEN}".
- zekerheid: "hoog" als het er zonder twijfel bij hoort, "middel" als het waarschijnlijk klopt, "laag" bij echte twijfel. Bij "{GEEN}" zegt de zekerheid hoe zeker je bent dat geen type past.
- reden: één korte zin in het Nederlands.

Geef voor elke naam precies één oordeel, met het nummer van de naam."""


def schema(namen):
    return {
        "type": "object",
        "properties": {"oordelen": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "naam": {"type": "integer", "description": "Het nummer van de naam in het bericht"},
                "type": {"type": "string", "enum": [GEEN] + namen},
                "zekerheid": {"type": "string", "enum": list(ZEKERHEID)},
                "reden": {"type": "string"},
            },
            "required": ["naam", "type", "zekerheid", "reden"],
            "additionalProperties": False,
        }}},
        "required": ["oordelen"],
        "additionalProperties": False,
    }


def types_tekst(types):
    """De typelijst per hoofdgroep, in dezelfde vorm als de Edge Function artikelen-classificeren."""
    regels, groep = [], None
    for t in types:
        if t["hoofdgroep"] != groep:
            groep = t["hoofdgroep"]
            regels += ["", f"## {groep}"]
        regels.append(f"- {t['naam']}" + (f": {t['valt_eronder']}" if t["valt_eronder"] else "")
                      + (f" Niet: {t['valt_er_niet_onder']}" if t["valt_er_niet_onder"] else ""))
    return "\n".join(regels)


def vraag_types(producten, types, verbruik):
    """Laat de AI de catalogusproducten zonder type beoordelen. Geeft per product-id (type of None, zekerheid, reden)."""
    if not producten:
        return {}
    sleutel = voorstellen.lees_sleutel()
    if not sleutel:
        sys.exit("ANTHROPIC_API_KEY is niet gezet (in de omgeving of in .env).")
    per_naam = {t["naam"]: t for t in types}
    systeem = OPDRACHT + "\n\n# Producttypes\n" + types_tekst(types)
    uit = {}
    for i in range(0, len(producten), PORTIE):
        portie = producten[i:i + PORTIE]
        regels = []
        for nr, p in enumerate(portie, 1):
            andere = [n["naam"] for n in p["namen"] if n["naam"] != p["naam"].lower()][:voorstellen.NAMEN_MAX]
            regels.append(f"{nr}. {p['naam']}" + (" | ook: " + ", ".join(andere) if andere else ""))
        try:
            antwoord = voorstellen.vraag_ai(sleutel, systeem, "Namen:\n" + "\n".join(regels), schema(list(per_naam)), verbruik)
        except (RuntimeError, ValueError) as fout:
            print(f"  de AI-ronde voor {len(portie)} catalogusproducten is mislukt: {fout}")
            continue
        for o in antwoord.get("oordelen", []):
            nr = o.get("naam")
            if not isinstance(nr, int) or not 1 <= nr <= len(portie) or o.get("zekerheid") not in ZEKERHEID:
                continue
            if o.get("type") != GEEN and o.get("type") not in per_naam:
                continue
            uit[portie[nr - 1]["id"]] = (per_naam.get(o["type"]), ZEKERHEID[o["zekerheid"]], str(o.get("reden") or "").strip())
    return uit


def lees_keuzes():
    """De keuzes die de beheerder al in het verschillenbestand heeft gezet, per artikel."""
    if not VERSCHILLEN.exists():
        return {}
    with VERSCHILLEN.open(newline="", encoding="utf-8-sig") as bestand:
        return {(r["supermarkt"], r["artikel"]): (r.get("keuze") or "").strip().lower()
                for r in csv.DictReader(bestand, delimiter=";")}


def schrijf(pad, kop, rijen):
    pad.parent.mkdir(exist_ok=True)
    with pad.open("w", newline="", encoding="utf-8-sig") as bestand:
        uit = csv.writer(bestand, delimiter=";")
        uit.writerow(kop)
        uit.writerows(rijen)


def toon(kop, regels):
    if regels:
        print(f"{kop}: {len(regels)}")
        for regel in regels[:VOORBEELDEN]:
            print("  " + regel)
        if len(regels) > VOORBEELDEN:
            print(f"  ... en {len(regels) - VOORBEELDEN} meer")


def main():
    echt = "--echt" in sys.argv
    print("ECHT: de koppelingen worden opgeslagen." if echt else "PROEF: er wordt niets opgeslagen (gebruik --echt om op te slaan).")
    bestand, fouten = laden.lees_bestand()
    if fouten:
        sys.exit("docs/producttypes.csv heeft fouten; draai eerst scripts/producttypes-laden.py.")

    db = importeren.Supabase(*importeren.lees_config())
    try:
        db.login(input("\nE-mailadres van de beheerder: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
        werk = db.rpc("type_migration_work")
    except RuntimeError as fout:
        sys.exit(f"Mislukt: {fout}")

    types = werk["types"]
    per_sleutel = {sleutel_van(t["naam"]): t for t in types}
    per_id = {t["id"]: t for t in types}
    ontbreekt = [t["name"] for t in bestand if sleutel_van(t["name"]) not in per_sleutel]
    if ontbreekt:
        sys.exit(f"{len(ontbreekt)} types uit het bestand staan niet in de database ({', '.join(ontbreekt[:5])}); "
                 "draai eerst scripts/producttypes-laden.py --echt.")
    onbeoordeeld = sum(n["onbeoordeeld"] for n in werk["lijstnamen"])
    if onbeoordeeld:
        print("Let op: nog niet alle artikelen hebben een oordeel van de AI (python3 scripts/ah-bonus-opslaan.py --types). "
              "Lijstnamen van die artikelen doen nu niet mee.")

    # ---------- 1 en 2: catalogusproducten ----------
    uit_bestand = {b.lower(): per_sleutel[sleutel_van(t["name"])] for t in bestand for b in t["bron"]}
    product_type = {}   # product-id → (type of None, bron, zekerheid, reden)
    zonder = []
    for p in werk["producten"]:
        if p["naam"].lower() in uit_bestand:
            product_type[p["id"]] = (uit_bestand[p["naam"].lower()], "catalog", None, None)
        elif p["namen"]:
            zonder.append(p)
    verbruik = {"input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 0}
    print(f"\n{len(product_type)} catalogusproducten hebben een type uit het bestand, {len(zonder)} gaan naar de AI.")
    for pid, (soort, zekerheid, reden) in vraag_types(zonder, types, verbruik).items():
        product_type[pid] = (soort, "ai", zekerheid, reden)
    toon("Catalogusproducten zonder oordeel (de AI-ronde is mislukt of gaf niets bruikbaars)",
         [p["naam"] for p in zonder if p["id"] not in product_type])

    # Elke naam van een product wordt een naam van het type. Twee namen met dezelfde sleutel: de meest gekochte wint.
    namen = {}          # sleutel → { term, type, bron, zekerheid, reden, aankopen, product }
    botsingen, is_type = [], []
    for p in werk["producten"]:
        if p["id"] not in product_type:
            continue
        soort, bron, zekerheid, reden = product_type[p["id"]]
        for n in p["namen"]:
            sleutel = sleutel_van(n["naam"])
            if not sleutel:
                continue
            if sleutel in per_sleutel:
                # De naam is zelf een type; die gaat altijd voor
                if per_sleutel[sleutel] is not soort:
                    is_type.append(f"\"{n['naam']}\" is zelf een type, maar het product \"{p['naam']}\" gaat naar "
                                   f"\"{soort['naam'] if soort else GEEN}\"")
                continue
            nieuw = {"term": n["naam"], "type": soort, "bron": bron, "zekerheid": zekerheid, "reden": reden,
                     "aankopen": n["aankopen"], "product": p["naam"]}
            oud = namen.get(sleutel)
            if oud and oud["type"] is not soort:
                botsingen.append(f"\"{oud['term']}\" ({oud['product']}) en \"{n['naam']}\" ({p['naam']}) zijn dezelfde naam "
                                 "met een ander type; de meest gekochte telt")
            if not oud or n["aankopen"] > oud["aankopen"]:
                namen[sleutel] = nieuw

    # ---------- 3: lijstnamen ----------
    vervalt = 0
    for n in werk["lijstnamen"]:
        if n["sleutel"] in namen or n["sleutel"] in per_sleutel:
            continue
        if len(n["types"]) == 1 and not n["zonder_type"] and not n["onbeoordeeld"]:
            namen[n["sleutel"]] = {"term": n["naam"], "type": per_id[n["types"][0]["type_id"]], "bron": "catalog",
                                   "zekerheid": None, "reden": f"lijstnaam van {n['artikelen']} artikelen",
                                   "aankopen": 0, "product": ""}
        else:
            vervalt += 1

    # ---------- 4: artikelen ----------
    keuzes = lees_keuzes()
    per_artikel = {}
    for a in werk["artikelen"]:
        per_artikel.setdefault((a["supermarket"], a["article_id"]), []).append(a)
    bevestigd, overnemen, verschillen, onduidelijk = [], [], [], 0
    for (supermarkt, artikel), rijen in per_artikel.items():
        a = rijen[0]
        oud = {id(t): t for t in (product_type.get(r["product_id"], (None,))[0] for r in rijen) if t}
        if len(oud) != 1:
            # Het product heeft geen type, of het artikel is onder twee namen met een ander type gekocht: de AI telt
            onduidelijk += len(oud) > 1
            continue
        soort = next(iter(oud.values()))
        rij = {"supermarket": supermarkt, "article_id": artikel, "type_id": soort["id"], "bron": a["bron"]}
        if a["type_bron"] == "manual":
            continue
        if a["type_id"] == soort["id"]:
            if a["type_bron"] == "ai":
                bevestigd.append(rij)
        elif a["type_id"] is None:
            overnemen.append(rij)
        else:
            keuze = keuzes.get((supermarkt, artikel)) or KEUZE_STANDAARD
            verschillen.append({**rij, "keuze": keuze if keuze in KEUZES else KEUZE_STANDAARD, "titel": a["titel"],
                                "categorie": a["categorie"] or "", "catalogus": soort["naam"],
                                "ai": per_id[a["type_id"]]["naam"], "ai_id": a["type_id"], "zekerheid": a["zekerheid"] or ""})

    # ---------- Verslagen ----------
    schrijf(NAMEN, ["naam", "type", "hoofdgroep", "bron", "zekerheid", "aankopen", "reden", "catalogusproduct"], [
        [n["term"], n["type"]["naam"] if n["type"] else GEEN, n["type"]["hoofdgroep"] if n["type"] else "", n["bron"],
         n["zekerheid"] or "", n["aankopen"], n["reden"] or "", n["product"]]
        for n in sorted(namen.values(), key=lambda n: (n["bron"] != "ai", (n["type"] or {"naam": ""})["naam"], n["term"]))])
    schrijf(VERSCHILLEN, KOLOMMEN_VERSCHIL, [
        [v["keuze"], v["titel"], v["categorie"], v["catalogus"], v["ai"], v["zekerheid"], BRON[v["bron"]], v["supermarket"], v["article_id"]]
        for v in sorted(verschillen, key=lambda v: (v["catalogus"], v["ai"], v["titel"]))])

    van_ai = [n for n in namen.values() if n["bron"] == "ai"]
    print(f"\nNamen: {len(namen)} krijgen een oordeel. {sum(1 for n in namen.values() if n['bron'] == 'catalog' and n['product'])} "
          f"uit de catalogus, {sum(1 for n in namen.values() if not n['product'])} lijstnamen, {len(van_ai)} via de AI "
          f"(waarvan {sum(1 for n in van_ai if not n['type'])} zonder type). {vervalt} lijstnamen vervallen.")
    toon("\nVia de AI", [f"{n['term']} ({n['aankopen']}) → {n['type']['naam'] if n['type'] else GEEN} [{n['zekerheid']}]: {n['reden']}"
                         for n in sorted(van_ai, key=lambda n: -n["aankopen"])])
    toon("\nDezelfde naam bij twee types", botsingen)
    toon("\nNamen die zelf een type zijn", is_type)
    print(f"\nArtikelen uit de oude catalogus: {len(bevestigd)} keer is de AI het eens (gelden als nagekeken), "
          f"{len(overnemen)} hadden geen type van de AI en krijgen dat van de catalogus, {len(verschillen)} verschillen"
          + (f", {onduidelijk} onder twee namen met een ander type gekocht (de AI telt)." if onduidelijk else "."))
    groepen = {}
    for v in verschillen:
        groepen.setdefault((v["catalogus"], v["ai"]), []).append(v)
    toon("\nVerschillen (catalogus → AI, aantal artikelen, voorbeeld)",
         [f"{oud} → {nieuw}: {len(lijst)}, bijv. {lijst[0]['titel']}" for (oud, nieuw), lijst in sorted(groepen.items(), key=lambda g: -len(g[1]))])
    if verschillen:
        print(f"Bij een verschil zonder keuze telt \"{KEUZE_STANDAARD}\". Pas de kolom keuze aan in {VERSCHILLEN.relative_to(importeren.HOOFDMAP)}.")
    if sum(verbruik.values()):
        print(f"\nVerbruik: {verbruik['input_tokens'] + verbruik['cache_creation_input_tokens']} tokens invoer, "
              f"{verbruik['cache_read_input_tokens']} uit de cache, {verbruik['output_tokens']} uitvoer.")
    print(f"Alle namen staan in {NAMEN.relative_to(importeren.HOOFDMAP)}.")

    if not echt:
        print("\nPROEF: er is niets opgeslagen.")
        return
    try:
        opgeslagen = {}
        for bron in ("catalog", "ai"):
            rijen = [{"term": n["term"], "type_id": n["type"]["id"] if n["type"] else None,
                      "confidence": n["zekerheid"], "reason": n["reden"]} for n in namen.values() if n["bron"] == bron]
            for i in range(0, len(rijen), BLOK):
                uit = db.rpc("save_term_types", p_rows=rijen[i:i + BLOK], p_source=bron)
                for soort, aantal in uit.items():
                    opgeslagen[soort] = opgeslagen.get(soort, 0) + aantal
        artikelen = 0
        # Kiest de beheerder bij een verschil voor de AI, dan is dat zijn eigen oordeel: bron manual
        gekozen = bevestigd + overnemen + [v if v["keuze"] == "catalogus" else {**v, "type_id": v["ai_id"], "bron": "manual"}
                                           for v in verschillen]
        for bron in (*BRON, "manual"):
            rijen = [{k: r[k] for k in ("supermarket", "article_id", "type_id")} for r in gekozen if r["bron"] == bron]
            for i in range(0, len(rijen), BLOK):
                artikelen += db.rpc("set_article_types", p_rows=rijen[i:i + BLOK], p_source=bron)
    except RuntimeError as fout:
        sys.exit(f"Opslaan mislukt: {fout}. Draai het script opnieuw; wat al is opgeslagen wordt overgeslagen of bijgewerkt.")
    print(f"\nOpgeslagen: {opgeslagen.get('opgeslagen', 0)} namen ({opgeslagen.get('overgeslagen', 0)} overgeslagen: "
          f"door de beheerder gezet of al nagekeken) en {artikelen} artikelen.")


if __name__ == "__main__":
    main()
