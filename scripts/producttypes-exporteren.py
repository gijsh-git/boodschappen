#!/usr/bin/env python3
"""Schrijft de typelijst uit de database naar docs/producttypes-export.csv.

De database is de bron van de producttypes: je maakt, wijzigt en voegt ze samen in de app (Profiel >
Koppelingen beheren). Dit bestand is alleen een afdruk, zodat git laat zien hoe de lijst verandert. Pas het
niet met de hand aan: een wijziging hier doet niets en wordt bij de volgende export overschreven.

Het script draait vanzelf bij elke commit (.githooks/pre-commit) en kan ook met de hand:
  python3 scripts/producttypes-exporteren.py

Het leest via de Edge Function producttypes-exporteren, met AANBIEDINGEN_SLEUTEL uit de omgeving of uit .env.
Er is geen login nodig en het schrijft niets naar de database. De uitvoer is 0 als het bestand klopt met de
database (ook als het net is bijgewerkt) en 1 als lezen is mislukt; het bestand blijft dan zoals het was.
"""
import csv
import importlib.util
import io
import os
import sys
from pathlib import Path


def laad(naam):
    """Een script met een streepje in de naam is niet gewoon te importeren."""
    spec = importlib.util.spec_from_file_location(naam.replace("-", "_"), Path(__file__).with_name(naam + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


opslaan = laad("aanbiedingen-opslaan")
importeren = opslaan.importeren

UITVOER = importeren.HOOFDMAP / "docs" / "producttypes-export.csv"
# Alleen de types zelf. De namen die bij een type horen staan er bewust niet in: dat is wat mensen op hun
# lijst typten of kochten, en de repo is openbaar. Ook geen aantallen artikelen: die veranderen elke bonusweek,
# en het bestand hoort alleen te veranderen als de typelijst verandert.
KOLOMMEN = ["hoofdgroep", "type", "valt eronder", "valt er niet onder", "telt mee"]


def lees_sleutel():
    """AANBIEDINGEN_SLEUTEL uit de omgeving, anders uit .env in de hoofdmap."""
    sleutel = os.environ.get("AANBIEDINGEN_SLEUTEL", "").strip()
    bestand = importeren.HOOFDMAP / ".env"
    if not sleutel and bestand.exists():
        for regel in bestand.read_text().splitlines():
            naam, _, waarde = regel.partition("=")
            if naam.strip() == "AANBIEDINGEN_SLEUTEL":
                sleutel = waarde.strip().strip("\"'")
    return sleutel


def maak_tekst(types):
    """Het hele bestand als tekst. Puntkomma's en een BOM: zo opent het goed in Numbers en in Excel."""
    buffer = io.StringIO(newline="")
    uit = csv.writer(buffer, delimiter=";")
    uit.writerow(KOLOMMEN)
    for t in types:
        uit.writerow([t["hoofdgroep"], t["type"], t["valt_eronder"] or "", t["valt_er_niet_onder"] or "",
                      "ja" if t["telt_mee"] else "nee"])
    return buffer.getvalue()


def main():
    sleutel = lees_sleutel()
    if not sleutel:
        print("Typelijst niet geëxporteerd: AANBIEDINGEN_SLEUTEL is niet gezet (in de omgeving of in .env).", file=sys.stderr)
        return 1
    try:
        types = opslaan.roep(importeren.lees_config()[0], sleutel, "producttypes-exporteren", {}, wachten=30)["types"]
    except (RuntimeError, KeyError) as fout:
        print(f"Typelijst niet geëxporteerd: {fout}", file=sys.stderr)
        return 1
    if not types:
        print("Typelijst niet geëxporteerd: de database gaf geen types terug.", file=sys.stderr)
        return 1
    tekst = maak_tekst(types)
    oud = None
    if UITVOER.exists():
        # newline="": de regeleinden van csv (\r\n) blijven zoals ze zijn, anders lijkt het bestand steeds anders
        with UITVOER.open(encoding="utf-8-sig", newline="") as bestand:
            oud = bestand.read()
    if tekst == oud:
        print(f"{UITVOER.relative_to(importeren.HOOFDMAP)} is gelijk aan de database ({len(types)} types).")
        return 0
    with UITVOER.open("w", encoding="utf-8-sig", newline="") as bestand:
        bestand.write(tekst)
    print(f"{UITVOER.relative_to(importeren.HOOFDMAP)} bijgewerkt uit de database ({len(types)} types).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
