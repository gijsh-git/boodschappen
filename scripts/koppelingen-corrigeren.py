#!/usr/bin/env python3
"""Corrigeert de koppelingen artikel → product na het nalezen van 8 oktober 2026.

scripts/artikel-koppelingen-exporteren.py zette alle oordelen van de beheerder onder elkaar; bij het nalezen
kwamen fouten naar boven (zero-varianten bij het gewone product, systeemmesjes bij scheermesjes, potgroente bij
verse groente) en dubbele producten die volgens docs/productregels.md één product zijn. Dit script voert de
correcties uit die toen zijn besloten, in deze volgorde:

1. Losmaken: de goedgekeurde koppeling verdwijnt en telt als afwijzing van die combinatie (reject_article_link).
   Eerst de titels uit LOSMAKEN, daarna de algemene regel: elk artikel met "zero" in de titel, bij welk
   product het ook staat.
2. Verplaatsen: losmaken bij het ene product en goedkeuren bij het andere (reject_article_link,
   save_article_proposals, approve_article_links).
3. Samenvoegen van dubbele producten (merge_products; terug te draaien met "Losmaken" in het scherm Producten).
4. Hernoemen van producten met een merk in de naam (rename_product).

Losmaken is definitief: een afgewezen combinatie wordt nooit opnieuw voorgesteld en er is geen functie om een
afwijzing terug te draaien. Draai daarom eerst de proef en lees na wat er gebeurt.

Alles gaat via functies die de beheerdersrol controleren; de database ziet dit als het werk van de beheerder.

Gebruik, vanuit de hoofdmap van het project:
  python3 scripts/koppelingen-corrigeren.py          proef: laat zien wat er gebeurt, verandert niets
  python3 scripts/koppelingen-corrigeren.py --echt   voert het uit

Een titel die eindigt op "*" is een begin van titels; "*" alleen betekent alle artikelen van dat product.
Titels worden zonder hoofdletters vergeleken. Staat iets niet (meer) in de database, dan meldt het script dat
en slaat het over, zodat je het gerust twee keer kunt draaien.
"""
import getpass
import importlib.util
import re
import sys
from pathlib import Path

# De naam ah-importeren.py heeft een streepje en is dus niet gewoon te importeren
_spec = importlib.util.spec_from_file_location("ah_importeren", Path(__file__).with_name("ah-importeren.py"))
importeren = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(importeren)

REDEN = "Verplaatst door de beheerder na het nalezen van 8 oktober 2026."
# Algemene regel: zero (zero sugar, zero added sugar) is apart van de gewone variant, bij elk product en elk merk
ZERO = re.compile(r"\bzero\b", re.I)

# Product: titels waarvan de koppeling verdwijnt
LOSMAKEN = {
    # Krachtig Kanon (zwaar bier) en witpils zijn speciaalbier, en dat product bestaat nog niet: daarom los en
    # niet verplaatst. Een fust past alleen in een eigen tap
    "bier": ["Grolsch Krachtig kanon", "Grolsch Krachtig kanon 4-pack", "Heineken Witpils 6-pack",
             "Heineken Premium pilsener blade fust"],
    # Groente uit een pot is iets anders dan verse groente
    "boerenkool": ["Hak Boerenkool"],
    "sperziebonen": ["Hak Sperziebonen"],
    "spinazie": ["Hak Spinazie"],
    # "doekjes" zijn vochtige schoonmaakdoekjes; Swiffer is een eigen systeem, de starterset een apparaat
    "doekjes": ["Swiffer *"],
    # 0.0, 0% en decaf zijn apart van de gewone variant (zero valt onder de algemene regel ZERO)
    "grolsch radler": ["Grolsch Radler 0.0%", "Grolsch Radler citroen 0.0%", "Grolsch Radler citroen 0%",
                       "Grolsch Radler citroen alcoholvrij 0.0 6-pack", "Grolsch Radler citroen alcoholvrij 0.0% 6-pack"],
    "siroop": ["Slimpie *"],
    "perla koffiebonen": ["Perla Huisblends Decaf koffiebonen"],
    "perla koffiecapsules": ["Perla Huisblends Lungo decaf capsules"],
    "perla koffiepads": ["Perla Huisblends Decaf koffiepads"],
    # Drop is iets anders dan gums en winegums
    "haribo snoep": ["Haribo Zoute rijen", "Haribo Rotella", "Haribo Drop fruit fietsen"],
    # Specerijmengsels met een eigen smaak zijn geen maaltijdmix
    "kruidenmix": ["Verstegen World spice blend *"],
    # Het huishouden koopt wegwerpscheermesjes; systeemmesjes en handvatten passen alleen op hun eigen systeem
    "scheermesjes": ["*"],
}

