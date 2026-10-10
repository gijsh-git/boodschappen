#!/usr/bin/env python3
"""Zet de opgehaalde aanbiedingen van een supermarkt (data/<winkel>-aanbiedingen.json) in de database.

Elke winkel heeft een eigen ophaalscript (scripts/ah-bonus, scripts/plus-aanbiedingen) dat hetzelfde formaat
schrijft: { winkel, van, tot, opgehaald, aanbiedingen }, per aanbieding id, titel, korting, labels, categorie,
van, tot, groep, alleen_winkel, mislukt en de artikelen met artikel_id, webshop_id, ean, titel, merk, inhoud,
hoeveelheid, eenheid, categorie, prijs en actieprijs. Wat een winkel niet heeft blijft weg.

Dit script stuurt de week naar de Edge Function aanbiedingen-opslaan, die de databasefunctie save_offers
aanroept: artikelen en aanbiedingen worden toegevoegd of bijgewerkt, dus opnieuw draaien met dezelfde week
voegt niets dubbel toe. Het artikel_id is het artikelnummer in het systeem van de winkel: bij AH het hqId
(hetzelfde nummer als op de kassabon), bij PLUS het nummer van de webshop. Verlopen aanbiedingen ruimt de
functie zelf op.

Daarna krijgen de artikelen die nog geen producttype hebben er een, van welke winkel ook: de Edge Function
artikelen-classificeren laat de AI ze in porties beoordelen (titel, merk en categorie als invoer). Per week
zijn dat alleen de nieuwe artikelen; een artikel wordt één keer beoordeeld. Bij hetzelfde oordeel hoort de
variant (de smaak of soort binnen het type); een artikel of naam met een type en zonder variant krijgt die alsnog.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/aanbiedingen-opslaan.py --winkel AH           proef: telt wat er zou gebeuren, schrijft niets
  python3 scripts/aanbiedingen-opslaan.py --winkel AH --echt    slaat de week op en geeft nieuwe artikelen een type
  python3 scripts/aanbiedingen-opslaan.py --winkel PLUS --bekend
      vraagt welke artikelen van die winkel al een EAN of een hoeveelheid hebben en zet hun nummers in
      data/plus-bekend.json; het ophaalscript slaat voor die artikelen de productpagina over
  python3 scripts/aanbiedingen-opslaan.py --types               slaat niets op, geeft alleen artikelen zonder type een type

Voor --echt, --bekend en --types is AANBIEDINGEN_SLEUTEL nodig: dezelfde waarde als de secret met die naam in
Supabase. Met die sleutel kun je alleen aanbiedingen opslaan en die ene vraag stellen; de service role key
komt Supabase niet uit. Zet hem in .env of als secret in GitHub, nooit in de code. De wekelijkse taken staan
in .github/workflows/ah-bonus.yml en .github/workflows/plus-aanbiedingen.yml.
"""
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

# De naam ah-importeren.py heeft een streepje en is dus niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)

DATA = importeren.HOOFDMAP / "data"
# Een week met minder aanbiedingen dan dit is vrijwel zeker een mislukte ophaalronde. Per winkel:
# AH heeft er rond de 140 per week, PLUS rond de 200.
MINSTENS = {"AH": 20, "PLUS": 50}
# Zo vaak mag het geven van types haperen voordat het script ermee stopt
HAPERINGEN_MAX = 3
# Zoveel porties namen krijgen per keer hooguit een variant
RONDES_MAX = 50


def tekst(waarde):
    return None if waarde in (None, "", 0) else str(waarde)


# Eenheden naar de drie waarin de database rekent: gram, milliliter en stuks
EENHEDEN = {
    "g": ("g", 1), "gr": ("g", 1), "gram": ("g", 1), "kg": ("g", 1000), "kilo": ("g", 1000),
    "ml": ("ml", 1), "cl": ("ml", 10), "dl": ("ml", 100), "l": ("ml", 1000), "liter": ("ml", 1000),
    "st": ("st", 1), "stuk": ("st", 1), "stuks": ("st", 1),
}
_GETAL = r"(\d+(?:[.,]\d+)?)"
_INHOUD = re.compile(rf"^(?:(\d+)\s*x\s*)?{_GETAL}?\s*([a-z]+)$")


