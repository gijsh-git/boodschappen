#!/usr/bin/env python3
"""Zet de nagelezen typelijst (docs/producttypes.csv) in de database.

Het bestand komt van scripts/producttypes-voorstellen.py en is daarna door de beheerder bewerkt. Dit script
controleert het (lege namen, dubbele types, een catalogusproduct bij twee types, catalogusproducten die
nergens in zitten) en slaat de types op via save_product_types, die de beheerdersrol controleert. Een type
wordt herkend aan zijn naam: bestaat het al, dan worden hoofdgroep, afbakening en vlag bijgewerkt. Er wordt
nooit een type verwijderd. De kolom bronproducten gaat niet naar de database: die gebruikt de migratie van
de catalogus later, rechtstreeks uit het bestand.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/producttypes-laden.py           proef: controleert en telt, schrijft niets
  python3 scripts/producttypes-laden.py --echt    slaat de types op
  python3 scripts/producttypes-laden.py --echt --samenvoegen tomatensoep=soep
                                                  laat eerst het type tomatensoep opgaan in soep

Samenvoegen (--samenvoegen bron=doel, mag vaker) verhuist de artikelen en namen van de bron naar het doel en
haalt de bron weg; de naam van de bron blijft werken als naam van het doel. Haal de bron eerst uit het bestand
en zet zijn bronproducten bij het doel, anders komt hij bij het opslaan gewoon terug. Is er iets samengevoegd
of bijgewerkt, dan worden de artikelen waar de AI geen type voor vond opnieuw beoordeeld bij de volgende
ronde (python3 scripts/ah-bonus-opslaan.py --types).

Je logt in met het e-mailadres en wachtwoord van de beheerder; het wachtwoord wordt nergens bewaard.
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


voorstellen = laad("producttypes-voorstellen")
importeren = voorstellen.importeren

JA = {"ja": True, "nee": False}
# Zoveel voorbeelden per melding
VOORBEELDEN = 15


def lees_bestand():
    """De types uit het bestand, met de fouten die opslaan tegenhouden."""
    with voorstellen.UITVOER.open(newline="", encoding="utf-8-sig") as bestand:
        rijen = list(csv.DictReader(bestand, delimiter=";"))
    if not rijen or any(k not in rijen[0] for k in voorstellen.KOLOMMEN):
        sys.exit("Het bestand heeft niet de kolommen " + ", ".join(voorstellen.KOLOMMEN)
                 + ". Bewaar het als CSV met puntkomma's.")
    types, fouten, gezien = [], [], {}
    for nr, rij in enumerate(rijen, 2):
        naam = " ".join((rij["type"] or "").split())
        groep = (rij["hoofdgroep"] or "").strip()
        telt = JA.get((rij["telt mee"] or "ja").strip().lower())
        sleutel = voorstellen.sleutel_van(naam)
        if not naam and not groep:
            continue
        if not sleutel or len(naam) > 80:
            fouten.append(f"regel {nr}: geen geldige typenaam (\"{naam}\")")
        elif not groep:
            fouten.append(f"regel {nr}: \"{naam}\" heeft geen hoofdgroep")
        elif telt is None:
            fouten.append(f"regel {nr}: \"telt mee\" bij \"{naam}\" moet ja of nee zijn")
        elif sleutel in gezien:
            fouten.append(f"regel {nr}: \"{naam}\" staat er al op regel {gezien[sleutel]}")
        else:
            gezien[sleutel] = nr
            types.append({
                "name": naam, "main_group": groep, "scope": (rij["valt eronder"] or "").strip(),
                "excludes": (rij["valt er niet onder"] or "").strip(), "counts_in_profile": telt,
                "bron": [b.strip() for b in (rij["bronproducten"] or "").split(voorstellen.TUSSEN.strip()) if b.strip()],
            })
    return types, fouten


def toon(kop, namen):
    if namen:
        print(f"{kop}: {len(namen)}\n  " + ", ".join(namen[:VOORBEELDEN]) + (" ..." if len(namen) > VOORBEELDEN else ""))


def lees_samenvoegingen(types):
    """De paren (bron, doel) achter --samenvoegen, met de fouten die opslaan tegenhouden."""
    in_bestand = {voorstellen.sleutel_van(t["name"]) for t in types}
    paren, fouten = [], []
    for i, woord in enumerate(sys.argv):
        if woord != "--samenvoegen":
            continue
        bron, _, doel = (sys.argv[i + 1] if i + 1 < len(sys.argv) else "").partition("=")
        bron, doel = bron.strip(), doel.strip()
        if not bron or not doel:
            fouten.append("--samenvoegen verwacht bron=doel, bijvoorbeeld --samenvoegen tomatensoep=soep")
        elif voorstellen.sleutel_van(bron) in in_bestand:
            fouten.append(f"\"{bron}\" staat nog als type in het bestand; haal die regel eerst weg")
        elif voorstellen.sleutel_van(doel) not in in_bestand:
            fouten.append(f"het doel \"{doel}\" staat niet als type in het bestand")
        else:
            paren.append((bron, doel))
    return paren, fouten


def main():
    echt = "--echt" in sys.argv
    if not voorstellen.UITVOER.exists():
        sys.exit(f"{voorstellen.UITVOER.relative_to(importeren.HOOFDMAP)} bestaat niet; maak eerst een voorstel "
                 "met scripts/producttypes-voorstellen.py.")
    print("ECHT: de types worden opgeslagen." if echt else "PROEF: er wordt niets opgeslagen (gebruik --echt om op te slaan).")
    types, fouten = lees_bestand()
    samenvoegen, fouten_samen = lees_samenvoegingen(types)
    fouten += fouten_samen

    # Een catalogusproduct mag maar in één type opgaan
    waar = {}
    for t in types:
        for b in t["bron"]:
            if b.lower() in waar:
                fouten.append(f"het catalogusproduct \"{b}\" staat bij \"{waar[b.lower()]}\" en bij \"{t['name']}\"")
            waar.setdefault(b.lower(), t["name"])

    groepen = {}
    for t in types:
        groepen[t["main_group"]] = groepen.get(t["main_group"], 0) + 1
    print(f"\n{len(types)} types in {len(groepen)} hoofdgroepen:")
    for groep in sorted(groepen, key=str.lower):
        print(f"  {groep}: {groepen[groep]}")
    toon("\nTelt niet mee in het profiel", [t["name"] for t in types if not t["counts_in_profile"]])
    toon("Zonder afbakening (de AI weet dan alleen de naam)", [t["name"] for t in types if not t["scope"]])

    db = importeren.Supabase(*importeren.lees_config())
    try:
        db.login(input("\nE-mailadres van de beheerder: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
        werk = db.rpc("type_proposal_work")
    except RuntimeError as fout:
        sys.exit(f"Mislukt: {fout}")

    # De catalogus ernaast: alles wat gekocht is of op een lijst staat hoort straks bij een type
    catalogus = {p["naam"].lower(): p for p in werk["producten"]}
    toon("\nBronproducten die niet (meer) in de catalogus staan", sorted(b for b in waar if b not in catalogus))
    los = [p for naam, p in catalogus.items() if naam not in waar]
    toon("Catalogusproducten met aankopen die in geen enkel type zitten",
         [f"{p['naam']} ({p['aankopen']})" for p in sorted(los, key=lambda p: -p["aankopen"]) if p["aankopen"]])
    zonder = sum(1 for p in los if not p["aankopen"])
    if zonder:
        print(f"En {zonder} catalogusproducten zonder aankopen.")
    if los:
        print("Wat hier staat beoordeelt de AI bij de migratie (scripts/naar-producttypes.py); een te vage naam of een losse merknaam krijgt dan geen type.")

    if fouten:
        print(f"\n{len(fouten)} fouten in het bestand:")
        for fout in fouten:
            print("  " + fout)
        sys.exit("Los die eerst op; er is niets opgeslagen.")
    for bron, doel in samenvoegen:
        print(f"Samenvoegen: \"{bron}\" gaat op in \"{doel}\".")
    if not echt:
        print("\nPROEF: er is niets opgeslagen.")
        return
    try:
        # Eerst samenvoegen, zolang beide types er nog zijn; daarna krijgt het doel zijn nieuwe afbakening
        for bron, doel in samenvoegen:
            samen = db.rpc("merge_product_types", p_source=bron, p_target=doel)
            print(f"Samengevoegd: \"{samen['bron']}\" in \"{samen['doel']}\" ({samen['artikelen']} artikelen, {samen['namen']} namen verhuisd).")
        uit = db.rpc("save_product_types", p_rows=[{k: v for k, v in t.items() if k != "bron"} for t in types])
    except RuntimeError as fout:
        sys.exit(f"Opslaan mislukt: {fout}")
    print(f"\nOpgeslagen: {uit['nieuw']} nieuw, {uit['bijgewerkt']} bijgewerkt, {uit['ongewijzigd']} ongewijzigd; "
          f"nu {uit['totaal']} types in de database.")
    if uit["niet_in_bestand"]:
        print(f"{uit['niet_in_bestand']} types staan wel in de database maar niet in het bestand; die blijven staan.")
    if samenvoegen or uit["nieuw"] or uit["bijgewerkt"]:
        # Een gewijzigde afbakening geeft niet vanzelf een herbeoordeling; een nieuw type wel
        try:
            opnieuw = db.rpc("reset_untyped_articles")
        except RuntimeError as fout:
            sys.exit(f"Opnieuw laten beoordelen mislukt: {fout}")
        if opnieuw:
            print(f"{opnieuw} artikelen zonder type worden opnieuw beoordeeld: python3 scripts/ah-bonus-opslaan.py --types")


if __name__ == "__main__":
    main()