# (van, naar, titels): de koppeling gaat naar een ander, bestaand product
VERPLAATSEN = [
    ("oregano", "gedroogde oregano", ["Verstegen Oregano"]),
    ("zout", "zeezout", ["Verstegen *"]),
    ("smeerbare boter", "halvarine", ["Blue Band Heerlijk romig ongezouten"]),
    # Alle mixen voor een gerecht of vleessoort zijn "kruidenmix", ongeacht merk. Bij "verstegen kruiden" stonden
    # alleen mixen (vlees-, vis- en Italiaanse kruiden); dat product wordt hieronder "kruiden"
    ("verstegen kruiden", "kruidenmix", ["*"]),
]

# (bron, doel): schrijfwijze, tikfouten, enkelvoud en meervoud, synoniemen en merken van hetzelfde soort product
SAMENVOEGEN = [
    ("roerbakgroenten", "wokgroente"),
    ("aardappel", "aardappelen"),
    ("brocoli", "broccoli"),
    ("brocolio", "broccoli"),
    ("banaan", "bananen"),
    ("bosui", "bosuien"),
    ("rode ui", "rode uien"),
    ("adnijvie", "andijvie"),
    ("cup a spup", "cup a soup"),
    ("groente", "groenten"),
    ("de buitenbeentjes komkommer", "komkommer"),
    ("proteinedrank", "eiwitdrank"),
    ("proteinedrink", "eiwitdrank"),
    ("frikandelbrood", "hartig broodje"),
    ("firkandelbroodje", "hartig broodje"),
    ("pinda's (duyvis)", "pinda's duyvis"),
    ("sojasaus (go-tan)", "sojasaus"),
    ("sojasaus go-tan", "sojasaus"),
    ("haribo snoep", "snoep"),
    ("perla koffiebonen", "koffiebonen"),
]

# (oud, nieuw): een productnaam is de soort, niet het merk
HERNOEMEN = [
    ("palmolive handzeep", "handzeep"),
    ("perla koffiecapsules", "koffiecapsules"),
    ("perla koffiepads", "koffiepads"),
    ("grolsch radler", "radler"),
    # Losse kruiden en specerijen, zonder merk; de mixen zijn hierboven naar "kruidenmix" verplaatst
    ("verstegen kruiden", "kruiden"),
    ("pinda's duyvis", "pinda's"),
]


def past(titel, patroon):
    titel, patroon = titel.lower(), patroon.lower()
    if patroon.endswith("*"):
        return titel.startswith(patroon[:-1])
    return titel == patroon


def zoek(gekoppeld, product, patronen, meldingen):
    """De goedgekeurde koppelingen van dit product waarvan de titel bij een van de patronen past."""
    van_product = [r for r in gekoppeld if r["product"].lower() == product]
    gevonden = []
    for patroon in patronen:
        rijen = [r for r in van_product if past(r["titel"], patroon)]
        if not rijen:
            meldingen.append(f"niet gevonden bij \"{product}\": {patroon}")
        gevonden += [r for r in rijen if r not in gevonden]
    return gevonden


def regel(r):
    return f"    {r['titel']}" + (f" ({r['inhoud']})" if r.get("inhoud") else "")


