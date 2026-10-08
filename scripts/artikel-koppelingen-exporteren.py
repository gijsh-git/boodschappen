#!/usr/bin/env python3
"""Schrijft de oordelen van de beheerder over niveau 2 naar één bestand, om ze te laten nalezen.

In het scherm Producten keurt de beheerder voorstellen goed of wijst ze af (zie scripts/artikel-voorstellen.py).
Dit script zet alle goedgekeurde koppelingen en alle afgewezen combinaties per product onder elkaar, met de
opdracht voor de lezer, docs/productregels.md en de lijst van alle producten erbij. Het bestand staat op
zichzelf: je kunt het zo aan iemand anders of aan een AI geven.

Het script leest alleen, via article_link_review, die de beheerdersrol controleert.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/artikel-koppelingen-exporteren.py

Het resultaat komt in data/artikel-koppelingen.md (data/ staat niet in git). Je logt in met het e-mailadres
en wachtwoord van de beheerder; het wachtwoord wordt nergens bewaard.
"""
import getpass
import importlib.util
import sys
from datetime import date
from pathlib import Path

# De naam ah-importeren.py heeft een streepje en is dus niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)

REGELS = importeren.HOOFDMAP / "docs" / "productregels.md"
UITVOER = importeren.HOOFDMAP / "data" / "artikel-koppelingen.md"
ZEKERHEID = {"high": "hoog", "medium": "middel", "low": "laag"}
BRON = {"rule": "vaste regel", "ai": "AI"}

OPDRACHT = """Een boodschappen-app koppelt artikelen van een supermarkt aan producten. Een product is het niveau waarop een koper wisselt bij een aanbieding: is een gekoppeld artikel in de aanbieding, dan laat de app dat zien bij dat product. Een script stelde per artikel een product voor; de beheerder keurde elk voorstel goed of wees het af. Hieronder staan al die oordelen, per product.

Lees ze na aan de hand van de productregels. De toets is steeds: zou iemand die dit product koopt bij een aanbieding dit artikel in plaats daarvan kopen?

- Goedgekeurd maar fout: het artikel hoort niet bij dit product (pompoensoep bij pompoen), of het is een variant waar je niet tussen wisselt (cola zero bij cola).
- Afgewezen maar fout: het artikel hoort volgens de regels wel bij dit product.
- Hoort een artikel beter bij een ander product uit de lijst onderaan, noem dat product.
- Oordelen die elkaar tegenspreken: twee vergelijkbare artikelen waarvan de een is goedgekeurd en de ander afgewezen bij hetzelfde product.

Noem alleen de oordelen waar je het mee oneens bent of over twijfelt, per product, met een korte reden en hoe zeker je bent. Wat klopt hoef je niet te herhalen. Sluit af met een telling en met patronen die je ziet, bijvoorbeeld een regel die steeds anders is toegepast of die in de productregels ontbreekt."""


def artikel_regel(rij, met_voorstel):
    """Eén artikel: titel, merk, inhoud en categorie, en bij een goedgekeurd artikel wat het voorstel erbij zei."""
    delen = [rij["titel"]]
    for kop, veld in (("merk", "merk"), ("inhoud", "inhoud"), ("categorie", "categorie")):
        if rij.get(veld):
            delen.append(f"{kop}: {rij[veld]}")
    if met_voorstel:
        delen.append(f"voorstel: {BRON.get(rij.get('bron'), 'onbekend')}, zekerheid {ZEKERHEID.get(rij.get('zekerheid'), 'onbekend')}")
        if rij.get("reden"):
            delen.append(f"reden: {rij['reden']}")
    return "- " + " | ".join(delen)


def maak_tekst(uit, regels):
    goed, af = uit["goedgekeurd"], uit["afgewezen"]
    per_product = {}
    for soort, rijen in (("goed", goed), ("af", af)):
        for rij in rijen:
            per_product.setdefault(rij["product"], {"goed": [], "af": []})[soort].append(rij)

    tekst = [
        "# Koppelingen artikel → product nalezen", "",
        f"Stand van {date.today().isoformat()}: {len(goed)} goedgekeurd, {len(af)} afgewezen, bij {len(per_product)} producten.", "",
        "## Opdracht", "", OPDRACHT, "",
        "## Productregels", "",
        "De regels van de app, letterlijk overgenomen. Kopjes hieronder horen bij de regels tot aan \"De oordelen\".", "",
        regels.strip(), "",
        "## De oordelen", "",
        "Bij een goedgekeurd artikel staat wat het voorstel erbij zei. Bij een afgewezen artikel is dat niet bewaard.", "",
    ]
    for product in sorted(per_product, key=str.lower):
        tekst += [f"### {product}", ""]
        for soort, kop in (("goed", "Goedgekeurd"), ("af", "Afgewezen")):
            rijen = per_product[product][soort]
            if rijen:
                tekst += [f"{kop}:"] + [artikel_regel(rij, soort == "goed") for rij in rijen] + [""]
    tekst += ["## Alle producten", "",
              "Om te zien of een artikel beter bij een ander product past.", "",
              ", ".join(uit["producten"]), ""]
    return "\n".join(tekst)


def main():
    db = importeren.Supabase(*importeren.lees_config())
    try:
        db.login(input("E-mailadres van de beheerder: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
        uit = db.rpc("article_link_review")
    except RuntimeError as fout:
        sys.exit(f"Mislukt: {fout}")

    UITVOER.parent.mkdir(exist_ok=True)
    UITVOER.write_text(maak_tekst(uit, REGELS.read_text()))
    print(f"{len(uit['goedgekeurd'])} goedgekeurd en {len(uit['afgewezen'])} afgewezen geschreven naar {UITVOER.relative_to(importeren.HOOFDMAP)}.")


if __name__ == "__main__":
    main()
