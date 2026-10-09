-- Controlequeries voor de overstap naar producttypes: de oude catalogus naast de nieuwe types.
-- Draai ze één voor één in de SQL Editor: die toont alleen de uitkomst van de laatste opdracht.
-- Ze lezen alleen. De vergelijking met de oude catalogus (query 2, 4 en 5) zegt iets zolang de oude tabellen bestaan.

-- ---------- 1. Hoeveel is er gekoppeld? ----------
-- artikelen: alle artikelen hebben een oordeel als "onbeoordeeld" 0 is.
-- aankopen:  zonder_type zijn aankopen waarvan de naam bij geen enkel type hoort (query 3 laat ze zien).
select 'artikelen' as wat,
       count(*) filter (where t.type_id is not null) as met_type,
       count(*) filter (where t.article_id is not null and t.type_id is null) as zonder_type,
       count(*) filter (where t.article_id is null) as onbeoordeeld
from public.articles x
left join public.article_types t on t.supermarket = x.supermarket and t.article_id = x.article_id
union all
select 'aankopen', count(pt.type_id), count(*) - count(pt.type_id), 0
from public.purchase_types() pt
union all
select 'namen (' || s.source || ')', count(s.type_id), count(*) - count(s.type_id), 0
from public.term_synonyms s
group by s.source;

-- ---------- 2. De top van het profiel, oud naast nieuw ----------
-- Aankoopdagen per product (oud) en per type (nieuw), over alle lijsten die meetellen en alle tijd.
-- Een type dat hoger staat dan het oude product heeft er namen bij gekregen, en dat is de bedoeling.
-- Kijk of de volgorde bovenaan herkenbaar is en of er niets vreemds tussen staat.
with basis as (
  select (a.bought_at at time zone 'Europe/Amsterdam')::date as dag,
         pr.name as product, coalesce(pr.counts_in_profile, true) as product_telt,
         ty.name as soort, coalesce(ty.counts_in_profile, true) as type_telt
  from public.purchases a
  join public.lists l on l.id = a.list_id and l.counts_for_profile
  left join public.product_aliases pa on pa.normalized_name = a.normalized_name
  left join public.products pr on pr.id = pa.product_id
  left join public.purchase_types() pt on pt.purchase_id = a.id
  left join public.product_types ty on ty.id = pt.type_id
),
oud as (
  select product as naam, count(distinct dag) as dagen, row_number() over (order by count(distinct dag) desc, product) as plek
  from basis where product_telt and product is not null group by product
),
nieuw as (
  select soort as naam, count(distinct dag) as dagen, row_number() over (order by count(distinct dag) desc, soort) as plek
  from basis where type_telt and soort is not null group by soort
)
select coalesce(o.plek, n.plek) as plek, o.naam as product_oud, o.dagen as dagen_oud, n.naam as type_nieuw, n.dagen as dagen_nieuw
from oud o
full join nieuw n on n.plek = o.plek
where coalesce(o.plek, n.plek) <= 40
order by 1;

-- ---------- 3. Aankopen zonder type ----------
-- Namen die bij geen enkel type horen: bewust (een losse merknaam, een te vage naam) of gemist.
-- In het profiel staan ze na fase 4 onder hun eigen naam.
select a.name, count(*) as aankopen, max((a.bought_at at time zone 'Europe/Amsterdam')::date) as laatste,
       s.source as bron, s.reason as reden
from public.purchases a
join public.purchase_types() pt on pt.purchase_id = a.id and pt.type_id is null
left join public.term_synonyms s on s.key = public.match_key(a.name)
group by a.name, s.source, s.reason
order by aankopen desc, a.name;

-- ---------- 4. Welke producten zijn samengegaan in één type? ----------
-- Per type de oude catalogusproducten die erin opgaan. Meer dan één: die telden eerst apart en nu samen.
select ty.main_group as hoofdgroep, ty.name as type, count(distinct pr.id) as producten,
       string_agg(distinct pr.name, ', ' order by pr.name) as was
from public.term_synonyms s
join public.product_types ty on ty.id = s.type_id
join public.product_aliases pa on public.match_key(pa.normalized_name) = s.key
join public.products pr on pr.id = pa.product_id
group by ty.main_group, ty.name
having count(distinct pr.id) > 1
order by producten desc, ty.name;

-- ---------- 5. Eén oud product over meerdere types ----------
-- Aankopen van één catalogusproduct die nu bij verschillende types horen. Dat komt door het artikel op de
-- bon: het artikel heeft een eigen type dat afwijkt van de naam. Vaak terecht (de bon weet het beter).
select pr.name as product, ty.name as type, count(*) as aankopen
from public.purchases a
join public.product_aliases pa on pa.normalized_name = a.normalized_name
join public.products pr on pr.id = pa.product_id
join public.purchase_types() pt on pt.purchase_id = a.id
join public.product_types ty on ty.id = pt.type_id
where pr.id in (
  select pa2.product_id
  from public.purchases a2
  join public.product_aliases pa2 on pa2.normalized_name = a2.normalized_name
  join public.purchase_types() pt2 on pt2.purchase_id = a2.id
  where pt2.type_id is not null
  group by pa2.product_id
  having count(distinct pt2.type_id) > 1)
group by pr.name, ty.name
order by pr.name, aankopen desc;

-- ---------- 6. Wat de AI nergens kwijt kon ----------
-- Artikelen met het oordeel "geen type", gegroepeerd op het type dat volgens de AI ontbreekt.
-- Een voorstel dat vaak terugkomt is een kandidaat voor een nieuw type (create_product_type).
select coalesce(t.suggested_type, '(geen gewone boodschap)') as voorstel, count(*) as artikelen,
       (array_agg(x.title order by x.title))[1:4] as voorbeelden
from public.article_types t
join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
where t.type_id is null
group by t.suggested_type
order by artikelen desc, voorstel;

-- ---------- 7. Types en zekerheid per hoofdgroep ----------
select ty.main_group as hoofdgroep, count(*) as artikelen,
       count(*) filter (where t.confidence = 'high') as hoog,
       count(*) filter (where t.confidence = 'medium') as middel,
       count(*) filter (where t.confidence = 'low') as laag,
       count(*) filter (where t.reviewed_at is not null) as nagekeken
from public.article_types t
join public.product_types ty on ty.id = t.type_id
group by ty.main_group
order by artikelen desc;
