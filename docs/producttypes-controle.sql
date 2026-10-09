-- Controlequeries voor de producttypes: wat heeft een type, wat niet, en wat kon de AI nergens kwijt.
-- Draai ze één voor één in de SQL Editor: die toont alleen de uitkomst van de laatste opdracht. Ze lezen alleen.
-- De vergelijkingen met de oude catalogus zijn vervallen toen die catalogus is opgeruimd (9 oktober 2026).

-- ---------- 1. Hoeveel is er gekoppeld? ----------
-- artikelen: alle artikelen hebben een oordeel als "onbeoordeeld" 0 is.
-- aankopen:  zonder_type zijn aankopen waarvan de naam bij geen enkel type hoort (query 2 laat ze zien).
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

-- ---------- 2. Aankopen zonder type ----------
-- Namen die bij geen enkel type horen: bewust (een losse merknaam, een te vage naam) of gemist.
-- In het profiel staan ze onder hun eigen naam.
select a.name, count(*) as aankopen, max((a.bought_at at time zone 'Europe/Amsterdam')::date) as laatste,
       s.source as bron, s.reason as reden
from public.purchases a
join public.purchase_types() pt on pt.purchase_id = a.id and pt.type_id is null
left join public.term_synonyms s on s.key = public.match_key(a.name)
group by a.name, s.source, s.reason
order by aankopen desc, a.name;

-- ---------- 3. Wat de AI nergens kwijt kon ----------
-- Artikelen met het oordeel "geen type", gegroepeerd op het type dat volgens de AI ontbreekt.
-- Een voorstel dat vaak terugkomt is een kandidaat voor een nieuw type (create_product_type).
select coalesce(t.suggested_type, '(geen gewone boodschap)') as voorstel, count(*) as artikelen,
       (array_agg(x.title order by x.title))[1:4] as voorbeelden
from public.article_types t
join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
where t.type_id is null
group by t.suggested_type
order by artikelen desc, voorstel;

-- ---------- 4. Types en zekerheid per hoofdgroep ----------
select ty.main_group as hoofdgroep, count(*) as artikelen,
       count(*) filter (where t.confidence = 'high') as hoog,
       count(*) filter (where t.confidence = 'medium') as middel,
       count(*) filter (where t.confidence = 'low') as laag,
       count(*) filter (where t.reviewed_at is not null) as nagekeken
from public.article_types t
join public.product_types ty on ty.id = t.type_id
group by ty.main_group
order by artikelen desc;
