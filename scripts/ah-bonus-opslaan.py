#!/usr/bin/env python3
"""Zet de opgehaalde AH-bonus (data/ah-bonus.json, zie scripts/ah-bonus) in de database (roadmap stap 3).

Stuurt de week naar de Edge Function aanbiedingen-opslaan, die de databasefunctie save_offers aanroept: artikelen en aanbiedingen worden toegevoegd of bijgewerkt,
dus opnieuw draaien met dezelfde week voegt niets dubbel toe. Het hq_id van AH gaat mee als article_id,
hetzelfde nummer als op de kassabon. Verlopen aanbiedingen ruimt de functie zelf op.

Daarna krijgen de artikelen die nog geen producttype hebben er een: de Edge Function artikelen-classificeren
laat de AI ze in porties beoordelen (titel, merk en categorie als invoer). Per week zijn dat alleen de nieuwe
artikelen; een artikel wordt één keer beoordeeld. Bij hetzelfde oordeel hoort de variant (de smaak of soort
binnen het type); een artikel of naam met een type en zonder variant krijgt die alsnog.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/ah-bonus-opslaan.py           proef: telt wat er zou gebeuren, schrijft niets
  python3 scripts/ah-bonus-opslaan.py --echt    slaat de week op en geeft nieuwe artikelen een type
  python3 scripts/ah-bonus-opslaan.py --types   slaat niets op, geeft alleen artikelen zonder type een type

Voor --echt is AANBIEDINGEN_SLEUTEL nodig: dezelfde waarde als de secret met die naam in Supabase. Met
die sleutel kun je alleen aanbiedingen opslaan; de service role key komt Supabase niet uit. Zet hem in
.env of als secret in GitHub, nooit in de code. De wekelijkse taak staat in .github/workflows/ah-bonus.yml.
"""
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

# De naam ah-importeren.py heeft een streepje en is dus niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)

BONUS = importeren.HOOFDMAP / "data" / "ah-bonus.json"
# Een week met minder aanbiedingen dan dit is vrijwel zeker een mislukte ophaalronde
MINSTENS = 20
# Zo vaak mag het geven van types haperen voordat het script ermee stopt
HAPERINGEN_MAX = 3
# Zoveel porties namen krijgen per keer hooguit een variant
RONDES_MAX = 50


def tekst(waarde):
    return None if waarde in (None, "", 0) else str(waarde)


def maak_aanbieding(a):
    """Eén aanbieding uit ah-bonus.json in de vorm die save_offers verwacht."""
    artikelen = []
    for art in a["artikelen"]:
        artikelen.append({
            "article_id": tekst(art.get("hq_id")),
            "webshop_id": tekst(art.get("webshop_id")),
            "title": art["titel"],
            "brand": art.get("merk"),
            "size": art.get("inhoud"),
            "category": art.get("categorie"),
            "price": art.get("prijs"),
            "bonus_price": art.get("bonusprijs"),
        })
    return {
        "offer_id": a["id"],
        "title": a["titel"],
        "discount_text": a.get("korting"),
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


def stuur(url, sleutel, aanbiedingen):
    """Stuurt de aanbiedingen naar de Edge Function en geeft de telling van save_offers terug."""
    return roep(url, sleutel, "aanbiedingen-opslaan", {"supermarkt": importeren.SUPERMARKT, "aanbiedingen": aanbiedingen})


def geef_types(url, sleutel):
    """Laat de artikelen zonder producttype beoordelen, portie voor portie. Geeft terug hoeveel er over zijn."""
    totaal = {"met_type": 0, "geen_type": 0}
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
            totaal[soort] += uit[soort]
        nog = uit["nog"]
        if uit["beoordeeld"]:
            print(f"  {uit['beoordeeld']} artikelen beoordeeld, nog {nog}")
        # Wat overblijft krijgt geen bruikbaar oordeel: niet eindeloos opnieuw vragen
        if nog and not uit["beoordeeld"]:
            break
    print(f"Types: {totaal['met_type']} artikelen kregen een type, {totaal['geen_type']} horen bij geen enkel type.")
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


def main():
    echt = "--echt" in sys.argv
    if "--types" in sys.argv:
        sleutel = os.environ.get("AANBIEDINGEN_SLEUTEL", "").strip()
        if not sleutel:
            sys.exit("AANBIEDINGEN_SLEUTEL is niet gezet.")
        nog = geef_types(importeren.lees_config()[0], sleutel)
        if nog != 0:
            sys.exit(f"Niet alle artikelen hebben een oordeel (nog {nog if nog is not None else 'onbekend'}); draai het opnieuw.")
        return
    if not BONUS.exists():
        sys.exit(f"{BONUS} bestaat niet; haal de bonus eerst op (zie scripts/ah-bonus).")
    week = json.loads(BONUS.read_text())
    aanbiedingen = [maak_aanbieding(a) for a in week["aanbiedingen"]]

    artikelen = [art for a in aanbiedingen for art in a["articles"]]
    zonder_id = [art for art in artikelen if not art["article_id"]]
    mislukt = [a for a in aanbiedingen if not a["complete"]]
    print(f"Bonus van {week['van']} tot {week['tot']}, opgehaald {week['opgehaald']}: "
          f"{len(aanbiedingen)} aanbiedingen, {len(artikelen)} artikelen.")
    if zonder_id:
        print(f"{len(zonder_id)} artikelen hebben geen hq_id en worden overgeslagen: "
              + ", ".join(art["title"] for art in zonder_id[:5]) + (" ..." if len(zonder_id) > 5 else ""))
    for a in mislukt:
        print(f"Artikelen ophalen mislukt bij: {a['title']}")
    if len(aanbiedingen) < MINSTENS:
        sys.exit(f"Minder dan {MINSTENS} aanbiedingen: dit lijkt geen hele week, er wordt niets opgeslagen.")

    if not echt:
        print("PROEF: er is niets opgeslagen (gebruik --echt om op te slaan).")
        return

    sleutel = os.environ.get("AANBIEDINGEN_SLEUTEL", "").strip()
    if not sleutel:
        sys.exit("AANBIEDINGEN_SLEUTEL is niet gezet.")
    url, _ = importeren.lees_config()
    try:
        uit = stuur(url, sleutel, aanbiedingen)
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
