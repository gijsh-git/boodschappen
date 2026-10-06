#!/usr/bin/env python3
"""Zet de opgehaalde AH-bonnen (data/ah-bonnen.json, zie scripts/ah-bonnen) als bonnen en aankopen in een lijst.

Gebruikt dezelfde opslag als "Bon scannen" in de app: receipt_exists, match_receipt_lines en save_receipt.
Daardoor telt niets dubbel: een bon met dezelfde supermarkt, datum en totaal wordt overgeslagen (ook bij
opnieuw draaien, en ook als je hem al gescand had), en een product telt per dag één keer.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/ah-importeren.py           proef: laat zien wat er zou gebeuren, schrijft niets
  python3 scripts/ah-importeren.py --echt    slaat de bonnen op

Je logt in met het e-mailadres en wachtwoord van de app; het wachtwoord wordt nergens bewaard.
"""
import getpass
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

HOOFDMAP = Path(__file__).resolve().parent.parent
BONNEN = HOOFDMAP / "data" / "ah-bonnen.json"
# Optioneel: { "AH JB PLAKKEN": "jong belegen kaas plakken" } om bonteksten leesbaar te maken
NAMEN = HOOFDMAP / "data" / "ah-namen.json"
SUPERMARKT = "AH"
# Geen producten: toeslag op wegwerpverpakkingen
OVERSLAAN = {"HEFFING SUP"}


def lees_config():
    tekst = (HOOFDMAP / "config.js").read_text()
    url = re.search(r'SUPABASE_URL:\s*"([^"]+)"', tekst).group(1)
    sleutel = re.search(r'SUPABASE_ANON_KEY:\s*"([^"]+)"', tekst).group(1)
    return url, sleutel


def kaal(tekst):
    """Hoofdletters zonder spaties en leestekens, om bontekst en kortingsnaam te vergelijken."""
    return re.sub(r"[^A-Z0-9]", "", tekst.upper())


def leesbaar(bon_naam, namen):
    """De naam van de aankoop: uit ah-namen.json, anders de bontekst in kleine letters zonder huismerk."""
    if bon_naam in namen:
        return namen[bon_naam]
    return re.sub(r"^ah\s+", "", bon_naam.strip().lower())


def past(bon_naam, actie):
    """Hoe goed past een bonregel bij de naam van een korting? 2 = een heel woord komt erin voor,
    1 = het begin van een woord (beide teksten zijn afgekapt of afgekort), 0 = niet."""
    woorden = [kaal(w) for w in bon_naam.split()]
    woorden = [w for w in woorden if len(w) >= 4]
    if any(w in actie for w in woorden):
        return 2
    for w in woorden:
        # "RUNDERGEHAKT" bij "AHRUNDERGEHA": de kortingsnaam houdt na 12 tekens op
        if any(actie.endswith(w[:n]) for n in range(4, len(w))):
            return 1
        # "KIPDIJREEP" bij "AHKIPDIJSHOA": de eerste vijf letters komen overeen
        if len(w) >= 5 and w[:5] in actie:
            return 1
    return 0


def verdeel_kortingen(regels, kortingen):
    """Zet elke korting van de bon bij de regel(s) waar ze bij hoort. Geeft het aantal niet-geplaatste terug.

    AH noemt de korting naar de actie, aan elkaar en afgekapt ("AHAVOCADOPER", "ALLEHIPRO"). De regels die
    het best passen (zie past()) krijgen de korting; zijn dat er meer, dan naar verhouding van de prijs.
    """
    los = 0
    for k in kortingen:
        bedrag = round(-k["bedrag"], 2)
        if bedrag <= 0:
            continue
        actie = kaal(k["naam"])
        scores = [past(r["receipt_name"], actie) for r in regels]
        beste = max(scores, default=0)
        passend = [r for r, score in zip(regels, scores) if beste and score == beste]
        if not passend:
            los += 1
            continue
        totaal = sum(r["price"] for r in passend)
        rest = bedrag
        for i, r in enumerate(passend):
            deel = rest if i == len(passend) - 1 else round(bedrag * r["price"] / totaal, 2)
            rest = round(rest - deel, 2)
            r["discount"] = round((r["discount"] or 0) + deel, 2)
    for r in regels:
        # Nooit meer korting dan de regel kostte
        if r["discount"] is not None:
            r["discount"] = min(r["discount"], r["price"])
    return los


