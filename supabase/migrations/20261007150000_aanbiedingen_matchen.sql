-- Matchen van aanbiedingen (roadmap stap 5, deel 1): welke geldige aanbiedingen tellen voor iemand, via het
-- aankoopprofiel van het huishouden en via de eigen favorieten, en welke horen bij een item op de lijst.
--
-- De route voor het profiel is aanbieding → artikel → product → profiel. De koppeling artikel → product komt
-- hier alleen uit niveau 1: het artikelnummer staat op een eigen bon, dus de naam van die aankoop zegt welk
-- product het is. Daar is geen tabel voor nodig, het volgt uit purchases. Niveau 2 (voorstel, goedgekeurd door
-- de beheerder) komt in een latere migratie en sluit aan in article_products().
-- Favorieten gaan rechtstreeks naar articles, zonder product ertussen.
--
-- De oude tabel deals en deals_for_list blijven nog staan tot het nieuwe label getest is.

-- ---------- Instellingen ----------
-- Getallen die de beheerder wil kunnen bijstellen zonder een functie te wijzigen. Aanpassen kan in de
-- SQL Editor (het zijn gegevens, geen structuur):
--   update public.settings set value = 4 where key = 'regular_min_days';
-- Geen policies en geen rechten: alleen de functies hieronder lezen de tabel.
create table public.settings (
  key text primary key,
  value integer not null,
  description text not null
);
alter table public.settings enable row level security;
revoke all on table public.settings from public, anon, authenticated;

-- GRENS VAST PRODUCT: vanaf wanneer een huishouden een product "koopt"
insert into public.settings (key, value, description) values
  ('regular_min_days', 3, 'Vast product: minstens zoveel aankoopdagen'),
  ('regular_max_age_days', 365, 'Vast product: de laatste aankoop is hooguit zoveel dagen geleden');

-- ---------- Vaste producten ----------
-- De producten die het huishouden van p_user koopt: genoeg aankoopdagen en kort genoeg geleden (zie settings).
-- Dezelfde basis als purchase_profile: aankopen uit lijsten waarvan je deelnemer bent en die meetellen voor
-- het profiel, ook gearchiveerde, zonder producten met de vlag "telt niet mee in profiel".
create function public.regular_products(p_user uuid)
returns table (product_id uuid, naam text, dagen integer, laatste date)
language sql stable security definer
set search_path to 'public'
as $$
  with grens as (
    select (now() at time zone 'Europe/Amsterdam')::date as vandaag,
           (select value from public.settings where key = 'regular_min_days') as min_dagen,
           (select value from public.settings where key = 'regular_max_age_days') as max_oud
  ),
  gekocht as (
    select pr.id, pr.name, (a.bought_at at time zone 'Europe/Amsterdam')::date as dag
    from public.purchases a
    join public.lists l on l.id = a.list_id and l.counts_for_profile
    join public.list_members m on m.list_id = l.id and m.user_id = p_user
    join public.product_aliases pa on pa.normalized_name = a.normalized_name
    join public.products pr on pr.id = pa.product_id and pr.counts_in_profile
  )
  select g.id, g.name, count(distinct g.dag)::integer, max(g.dag)
  from gekocht g cross join grens
  group by g.id, g.name, grens.vandaag, grens.min_dagen, grens.max_oud
  having count(distinct g.dag) >= grens.min_dagen
     and max(g.dag) >= grens.vandaag - grens.max_oud;
$$;

-- ---------- Artikel → product ----------
-- Gedeeld voor iedereen: bij welk product een artikel van een supermarkt hoort.
-- Niveau 1: het artikelnummer staat op een bon. De supermarkt komt van die bon, het product van de naam van
-- de aankoop (via product_aliases), dus samenvoegen en losmaken van producten werkt hier vanzelf in door.
create function public.article_products()
returns table (supermarket text, article_id text, product_id uuid)
language sql stable security definer
set search_path to 'public'
as $$
  select distinct upper(btrim(r.store)), a.article_id, pa.product_id
  from public.purchases a
  join public.receipts r on r.id = a.receipt_id
  join public.product_aliases pa on pa.normalized_name = a.normalized_name
  where a.article_id is not null
    and btrim(r.store) <> '';
$$;

