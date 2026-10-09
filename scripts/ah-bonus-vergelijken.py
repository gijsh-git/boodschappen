#!/usr/bin/env python3
"""Legt de AH-bonus van één week (data/ah-bonus.json, zie scripts/ah-bonus) naast wat we bij AH kopen
(data/ah-bonnen.json, zie scripts/ah-bonnen). Verkenning: het schrijft niets, het telt alleen.

Twee manieren om een aanbieding aan een aankoop te koppelen:
  via ID    het product_id op de bon is het hq_id van een artikel in de aanbieding: precies dat artikel
  via naam  de naam van het product komt als hele woorden voor in de titel van een artikel in de aanbieding

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/ah-bonus-vergelijken.py           producten = de leesbare namen uit data/ah-namen.json
  python3 scripts/ah-bonus-vergelijken.py --alles   toon alle treffers in plaats van een paar voorbeelden

De optie --producten (de samengevoegde producten uit de oude catalogus) is vervallen met die catalogus.
"""
import importlib.util
import json
import re
import sys
import unicodedata
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

HOOFDMAP = Path(__file__).resolve().parent.parent
BONUS = HOOFDMAP / "data" / "ah-bonus.json"
BONNEN = HOOFDMAP / "data" / "ah-bonnen.json"
NAMEN = HOOFDMAP / "data" / "ah-namen.json"
# Vanaf zoveel aankoopdagen noemen we iets een vast product (het aankoopprofiel toont het interval ook vanaf 3)
VAST = 3
# "Kopen we nog": laatst gekocht binnen zoveel dagen
RECENT = 365

# Het importscript heeft een streepje in de naam en is daardoor niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)


def woorden(tekst):
    """Kleine letters zonder accenten, als losse woorden."""
    kaal = unicodedata.normalize("NFKD", tekst.lower()).encode("ascii", "ignore").decode()
    return re.findall(r"[a-z0-9]+", kaal)


def stam(woord):
    """Heel grof enkelvoud, zodat "aardappelen" bij "aardappel" past en "eieren" bij "ei" niet per ongeluk."""
    for uitgang in ("en", "s"):
        if len(woord) > len(uitgang) + 3 and woord.endswith(uitgang):
            return woord[: -len(uitgang)]
    return woord


def past_op_titel(product_woorden, titel_woorden):
    """Alle woorden van het product staan als heel woord in de titel."""
    return bool(product_woorden) and product_woorden <= titel_woorden


