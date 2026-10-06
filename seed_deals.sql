-- BonusBuddy: testaanbiedingen voor de tabel deals
-- Uitvoeren in Supabase: SQL Editor > New query > plakken > Run (na schema.sql)
--
-- LET OP: dit maakt de tabel deals eerst leeg, zodat opnieuw uitvoeren geen dubbele rijen geeft.
-- Alleen gebruiken zolang er testgegevens in staan.
--
-- De aanbiedingen gelden van maandag t/m zondag van de week waarin je dit uitvoert.

delete from public.deals;

insert into public.deals (supermarkt, productnaam, omschrijving, prijs, geldig_van, geldig_tot)
select d.supermarkt, d.productnaam, d.omschrijving, d.prijs,
       date_trunc('week', current_date)::date,
       date_trunc('week', current_date)::date + 6
from (values
  ('AH',   'AH Goudse kaas plakken jong belegen',        '2e halve prijs',     3.49),
  ('AH',   'AH Zaanlander kaas stuk extra belegen',      '25% korting',        5.99),
  ('AH',   'AH Halfvolle melk 1 liter',                  '2 voor 1.99',        1.99),
  ('AH',   'AH Kipfilet 500 gram',                       '25% korting',        4.49),
  ('AH',   'Calvé Pindakaas 650 gram',                   '1+1 gratis',         4.79),
  ('AH',   'Douwe Egberts Aroma Rood koffie snelfilter', '2e halve prijs',     6.99),
  ('AH',   'AH Bananen tros',                            'Voor 1.29',          1.29),
  ('AH',   'AH Scharreleieren 10 stuks',                 '2 voor 4.50',        4.50),
  ('AH',   'AH Tijgerbrood heel',                        'Voor 1.49',          1.49),
  ('AH',   'Coca-Cola Zero 1,5 liter',                   '4 halen, 2 betalen', null),
  ('PLUS', 'PLUS Jong belegen kaas plakken',             '2 voor 5.00',        5.00),
  ('PLUS', 'PLUS Volle melk 1 liter',                    '2e halve prijs',     1.19),
  ('PLUS', 'PLUS Kipfilet 1 kilo',                       'Voor 7.99',          7.99),
  ('PLUS', 'PLUS Pindakaas naturel 350 gram',            '2 voor 3.50',        3.50),
  ('PLUS', 'PLUS Koffie pads roodmerk 36 stuks',         '1+1 gratis',         3.29),
  ('PLUS', 'Chiquita Bananen per kilo',                  'Voor 1.59',          1.59),
  ('PLUS', 'PLUS Griekse yoghurt 1 kilo',                '2e halve prijs',     2.39),
  ('PLUS', 'Elstar appels 1,5 kilo',                     'Voor 1.99',          1.99),
  ('PLUS', 'Grand''Italia Pasta penne 500 gram',         '2+1 gratis',         null),
  ('PLUS', 'PLUS Roomboter ongezouten 250 gram',         '25% korting',        2.24)
) as d(supermarkt, productnaam, omschrijving, prijs);