def maak_bon(bon, namen):
    """Een bon uit ah-bonnen.json omzetten naar de invoer van save_receipt."""
    # AH geeft de tijd in UTC; de bondatum is de dag in Nederland
    moment = datetime.fromisoformat(bon["datum"].replace("Z", "+00:00"))
    datum = moment.astimezone(ZoneInfo("Europe/Amsterdam")).date().isoformat()
    # Hetzelfde product op meerdere regels wordt één regel, net als bij het scannen. Dat geldt ook voor
    # bonteksten die dezelfde leesbare naam krijgen: de database telt een naam per dag maar één keer.
    per_naam = {}
    for r in bon["regels"]:
        if r["naam"] in OVERSLAAN or r["aantal"] <= 0:
            continue
        naam = leesbaar(r["naam"], namen)
        regel = per_naam.setdefault(naam, {
            "name": naam, "receipt_name": r["naam"],
            "aantal": 0, "price": 0, "discount": None, "purchase_id": None,
        })
        if r["naam"] not in regel["receipt_name"].split(" + "):
            regel["receipt_name"] += " + " + r["naam"]
        regel["aantal"] += r["aantal"]
        regel["price"] = round(regel["price"] + r["bedrag"], 2)
    regels = list(per_naam.values())
    los = verdeel_kortingen(regels, bon["kortingen"])
    for r in regels:
        r["quantity"] = str(r.pop("aantal"))
    return {"datum": datum, "totaal": bon["totaal"], "regels": regels, "kortingen_los": los}


class Supabase:
    def __init__(self, url, sleutel):
        self.url, self.sleutel, self.token = url, sleutel, None

    def vraag(self, pad, body=None):
        kop = {"apikey": self.sleutel, "Content-Type": "application/json"}
        if self.token:
            kop["Authorization"] = "Bearer " + self.token
        data = json.dumps(body).encode() if body is not None else None
        verzoek = urllib.request.Request(self.url + pad, data=data, headers=kop)
        try:
            with urllib.request.urlopen(verzoek, timeout=30) as antwoord:
                tekst = antwoord.read().decode()
                return json.loads(tekst) if tekst else None
        except urllib.error.HTTPError as fout:
            tekst = fout.read().decode()
            try:
                inhoud = json.loads(tekst)
                melding = inhoud.get("message") or inhoud.get("msg") or inhoud.get("error_description") or tekst
            except ValueError:
                melding = tekst
            raise RuntimeError(melding) from None

    def login(self, email, wachtwoord):
        antwoord = self.vraag("/auth/v1/token?grant_type=password", {"email": email, "password": wachtwoord})
        self.token = antwoord["access_token"]
        return antwoord["user"]["id"]

    def rpc(self, naam, **parameters):
        return self.vraag("/rest/v1/rpc/" + naam, parameters)


def kies_lijst(db, gebruiker):
    rijen = db.vraag("/rest/v1/list_members?select=lists(id,name,counts_for_profile,archived_at)&user_id=eq." + gebruiker)
    lijsten = [r["lists"] for r in rijen if r["lists"] and r["lists"]["counts_for_profile"] and not r["lists"]["archived_at"]]
    if not lijsten:
        sys.exit("Je hebt geen actieve lijst die meetelt voor het aankoopprofiel.")
    print("\nIn welke lijst moeten de bonnen komen?")
    for i, lijst in enumerate(lijsten, 1):
        print(f"  {i}. {lijst['name']}")
    while True:
        keuze = input("Nummer: ").strip()
        if keuze.isdigit() and 1 <= int(keuze) <= len(lijsten):
            return lijsten[int(keuze) - 1]