def main():
    alles = "--alles" in sys.argv
    for pad in (BONUS, BONNEN):
        if not pad.exists():
            sys.exit(f"{pad} bestaat niet; haal het eerst op (zie scripts/ah-bonus en scripts/ah-bonnen).")
    week = json.loads(BONUS.read_text())
    bonnen = [b for b in json.loads(BONNEN.read_text()) if b.get("compleet")]
    namen = json.loads(NAMEN.read_text()) if NAMEN.exists() else {}
    def product(bon_naam):
        return importeren.leesbaar(bon_naam, namen)

    # ---------- Wat we kopen ----------
    # per bon-ID en per product: op welke dagen gekocht
    id_dagen, id_teksten, id_product = defaultdict(set), defaultdict(set), {}
    product_dagen, product_ids = defaultdict(set), defaultdict(set)
    zonder_id = 0
    for b in bonnen:
        moment = datetime.fromisoformat(b["datum"].replace("Z", "+00:00"))
        dag = moment.astimezone(ZoneInfo("Europe/Amsterdam")).date()
        for r in b["regels"]:
            if r["naam"] in importeren.OVERSLAAN or r["aantal"] <= 0:
                continue
            p = product(r["naam"])
            product_dagen[p].add(dag)
            pid = r.get("product_id")
            if not pid:
                zonder_id += 1
                continue
            id_dagen[pid].add(dag)
            id_teksten[pid].add(r["naam"])
            id_product[pid] = p
            product_ids[p].add(pid)

    grens = date.fromisoformat(week["van"]) - timedelta(days=RECENT)

    def vast(dagen):
        return len(dagen) >= VAST and max(dagen) >= grens

    vaste_producten = {p for p, d in product_dagen.items() if vast(d)}
    alle_dagen = sorted(d for dagen in product_dagen.values() for d in dagen)
    print(f"Bonus van {week['van']} tot {week['tot']}: {len(week['aanbiedingen'])} aanbiedingen, "
          f"{sum(len(a['artikelen']) for a in week['aanbiedingen'])} artikelen.")
    print(f"Bonnen: {len(bonnen)} van {alle_dagen[0]} tot {alle_dagen[-1]}, {len(id_dagen)} verschillende bon-ID's, "
          f"{len(product_dagen)} producten (namen uit ah-namen.json).")
    print(f"Vaste producten (minstens {VAST} aankoopdagen, laatste binnen {RECENT} dagen): {len(vaste_producten)}.")
    if zonder_id:
        print(f"{zonder_id} bonregels hebben geen product_id.")
    meer_ids = {p: ids for p, ids in product_ids.items() if len(ids) > 1}
    print(f"{len(meer_ids)} producten staan onder meer dan één bon-ID op de bonnen (ander merk, formaat of soort).")

    # ---------- Per aanbieding: wat raakt hij ----------
    product_woorden = {p: frozenset(stam(w) for w in woorden(p)) for p in product_dagen}
    # Eerst op één woord zoeken, dan pas de rest controleren; anders is het 2400 x 500 vergelijkingen
    per_woord = defaultdict(set)
    for p, ws in product_woorden.items():
        for w in ws:
            per_woord[w].add(p)

    rijen = []
    for a in week["aanbiedingen"]:
        via_id = {}    # artikel-titel -> product, voor artikelen die we zelf gekocht hebben
        via_naam = defaultdict(list)  # product -> titels van artikelen die erop lijken
        for art in a["artikelen"]:
            pid = art.get("hq_id")
            if pid in id_dagen:
                via_id[art["titel"]] = (id_product[pid], pid)
            tw = frozenset(stam(w) for w in woorden(art["titel"]))
            for p in {p for w in tw for p in per_woord.get(w, ())}:
                if past_op_titel(product_woorden[p], tw):
                    via_naam[p].append(art["titel"])
        rijen.append({"a": a, "id": via_id, "naam": via_naam,
                      "id_producten": {p for p, _ in via_id.values()}})

    def tel(voorwaarde):
        return sum(1 for r in rijen if voorwaarde(r))

    n = len(rijen)
    print("\n== Hoeveel aanbiedingen raken iets wat we kopen ==")
    print(f"{'':34}{'alles ooit':>12}{'vaste producten':>18}")
    regels = [
        ("via ID (precies dat artikel)", lambda r: r["id"], lambda r: r["id_producten"] & vaste_producten),
        ("via naam", lambda r: r["naam"], lambda r: set(r["naam"]) & vaste_producten),
        ("via ID en naam allebei", lambda r: r["id"] and r["naam"],
         lambda r: r["id_producten"] & vaste_producten and set(r["naam"]) & vaste_producten),
        ("alleen via ID", lambda r: r["id"] and not r["naam"],
         lambda r: r["id_producten"] & vaste_producten and not set(r["naam"]) & vaste_producten),
        ("alleen via naam", lambda r: r["naam"] and not r["id"],
         lambda r: set(r["naam"]) & vaste_producten and not r["id_producten"] & vaste_producten),
    ]
    for titel, ooit, vaste in regels:
        print(f"{titel:34}{tel(ooit):>8} / {n}{tel(vaste):>14} / {n}")

    artikelen_geraakt = {pid for r in rijen for _, pid in r["id"].values()}
    print(f"\nVan onze {len(id_dagen)} bon-ID's zijn er deze week {len(artikelen_geraakt)} in de bonus.")
    print(f"Van onze {len(vaste_producten)} vaste producten: {len({p for r in rijen for p in r['id_producten']} & vaste_producten)} "
          f"via ID geraakt, {len({p for r in rijen for p in r['naam']} & vaste_producten)} via naam.")

    def kop(tekst):
        print(f"\n== {tekst} ==")

    def toon(lijst, maximum=12):
        for regel in lijst if alles else lijst[:maximum]:
            print("  " + regel)
        if not alles and len(lijst) > maximum:
            print(f"  ... en nog {len(lijst) - maximum} (gebruik --alles)")

    def dagen_tekst(p):
        d = product_dagen[p]
        return f"{len(d)}x, laatst {max(d)}"

    kop("Via ID: aanbiedingen met een artikel dat we zelf gekocht hebben (vaste producten eerst)")
    uit = []
    for r in sorted(rijen, key=lambda r: -max((len(product_dagen[p]) for p in r["id_producten"]), default=0)):
        if not r["id"]:
            continue
        a = r["a"]
        wat = "; ".join(f"{t} = {p} ({dagen_tekst(p)})" for t, (p, _) in list(r["id"].items())[:3])
        meer = f" +{len(r['id']) - 3}" if len(r["id"]) > 3 else ""
        uit.append(f"{a['titel']} [{a['korting']}], {len(r['id'])} van {len(a['artikelen'])} artikelen: {wat}{meer}")
    toon(uit, 25)

    kop("Alleen via naam: vast product, maar een ander artikel dan we kochten (ander merk of formaat, of een misser)")
    uit = []
    for r in rijen:
        for p in sorted(set(r["naam"]) & vaste_producten - r["id_producten"], key=lambda p: -len(product_dagen[p])):
            titels = r["naam"][p]
            uit.append(f"{p} ({dagen_tekst(p)}) ~ {r['a']['titel']} [{r['a']['korting']}]: "
                       f"{'; '.join(titels[:3])}{f' +{len(titels) - 3}' if len(titels) > 3 else ''}")
    toon(uit, 30)

    kop("Alleen via ID: het artikel is van ons, maar de naam van het product staat niet in de titel")
    uit = []
    for r in rijen:
        for titel, (p, pid) in r["id"].items():
            if p not in r["naam"]:
                uit.append(f"{p} ({dagen_tekst(p)}), bontekst {' / '.join(sorted(id_teksten[pid]))} = {titel}")
    toon(uit, 30)

    kop("Brede groepen: hoeveel van de artikelen in een geraakte groep kochten we zelf")
    uit = []
    for r in sorted(rijen, key=lambda r: -len(r["a"]["artikelen"])):
        if r["id"] and len(r["a"]["artikelen"]) >= 20:
            uit.append(f"{r['a']['titel']}: {len(r['id'])} van {len(r['a']['artikelen'])}")
    toon(uit, 15)

    kop("Producten onder meer dan één bon-ID (de naam zegt hier meer dan het ID)")
    uit = [f"{p} ({dagen_tekst(p)}): {len(ids)} ID's, bonteksten {', '.join(sorted({t for i in ids for t in id_teksten[i]})[:6])}"
           for p, ids in sorted(meer_ids.items(), key=lambda x: -len(x[1]))]
    toon(uit, 15)


if __name__ == "__main__":
    main()
