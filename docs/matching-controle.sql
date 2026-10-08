-- Controlequeries voor het gelaagd matchen van lijsttermen (migraties gelaagd_matchen en matchen_bijgesteld).
-- Draai ze één voor één in de SQL Editor: die toont alleen de uitkomst van de laatste opdracht.
--
-- De lagen (kolom step van term_articles):
--   1 exact, 2 synoniem, 3 merk, 4 tolerant, 5 titel. Geen rij = de term matcht nergens.

-- ---------- 0. Vooraf: welke lijstnamen staan er? ----------
-- Bevestigt waarom een term niet matchte. Op 8 oktober 2026: "chocolade", "tandpasta", "shampoo" en
-- "eiwitdrank" staan erin; "proteinedrank" niet (dat is een naam van het product eiwitdrank, zie
-- product_aliases), en een los merk als "sensodyne" of "parodontax" ook niet.
select n.name, n.key, n.stem, count(*) as artikelen
from public.article_names n
where n.key ~ '(prote|eiwit|chocola|tandpasta|shampoo|nivea|sensodyne|parodontax)'
group by n.name, n.key, n.stem
order by n.key;

-- ---------- 1. De testtermen per laag ----------
-- Verwacht: proteinedrank 1, proteine drank 1, proteinedrink 1, chocolade 1, chocola 4, tandpasta 1,
-- tandenpasta 4, shampoo 1, nivea 3, parodontax 3, sensodyne 3, sensodyne tandpasta 5, gember en xyzzy geen laag
-- (een los woord gaat niet door de titellaag).
select t.term, a.step, count(a.article_id) as artikelen
from unnest(array['proteinedrank', 'proteine drank', 'proteinedrink', 'chocolade', 'chocola', 'tandpasta',
                  'tandenpasta', 'shampoo', 'nivea', 'parodontax', 'sensodyne', 'sensodyne tandpasta',
                  'gember', 'xyzzy']) as t(term)
left join lateral public.term_articles(t.term) a on true
group by t.term, a.step
order by a.step nulls last, t.term;

-- ---------- 2. Wat vindt één term precies? ----------
-- Vul de term in. Laat per artikel de titel, het merk en de lijstnamen zien.
select a.step, x.title, x.brand, x.category,
       (select string_agg(n.name, ', ' order by n.position)
        from public.article_names n
        where n.supermarket = x.supermarket and n.article_id = x.article_id) as lijstnamen
from public.term_articles('chocola') a
join public.articles x on upper(x.supermarket) = a.supermarket and x.article_id = a.article_id
order by x.title
limit 100;

-- ---------- 3. Tegencontrole tolerant ----------
-- Welke lijstnamen en merken lijken het meest op een term, met de score. Alles vanaf de grens
-- (settings: fuzzy_min_similarity_pct, in procenten) telt in laag 4, en dan alleen de hoogste score.
-- Verwacht: bij 'cola' geen chocolade boven de grens, bij 'volle melk' geen halfvolle melk.
select k.sleutel, k.soort, round(extensions.similarity(k.sleutel, public.match_key('chocola'))::numeric, 2) as score
from (
  select distinct n.key as sleutel, 'lijstnaam' as soort from public.article_names n where n.key <> ''
  union
  select distinct x.brand_key, 'merk' from public.articles x where x.brand_key <> ''
) k
order by score desc
limit 10;

-- De grens bijstellen (gegevens, geen structuur):
--   update public.settings set value = 60 where key = 'fuzzy_min_similarity_pct';

-- ---------- 4. Het logboek: termen die nergens op matchten ----------
-- Alleen wat nu nog steeds niets oplevert: een term kan intussen matchen door nieuwe artikelen of een synoniem.
select u.term, u.times, u.first_seen, u.last_seen, u.judged_at
from public.unmatched_terms u
where not exists (select 1 from public.term_articles(u.term))
order by u.times desc, u.last_seen desc;

-- ---------- 5. Synoniemen ----------
-- Toevoegen: de term zoals getypt, en de naam waar hij voor staat (een lijstnaam of een productnaam).
--   insert into public.term_synonyms (key, term, target, source)
--   values (public.match_key('proteinedrink'), 'proteinedrink', 'proteinedrank', 'manual');
-- Weghalen:
--   delete from public.term_synonyms where key = public.match_key('proteinedrink');
-- Overzicht, met of het doel zelf iets oplevert (zo niet, dan doet het synoniem niets):
select s.term, s.target, s.source, s.created_at,
       exists (select 1 from public.term_articles_exact(s.target)) as doel_matcht
from public.term_synonyms s
order by s.created_at desc;

-- ---------- 6. Het label op een lijst ----------
-- Per item op een lijst de laag waarlangs het matcht en het aantal geldige aanbiedingen.
-- Vul de naam van de lijst in.
select i.name, min(a.step) as step, count(distinct o.id) as aanbiedingen
from public.items i
join public.lists l on l.id = i.list_id and l.name = 'NAAM-VAN-DE-LIJST'
left join lateral public.term_articles(i.name) a on true
left join public.offer_articles oa on upper(oa.supermarket) = a.supermarket and oa.article_id = a.article_id
left join public.offers o on o.id = oa.offer_id
  and (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
group by i.id, i.name
order by step nulls last, i.name;
