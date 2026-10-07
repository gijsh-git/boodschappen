-- De oude tabel deals met testdata en de functie deals_for_list vervallen (roadmap stap 5).
--
-- De app gebruikt ze niet meer: het Bonus-label op de lijst komt uit de echte aanbiedingen (offers,
-- offer_articles) via offers_for_list. Zonder cascade: hangt er nog iets anders aan, dan faalt de migratie.
drop function public.deals_for_list(uuid);
drop table public.deals;