def getal(tekst):
    return float(tekst.replace(",", "."))


def hoeveelheid(inhoud):
    """De inhoud als (hoeveelheid, eenheid) in g, ml of st, of (None, None) als dat er niet in staat.

    "500 g" -> (500, "g"), "6 x 330 ml" -> (1980, "ml"), "1,5 l" -> (1500, "ml"), "ca. 300 g" -> (300, "g"),
    "per stuk" -> (1, "st"), "Los, per 500 gram" -> (500, "g"), "kilo" -> (1000, "g"), "20 wasbeurten" -> niets.
    """
    tekst = (inhoud or "").lower().strip()
    tekst = re.sub(r"^(los,\s*)?(ca\.?\s*|per\s+)*", "", tekst).strip()
    gevonden = _INHOUD.match(tekst)
    if not gevonden or gevonden.group(3) not in EENHEDEN:
        return None, None
    keer, aantal, eenheid = gevonden.groups()
    eenheid, factor = EENHEDEN[eenheid]
    totaal = int(keer or 1) * (getal(aantal) if aantal else 1) * factor
    return (round(totaal, 3), eenheid) if totaal > 0 else (None, None)


def kortingstekst(a):
    """De kortingstekst van een aanbieding. PLUS geeft bij ruim de helft alleen een actieprijs; daar maken we
    er zelf een van, in de vorm die AH gebruikt: "VOOR 1.49", en per gewicht "KILO VOOR 1.69"."""
    if a.get("korting"):
        return a["korting"]
    prijs = a.get("actieprijs")
    if not prijs:
        return None
    gewicht = re.match(r"^per (kilo|\d+ gram)$", (a.get("verpakking") or "").strip().lower())
    return (gewicht.group(1).upper() + " " if gewicht else "") + f"VOOR {prijs:.2f}"


def maak_aanbieding(a):
    """Eén aanbieding uit het bestand van een winkel in de vorm die save_offers verwacht."""
    artikelen = []
    for art in a["artikelen"]:
        # De productpagina van de winkel gaat voor; anders lezen we de hoeveelheid uit de inhoud
        aantal, eenheid = None, None
        if art.get("hoeveelheid") and art.get("eenheid"):
            aantal, eenheid = hoeveelheid(f"{art['hoeveelheid']} {art['eenheid']}")
        if aantal is None:
            aantal, eenheid = hoeveelheid(art.get("inhoud"))
        artikelen.append({
            "article_id": tekst(art.get("artikel_id")),
            "webshop_id": tekst(art.get("webshop_id")),
            "ean": tekst(art.get("ean")),
            "title": art["titel"],
            "brand": art.get("merk"),
            "size": art.get("inhoud"),
            "quantity": aantal,
            "unit": eenheid,
            "category": art.get("categorie"),
            "price": art.get("prijs"),
            "bonus_price": art.get("actieprijs"),
        })
    return {
        "offer_id": a["id"],
        "title": a["titel"],
        "discount_text": kortingstekst(a),
        "labels": a.get("labels") or [],
        "category": a.get("categorie"),
        "valid_from": a["van"],
        "valid_to": a["tot"],
        "is_group": bool(a.get("groep")),
        "store_only": bool(a.get("alleen_winkel")),
        "complete": not a.get("mislukt"),
        "articles": artikelen,
    }


def roep(url, sleutel, functie, inhoud, wachten=120):
    """Roept een Edge Function aan met de eigen sleutel en geeft het antwoord terug."""
    body = json.dumps(inhoud).encode()
    kop = {"Content-Type": "application/json", "x-aanbiedingen-sleutel": sleutel}
    verzoek = urllib.request.Request(url + "/functions/v1/" + functie, data=body, headers=kop)
    try:
        with urllib.request.urlopen(verzoek, timeout=wachten) as antwoord:
            return json.loads(antwoord.read().decode())
    except urllib.error.HTTPError as fout:
        tekst = fout.read().decode()
        try:
            inhoud = json.loads(tekst)
            melding = inhoud.get("fout") or inhoud.get("message") or inhoud.get("msg") or tekst
        except (ValueError, AttributeError):
            melding = tekst
        raise RuntimeError(f"{fout.code}: {melding}") from None
    except (urllib.error.URLError, TimeoutError) as fout:
        raise RuntimeError(str(getattr(fout, "reason", fout))) from None