def main():
    echt = "--echt" in sys.argv[1:]
    db = importeren.Supabase(*importeren.lees_config())
    try:
        db.login(input("E-mailadres van de beheerder: ").strip(), getpass.getpass("Wachtwoord (je ziet niets terwijl je typt; sluit af met Enter): "))
        gekoppeld = db.rpc("article_link_review")["goedgekeurd"]
        producten = db.rpc("product_overview")
    except RuntimeError as fout:
        sys.exit(f"Mislukt: {fout}")

    per_naam = {}
    for p in producten:
        per_naam.setdefault(p["name"].lower(), []).append(p)
    meldingen, fouten = [], []
    # Wat al is losgemaakt komt niet nog een keer aan de beurt
    los = []

    def product_id(naam):
        gevonden = per_naam.get(naam, [])
        if len(gevonden) != 1:
            meldingen.append(f"product \"{naam}\" " + ("bestaat niet" if not gevonden else f"bestaat {len(gevonden)} keer"))
            return None
        return gevonden[0]["id"]

    def voer_uit(omschrijving, stap):
        if not echt:
            return
        try:
            stap()
        except RuntimeError as fout:
            fouten.append(f"{omschrijving}: {fout}")

    print("\n1. Losmaken")
    for product, patronen in LOSMAKEN.items():
        rijen = zoek(gekoppeld, product, patronen, meldingen)
        if rijen:
            print(f"  {product} ({len(rijen)}):")
        for r in rijen:
            print(regel(r))
            los.append(r)
            voer_uit(f"losmaken {r['titel']}", lambda r=r: db.rpc("reject_article_link", p_supermarket=r["supermarkt"], p_article_id=r["artikel_id"]))
    zero = [r for r in gekoppeld if ZERO.search(r["titel"]) and r not in los]
    if zero:
        print(f"  algemene regel, zero in de titel ({len(zero)}):")
    for r in zero:
        print(f"{regel(r)}, bij \"{r['product']}\"")
        los.append(r)
        voer_uit(f"losmaken {r['titel']}", lambda r=r: db.rpc("reject_article_link", p_supermarket=r["supermarkt"], p_article_id=r["artikel_id"]))

    print("\n2. Verplaatsen")
    for van, naar, patronen in VERPLAATSEN:
        doel = product_id(naar)
        rijen = [r for r in zoek(gekoppeld, van, patronen, meldingen) if r not in los]
        if not doel or not rijen:
            continue
        print(f"  {van} → {naar} ({len(rijen)}):")
        for r in rijen:
            print(regel(r))

            def verplaats(r=r):
                db.rpc("reject_article_link", p_supermarket=r["supermarkt"], p_article_id=r["artikel_id"])
                uit = db.rpc("save_article_proposals", p_rows=[{
                    "supermarket": r["supermarkt"], "article_id": r["artikel_id"], "product_id": doel,
                    "confidence": "high", "reason": REDEN, "source": "ai"}])
                if uit.get("voorstellen") != 1:
                    raise RuntimeError(f"niet als voorstel opgeslagen ({uit}); de koppeling bij \"{van}\" is wel los")
                if db.rpc("approve_article_links", p_rows=[{
                        "supermarket": r["supermarkt"], "article_id": r["artikel_id"], "product_id": doel}]) != 1:
                    raise RuntimeError(f"voorstel bij \"{naar}\" staat klaar maar is niet goedgekeurd")
            voer_uit(f"verplaatsen {r['titel']}", verplaats)

    print("\n3. Samenvoegen")
    for bron, doel in SAMENVOEGEN:
        bron_id, doel_id = product_id(bron), product_id(doel)
        if bron_id and doel_id:
            print(f"  {bron} → {doel}")
            voer_uit(f"samenvoegen {bron}", lambda b=bron_id, d=doel_id: db.rpc("merge_products", p_source=b, p_target=d))

    print("\n4. Hernoemen")
    for oud, nieuw in HERNOEMEN:
        if nieuw in per_naam:
            meldingen.append(f"\"{oud}\" niet hernoemd: \"{nieuw}\" bestaat al")
            continue
        pid = product_id(oud)
        if pid:
            print(f"  {oud} → {nieuw}")
            voer_uit(f"hernoemen {oud}", lambda p=pid, n=nieuw: db.rpc("rename_product", p_product=p, p_name=n))

    if meldingen:
        print("\nOvergeslagen:")
        for m in meldingen:
            print("  " + m)
    if fouten:
        print("\nMislukt:")
        for f in fouten:
            print("  " + f)
    print("\n" + ("Uitgevoerd." if echt else "Proef: er is niets veranderd. Draai met --echt om het uit te voeren."))
    sys.exit(1 if fouten else 0)


if __name__ == "__main__":
    main()
