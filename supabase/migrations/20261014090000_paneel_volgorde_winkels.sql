-- Het bonuspaneel: per item eerst dezelfde variant, daarna de winkels van de lijst in vaste volgorde (tot de
-- prijs per eenheid er is), en pas dan op titel.
create or replace function public.offer_details_for_list(p_list uuid) returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket, o.title, o.discount_text, o.valid_to
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  ding as (
    select i.id, i.name, i.offer_id, i.created_at, i.original_name is not null as gekozen,
           public.term_variant(coalesce(i.original_name, i.name)) as variant
    from public.items i
    where i.list_id = p_list and public.is_member(p_list)
  ),
  treffer as (
    select d.id as item, g.id as offer, oa.supermarket, oa.article_id
    from ding d
    cross join lateral public.term_articles(d.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
    where not d.gekozen
      and upper(g.supermarket) = any (public.list_supermarkets(p_list))
    union
    select d.id, g.id, oa.supermarket, oa.article_id
    from ding d
    join geldig g on g.id = d.offer_id
    left join public.offer_articles oa on oa.offer_id = g.id
  ),
  artikel as (
    select t.item, t.offer, x.article_id, x.title,
           coalesce(d.variant = a.variant_stem, false) as zelfde
    from treffer t
    join ding d on d.id = t.item
    left join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
    left join public.article_types a on a.supermarket = x.supermarket and a.article_id = x.article_id
  ),
  per as (
    select k.item, k.offer, count(k.article_id)::integer as totaal,
           (count(*) filter (where k.zelfde))::integer as zelfde,
           -- AANTAL TITELS: zoveel artikelen worden hooguit bij naam genoemd
           coalesce((array_agg(k.title order by k.zelfde desc, k.title) filter (where k.article_id is not null))[1:6], '{}') as artikelen
    from artikel k
    group by k.item, k.offer
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', p.item, 'id', g.id, 'supermarkt', g.supermarket, 'titel', g.title,
           'korting', g.discount_text, 'geldig_tot', g.valid_to,
           'artikelen', to_jsonb(p.artikelen), 'artikelen_totaal', p.totaal, 'artikelen_zelfde', p.zelfde,
           'gekozen', d.gekozen,
           'weggeklikt_door', case when d.offer_id is distinct from g.id then w.user_id end)
         order by d.created_at, d.id, (p.zelfde > 0) desc, g.supermarket, g.title, g.id), '[]'::jsonb)
  from per p
  join geldig g on g.id = p.offer
  join ding d on d.id = p.item
  left join public.offer_dismissals w on w.item_id = p.item and w.offer_id = p.offer and w.dismissed
  where public.is_member(p_list);
$$;