def main():
    echt = "--echt" in sys.argv
    if not BONNEN.exists():
        sys.exit(f"{BONNEN} bestaat niet; haal eerst de bonnen op met scripts/ah-bonnen.")
    namen = json.loads(NAMEN.read_text()) if NAMEN.exists() else {}
    ruw = [b for b in json.loads(BONNEN.read_text()) if b.get("compleet")]
    # Oudste eerst, zodat de aankopen in volgorde van kopen worden toegevoegd
    bonnen = sorted((maak_bon(b, namen) for b in ruw), key=lambda b: b["datum"])
    leeg = [b for b in bonnen if not b["regels"]]
    bonnen = [b for b in bonnen if b["regels"]]
    print(f"{len(bonnen)} bonnen van {bonnen[0]['datum']} tot {bonnen[-1]['datum']}, "
          f"{sum(len(b['regels']) for b in bonnen)} regels ({len(leeg)} bonnen zonder producten overgeslagen).")
    print(f"{sum(b['kortingen_los'] for b in bonnen)} kortingen konden niet bij een product worden gezet en vervallen.")
    print("ECHT: de bonnen worden opgeslagen." if echt else "PROEF: er wordt niets opgeslagen (gebruik --echt om op te slaan).")

    db = Supabase(*lees_config())
    try:
        gebruiker = db.login(input("\nE-mailadres van de app: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
    except RuntimeError as fout:
        sys.exit(f"Inloggen mislukt: {fout}")
    print("Ingelogd.")
    lijst = kies_lijst(db, gebruiker)

    tel = {"bonnen": 0, "dubbel": 0, "mislukt": 0, "toegevoegd": 0, "gekoppeld": 0, "overgeslagen": 0}
    for nr, bon in enumerate(bonnen, 1):
        try:
            if db.rpc("receipt_exists", p_list=lijst["id"], p_store=SUPERMARKT, p_date=bon["datum"], p_total=bon["totaal"]):
                tel["dubbel"] += 1
                continue
            # Regels die lijken op een aankoop van dezelfde dag komen bij die aankoop in plaats van erbij
            koppels = db.rpc("match_receipt_lines", p_list=lijst["id"], p_date=bon["datum"],
                             p_names=[r["name"] for r in bon["regels"]])
            for k in koppels:
                bon["regels"][k["regel"] - 1]["purchase_id"] = k["purchase_id"]
            if echt:
                uitkomst = db.rpc("save_receipt", p_list=lijst["id"], p_store=SUPERMARKT, p_date=bon["datum"],
                                  p_total=bon["totaal"], p_lines=bon["regels"])
                for soort in ("toegevoegd", "gekoppeld", "overgeslagen"):
                    tel[soort] += uitkomst[soort]
            else:
                gekoppeld = sum(1 for r in bon["regels"] if r["purchase_id"])
                tel["gekoppeld"] += gekoppeld
                tel["toegevoegd"] += len(bon["regels"]) - gekoppeld
            tel["bonnen"] += 1
        except RuntimeError as fout:
            tel["mislukt"] += 1
            print(f"Bon van {bon['datum']} (€ {bon['totaal']:.2f}) mislukt: {fout}")
        if nr % 25 == 0:
            print(f"  {nr} van {len(bonnen)}")

    woord = "opgeslagen" if echt else "zouden worden opgeslagen"
    print(f"\nLijst \"{lijst['name']}\": {tel['bonnen']} bonnen {woord}, {tel['dubbel']} stonden er al in, {tel['mislukt']} mislukt.")
    print(f"Regels: {tel['toegevoegd']} nieuwe aankopen, {tel['gekoppeld']} gekoppeld aan een bestaande aankoop"
          + (f", {tel['overgeslagen']} overgeslagen (die dag al geteld)." if echt else " (in de proef bij benadering)."))


if __name__ == "__main__":
    main()
