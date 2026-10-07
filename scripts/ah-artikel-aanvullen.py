#!/usr/bin/env python3
"""Vult het artikel-ID aan bij AH-aankopen die al in de database staan (roadmap stap 2).

De aankopen zijn eerder geïmporteerd zonder het product_id van de bon. Dit script zoekt bij elke aankoop
de bon terug in data/ah-bonnen.json (supermarkt AH, datum en totaal) en daarop de bontekst (receipt_name),
en zet het product_id van die regel als article_id bij de aankoop. Een bestaand ID wordt nooit overschreven.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/ah-artikel-aanvullen.py           proef: telt wat er zou gebeuren, schrijft niets
  python3 scripts/ah-artikel-aanvullen.py --echt    vult de ID's aan

Je logt in met het e-mailadres en wachtwoord van de app; het wachtwoord wordt nergens bewaard.
"""
import getpass
import importlib.util
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

# De naam ah-importeren.py heeft een streepje en is dus niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)

PER_KEER = 500

AL_GEVULD = "hadden al een artikel-ID"
GEEN_BON = "bon staat niet in ah-bonnen.json (bijv. een gescande bon)"
GEEN_TEKST = "aankoop heeft geen bontekst"
NIET_OP_BON = "bontekst staat niet op die bon"
MEERDERE = "meerdere artikelen samengevoegd in één aankoop"


def centen(bedrag):
    return None if bedrag is None else round(float(bedrag) * 100)


def artikelen_per_bon(ruw):
    """(datum, totaal in centen) -> { bontekst: { artikel-ID's } } voor alle bonnen uit ah-bonnen.json."""
    bonnen = defaultdict(lambda: defaultdict(set))
    for bon in ruw:
        teksten = bonnen[(importeren.bondatum(bon), centen(bon["totaal"]))]
        for r in bon["regels"]:
            if r["naam"] in importeren.OVERSLAAN or r["aantal"] <= 0 or not importeren.artikel_id(r):
                continue
            teksten[r["naam"]].add(importeren.artikel_id(r))
    return bonnen


def zoek_artikel(aankoop, bon, bonnen):
    """Geeft (artikel-ID, None) of (None, reden waarom er geen ID is)."""
    if aankoop.get("article_id"):
        return None, AL_GEVULD
    teksten = bonnen.get((bon["receipt_date"], centen(bon["total"])))
    if teksten is None:
        return None, GEEN_BON
    if not aankoop.get("receipt_name"):
        return None, GEEN_TEKST
    # De oude import voegde regels met dezelfde naam samen: "TEKST A + TEKST B"
    ids = set()
    for tekst in aankoop["receipt_name"].split(" + "):
        ids |= teksten.get(tekst, set())
    if not ids:
        return None, NIET_OP_BON
    if len(ids) > 1:
        return None, MEERDERE
    return ids.pop(), None


def haal_alles(db, pad):
    """Alle rijen van een tabel; de API geeft er hoogstens 1000 per keer."""
    rijen, vanaf = [], 0
    while True:
        deel = db.vraag(f"{pad}&order=id&limit=1000&offset={vanaf}")
        rijen += deel
        if len(deel) < 1000:
            return rijen
        vanaf += 1000


def haal_aankopen(db, lijst):
    """De aankopen van AH-bonnen in deze lijst, met hun bon."""
    bonnen = {b["id"]: b for b in haal_alles(db, f"/rest/v1/receipts?select=id,store,receipt_date,total&list_id=eq.{lijst}")
              if b["store"].strip().upper() == importeren.SUPERMARKT}
    aankopen = haal_alles(db, "/rest/v1/purchases?select=id,name,receipt_id,receipt_name,article_id"
                              f"&list_id=eq.{lijst}&receipt_id=not.is.null")
    return [(a, bonnen[a["receipt_id"]]) for a in aankopen if a["receipt_id"] in bonnen]


def main():
    echt = "--echt" in sys.argv
    if not importeren.BONNEN.exists():
        sys.exit(f"{importeren.BONNEN} bestaat niet; haal eerst de bonnen op met scripts/ah-bonnen.")
    bonnen = artikelen_per_bon(b for b in json.loads(importeren.BONNEN.read_text()) if b.get("compleet"))
    print("ECHT: de artikel-ID's worden opgeslagen." if echt else "PROEF: er wordt niets opgeslagen (gebruik --echt om op te slaan).")

    db = importeren.Supabase(*importeren.lees_config())
    try:
        gebruiker = db.login(input("\nE-mailadres van de app: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
    except RuntimeError as fout:
        sys.exit(f"Inloggen mislukt: {fout}")
    print("Ingelogd.")
    lijst = importeren.kies_lijst(db, gebruiker)

    aankopen = haal_aankopen(db, lijst["id"])
    vullen, redenen, voorbeelden = [], Counter(), defaultdict(list)
    for aankoop, bon in aankopen:
        artikel, reden = zoek_artikel(aankoop, bon, bonnen)
        if artikel:
            vullen.append({"purchase_id": aankoop["id"], "article_id": artikel})
        else:
            redenen[reden] += 1
            if len(voorbeelden[reden]) < 5:
                voorbeelden[reden].append(f"{bon['receipt_date']} {aankoop['name']} ({aankoop['receipt_name'] or 'geen bontekst'})")

    al = redenen.pop(AL_GEVULD, 0)
    woord = "krijgen" if echt else "zouden krijgen"
    print(f"\nLijst \"{lijst['name']}\": {len(aankopen)} aankopen van AH-bonnen.")
    print(f"  {len(vullen)} {woord} een artikel-ID")
    print(f"  {al} {AL_GEVULD}")
    print(f"  {sum(redenen.values())} krijgen er geen:")
    for reden, aantal in redenen.most_common():
        print(f"    {aantal} × {reden}")
        for voorbeeld in voorbeelden[reden]:
            print(f"        {voorbeeld}")

    if not echt:
        return
    gevuld = 0
    for vanaf in range(0, len(vullen), PER_KEER):
        gevuld += db.rpc("fill_article_ids", p_rows=vullen[vanaf:vanaf + PER_KEER])
    print(f"\n{gevuld} aankopen hebben een artikel-ID gekregen.")
    # Opnieuw tellen in de database, zodat de telling hierboven te controleren is
    nu = haal_aankopen(db, lijst["id"])
    met = sum(1 for a, _ in nu if a["article_id"])
    print(f"In de database nu: {met} van de {len(nu)} aankopen van AH-bonnen met een artikel-ID, {len(nu) - met} zonder.")


if __name__ == "__main__":
    main()
