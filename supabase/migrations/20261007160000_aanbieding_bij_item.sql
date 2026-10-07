-- Een item dat vanuit "Voor jou" op de lijst is gezet onthoudt van welke aanbieding het komt (roadmap stap 5).
--
-- Waarom: een favoriet op de lijst ("Calvé pindakaas", "banaan") is een nieuwe naam en dus een product zonder
-- artikelen; via het product krijgt het geen Bonus-label. De koppeling met de aanbieding zelf klopt altijd en
-- geldt voor iedereen op de lijst, ook voor wie die favoriet niet heeft.
--
-- Wijzigt een bestaande tabel: items krijgt een kolom erbij, leeg bij alle bestaande rijen.

-- Wordt vanzelf leeg als de aanbieding wordt opgeruimd (save_offers, 28 dagen na de laatste geldige dag)
alter table public.items add column offer_id uuid references public.offers(id) on delete set null;
comment on column public.items.offer_id is
  'De aanbieding waarmee dit item vanuit "Voor jou" op de lijst is gezet; leeg bij een gewoon item. Geeft het Bonus-label zolang de aanbieding geldig is.';

-- Per item bij welke supermarkt er hoeveel geldige aanbiedingen zijn. Twee routes, elke aanbieding telt één keer:
--   1. via het product: naam → product_aliases → de artikelen van dat product → aanbiedingen;
--   2. via de aanbieding waarmee het item op de lijst is gezet (items.offer_id).
create or replace function public.offers_for_list(p_list uuid)
returns table (item_id uuid, supermarkt text, aantal integer)
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  treffer as (
    select i.id as item, g.id as offer, g.supermarket
    from public.items i
    join public.product_aliases pa on pa.normalized_name = i.normalized_name
    join public.article_products() ap on ap.product_id = pa.product_id
    join public.offer_articles oa on upper(oa.supermarket) = ap.supermarket and oa.article_id = ap.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list
    union
    select i.id, g.id, g.supermarket
    from public.items i
    join geldig g on g.id = i.offer_id
    where i.list_id = p_list
  )
  select t.item, t.supermarket, count(distinct t.offer)::integer
  from treffer t
  where public.is_member(p_list)
  group by t.item, t.supermarket;
$$;