def stuur(url, sleutel, winkel, aanbiedingen):
    """Stuurt de aanbiedingen naar de Edge Function en geeft de telling van save_offers terug."""
    return roep(url, sleutel, "aanbiedingen-opslaan", {"supermarkt": winkel, "aanbiedingen": aanbiedingen})


def vraag_bekend(url, sleutel, winkel):
    """De artikelnummers van een winkel die al een EAN of een hoeveelheid hebben."""
    return roep(url, sleutel, "aanbiedingen-opslaan", {"supermarkt": winkel, "vraag": "bekend"})["artikelen"]


def geef_types(url, sleutel):
    """Laat de artikelen zonder producttype beoordelen, portie voor portie. Geeft terug hoeveel er over zijn."""
    totaal = {"met_type": 0, "geen_type": 0, "nieuwe_types": 0}
    haperingen = 0
    nog = None
    while nog != 0:
        try:
            uit = roep(url, sleutel, "artikelen-classificeren", {}, wachten=300)
        except RuntimeError as fout:
            # Een enkele hapering (te druk, time-out) mag; daarna stoppen we
            haperingen += 1
            print(f"  types geven hapert: {fout}")
            if haperingen >= HAPERINGEN_MAX:
                break
            continue
        for soort in totaal:
            totaal[soort] += uit.get(soort, 0)
        nog = uit["nog"]
        if uit["beoordeeld"]:
            print(f"  {uit['beoordeeld']} artikelen beoordeeld, nog {nog}")
        # Wat overblijft krijgt geen bruikbaar oordeel: niet eindeloos opnieuw vragen
        if nog and not uit["beoordeeld"]:
            break
    print(f"Types: {totaal['met_type']} artikelen kregen een type, {totaal['geen_type']} horen bij geen enkel type.")
    if totaal["nieuwe_types"]:
        print(f"  {totaal['nieuwe_types']} nieuwe types aangemaakt; kijk ze na in de app onder Koppelingen.")
    # Termen van de lijst die nog op een oordeel wachten (het seintje vanuit de database is een keer mislukt),
    # en namen die al een type hebben maar nog geen variant: portie voor portie, tot er niets meer bijkomt
    for _ in range(RONDES_MAX):
        try:
            uit = roep(url, sleutel, "term-classificeren", {"varianten": True}, wachten=300)
        except RuntimeError as fout:
            print(f"  open termen beoordelen mislukt: {fout}")
            break
        if uit.get("beoordeeld"):
            print(f"Termen: {uit['beoordeeld']} open termen van de lijst alsnog beoordeeld.")
        if uit.get("varianten"):
            print(f"  {uit['varianten']} namen kregen een variant, nog {uit.get('nog_varianten', 0)}")
        if uit.get("fout"):
            print(f"  open termen beoordelen mislukt: {uit['fout']}")
        if not uit.get("nog_varianten") or not uit.get("varianten"):
            break
    return nog


def lees_sleutel():
    sleutel = os.environ.get("AANBIEDINGEN_SLEUTEL", "").strip()
    if not sleutel:
        sys.exit("AANBIEDINGEN_SLEUTEL is niet gezet.")
    return sleutel


def lees_winkel():
    """De winkel achter --winkel, in hoofdletters."""
    if "--winkel" not in sys.argv or sys.argv.index("--winkel") + 1 >= len(sys.argv):
        sys.exit("Geef de winkel op: --winkel " + "|".join(MINSTENS))
    winkel = sys.argv[sys.argv.index("--winkel") + 1].upper()
    if winkel not in MINSTENS:
        sys.exit(f"Onbekende winkel {winkel}; kies uit " + ", ".join(MINSTENS))
    return winkel