-- ---------- Voor jou ----------
-- De geldige aanbiedingen die voor jou tellen, elk één keer, als JSON:
--   [{ id, supermarkt, titel, korting, geldig_van, geldig_tot, alleen_winkel,
--      favorieten: [{ id, term, brand, artikel, artikelen }],   -- je favorieten die erin zitten
--      producten:  [{ naam, dagen }] }]                         -- vaste producten van het huishouden erin
-- Via een favoriet: de term als hele woorden in de titel van een artikel ("melk" niet in "kokosmelk"; bij
-- meerdere woorden moeten ze er allemaal in staan), het merk exact, en de hoofdcategorie als de favoriet die
-- heeft (een artikel zonder hoofdcategorie wordt daar niet op uitgesloten). Alles via normalize_search.
-- Via het profiel: een artikel in de aanbieding hoort bij een vast product, ongeacht merk of formaat.
-- RANGORDE: favorieten bovenaan (zelf gekozen), daarna het profiel op aantal aankoopdagen.
create function public.offers_for_me() returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.*
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  art as materialized (
    select g.id as offer, x.supermarket, x.article_id, x.title,
           public.normalize_search(x.brand) as merk,
           array_remove(regexp_split_to_array(public.normalize_search(x.title), '[^[:alnum:]]+'), '') as woorden,
           case when x.category like '%/%' then public.normalize_search(split_part(x.category, '/', 1)) end as hoofd
    from geldig g
    join public.offer_articles oa on oa.offer_id = g.id
    join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
  ),
  fav as (
    select f.id, f.term, f.brand, f.normalized_brand, f.created_at,
           array_remove(regexp_split_to_array(coalesce(f.normalized_term, ''), '[^[:alnum:]]+'), '') as woorden,
           public.normalize_search(f.category) as hoofd
    from public.favorites f
    where f.user_id = auth.uid()
  ),
  -- artikel is een voorbeeld uit de aanbieding: bij een favoriet met alleen een merk zet de app die titel op de lijst
  via_fav as (
    select a.offer, f.id, f.term, f.brand, f.created_at, min(a.title) as artikel, count(*)::integer as artikelen
    from fav f
    join art a
      on (f.term is null or (cardinality(f.woorden) > 0 and f.woorden <@ a.woorden))
     and (f.normalized_brand is null or a.merk = f.normalized_brand)
     and (f.hoofd is null or a.hoofd is null or a.hoofd = f.hoofd)
    group by a.offer, f.id, f.term, f.brand, f.created_at
  ),
  via_profiel as (
    select distinct a.offer, v.product_id, v.naam, v.dagen
    from art a
    join public.article_products() ap on ap.supermarket = upper(a.supermarket) and ap.article_id = a.article_id
    join public.regular_products(auth.uid()) v on v.product_id = ap.product_id
  ),
  treffer as (
    select g.id, g.supermarket, g.title, g.discount_text, g.valid_from, g.valid_to, g.store_only,
           (select jsonb_agg(jsonb_build_object('id', f.id, 'term', f.term, 'brand', f.brand,
                                                'artikel', f.artikel, 'artikelen', f.artikelen)
                             order by f.created_at)
            from via_fav f where f.offer = g.id) as favorieten,
           (select jsonb_agg(jsonb_build_object('naam', p.naam, 'dagen', p.dagen) order by p.dagen desc, p.naam)
            from via_profiel p where p.offer = g.id) as producten,
           (select max(p.dagen) from via_profiel p where p.offer = g.id) as dagen
    from geldig g
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'supermarkt', t.supermarket, 'titel', t.title, 'korting', t.discount_text,
           'geldig_van', t.valid_from, 'geldig_tot', t.valid_to, 'alleen_winkel', t.store_only,
           'favorieten', coalesce(t.favorieten, '[]'::jsonb),
           'producten', coalesce(t.producten, '[]'::jsonb))
         order by (t.favorieten is not null) desc, t.dagen desc nulls last, t.title, t.id), '[]'::jsonb)
  from treffer t
  where t.favorieten is not null or t.producten is not null;
$$;

-- ---------- Bonus-label op de lijst ----------
-- Per item bij welke supermarkt er hoeveel geldige aanbiedingen zijn; dezelfde vorm als deals_for_list.
-- Een item telt via zijn product: naam → product_aliases → de artikelen van dat product → aanbiedingen.
-- Hier geldt de grens van het profiel niet: wat op de lijst staat wil je sowieso kopen.
-- Security definer omdat article_products() aankopen van alle lijsten leest; is_member bewaakt de lijst.
create function public.offers_for_list(p_list uuid)
returns table (item_id uuid, supermarkt text, aantal integer)
language sql stable security definer
set search_path to 'public'
as $$
  select i.id, o.supermarket, count(distinct o.id)::integer
  from public.items i
  join public.product_aliases pa on pa.normalized_name = i.normalized_name
  join public.article_products() ap on ap.product_id = pa.product_id
  join public.offer_articles oa on upper(oa.supermarket) = ap.supermarket and oa.article_id = ap.article_id
  join public.offers o on o.id = oa.offer_id
  where i.list_id = p_list
    and public.is_member(p_list)
    and (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  group by i.id, o.supermarket;
$$;

-- De twee hulpfuncties lezen aankopen van alle huishoudens en zijn alleen bedoeld voor de functies hierboven
revoke all on function public.regular_products(uuid) from public, anon, authenticated;
revoke all on function public.article_products() from public, anon, authenticated;
revoke all on function public.offers_for_me() from public, anon;
revoke all on function public.offers_for_list(uuid) from public, anon;
grant execute on function public.regular_products(uuid) to service_role;
grant execute on function public.article_products() to service_role;
grant execute on function public.offers_for_me() to authenticated, service_role;
grant execute on function public.offers_for_list(uuid) to authenticated, service_role;