def main():
    echt = "--echt" in sys.argv
    if "--types" in sys.argv:
        nog = geef_types(importeren.lees_config()[0], lees_sleutel())
        if nog != 0:
            sys.exit(f"Niet alle artikelen hebben een oordeel (nog {nog if nog is not None else 'onbekend'}); draai het opnieuw.")
        return
    winkel = lees_winkel()
    if "--bekend" in sys.argv:
        try:
            nummers = vraag_bekend(importeren.lees_config()[0], lees_sleutel(), winkel)
        except RuntimeError as fout:
            sys.exit(f"Vragen welke artikelen bekend zijn mislukt: {fout}")
        pad = DATA / f"{winkel.lower()}-bekend.json"
        pad.write_text(json.dumps(nummers))
        print(f"{len(nummers)} artikelen van {winkel} zijn al bekend; hun nummers staan in {pad}.")
        return
    bestand = DATA / f"{winkel.lower()}-aanbiedingen.json"
    if not bestand.exists():
        sys.exit(f"{bestand} bestaat niet; haal de aanbiedingen eerst op.")
    week = json.loads(bestand.read_text())
    if week.get("winkel") != winkel:
        sys.exit(f"{bestand} is van {week.get('winkel') or 'een onbekende winkel'}, niet van {winkel}; haal de aanbiedingen opnieuw op.")
    aanbiedingen = [maak_aanbieding(a) for a in week["aanbiedingen"]]

    artikelen = [art for a in aanbiedingen for art in a["articles"]]
    zonder_id = [art for art in artikelen if not art["article_id"]]
    mislukt = [a for a in aanbiedingen if not a["complete"]]
    print(f"{winkel} van {week['van']} tot {week['tot']}, opgehaald {week['opgehaald']}: "
          f"{len(aanbiedingen)} aanbiedingen, {len(artikelen)} artikelen.")
    met = lambda veld: sum(1 for art in artikelen if art[veld])
    print(f"  {met('quantity')} artikelen met een hoeveelheid, {met('ean')} met een EAN, "
          f"{sum(1 for a in aanbiedingen if not a['discount_text'])} aanbiedingen zonder kortingstekst.")
    if zonder_id:
        print(f"{len(zonder_id)} artikelen hebben geen artikelnummer en worden overgeslagen: "
              + ", ".join(art["title"] for art in zonder_id[:5]) + (" ..." if len(zonder_id) > 5 else ""))
    for a in mislukt:
        print(f"Artikelen ophalen mislukt bij: {a['title']}")
    if len(aanbiedingen) < MINSTENS[winkel]:
        sys.exit(f"Minder dan {MINSTENS[winkel]} aanbiedingen: dit lijkt geen hele week, er wordt niets opgeslagen.")

    if not echt:
        print("PROEF: er is niets opgeslagen (gebruik --echt om op te slaan).")
        return

    sleutel = lees_sleutel()
    url, _ = importeren.lees_config()
    try:
        uit = stuur(url, sleutel, winkel, aanbiedingen)
    except RuntimeError as fout:
        sys.exit(f"Opslaan mislukt: {fout}")
    print(f"Opgeslagen: {uit['aanbiedingen']} aanbiedingen met {uit['artikelen_in_aanbiedingen']} artikelen, "
          f"waarvan {uit['nieuwe_artikelen']} nieuw in de artikeltabel (nu {uit['artikelen_totaal']}). "
          f"{uit['opgeruimd']} verlopen aanbiedingen opgeruimd.")
    nog = geef_types(url, sleutel)
    if mislukt:
        # Wel opgeslagen wat er was, maar de taak moet als mislukt opvallen
        sys.exit(f"{len(mislukt)} groepen zijn zonder artikelen opgeslagen; draai het ophalen opnieuw.")
    if nog != 0:
        sys.exit(f"Niet alle artikelen hebben een type-oordeel (nog {nog if nog is not None else 'onbekend'}); de aanbiedingen zijn wel opgeslagen.")


if __name__ == "__main__":
    main()
