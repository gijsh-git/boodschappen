-- Wat er precies in de aanbieding is bij de items op de lijst (roadmap stap 5): de groene balk in de kop
-- van de lijst klapt uit en toont per item de aanbiedingen met hun artikelen.
--
-- Alleen een nieuwe functie; er verandert niets aan bestaande tabellen of functies.

-- Per item en aanbieding één regel, als JSON:
--   [{ item_id, id, supermarkt, titel, korting, geldig_tot, artikelen: [titel, ...], artikelen_totaal }]
-- Dezelfde twee routes als offers_for_list. artikelen zijn de artikelen waar het om gaat: via het product de
-- artikelen van dat product in de aanbieding, via items.offer_id alle artikelen van de aanbieding.
-- Hooguit 6 titels per regel; artikelen_totaal zegt hoeveel het er zijn.
create function public.offer_details_for_list(p_list uuid) returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket, o.title, o.discount_text, o.valid_to
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  treffer as (
    select i.id as item, g.id as offer, oa.supermarket, oa.article_id
    from public.items i
    join public.product_aliases pa on pa.normalized_name = i.normalized_name
    join public.article_products() ap on ap.product_id = pa.product_id
    join public.offer_articles oa on upper(oa.supermarket) = ap.supermarket and oa.article_id = ap.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list
    union
    select i.id, g.id, oa.supermarket, oa.article_id
    from public.items i
    join geldig g on g.id = i.offer_id
    left join public.offer_articles oa on oa.offer_id = g.id
    where i.list_id = p_list
  ),
  per as (
    select t.item, t.offer, count(x.article_id)::integer as totaal,
           -- AANTAL TITELS: zoveel artikelen worden hooguit bij naam genoemd
           coalesce((array_agg(x.title order by x.title) filter (where x.article_id is not null))[1:6], '{}') as artikelen
    from treffer t
    left join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
    group by t.item, t.offer
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', p.item, 'id', g.id, 'supermarkt', g.supermarket, 'titel', g.title,
           'korting', g.discount_text, 'geldig_tot', g.valid_to,
           'artikelen', to_jsonb(p.artikelen), 'artikelen_totaal', p.totaal)
         order by g.title, g.id, p.item), '[]'::jsonb)
  from per p
  join geldig g on g.id = p.offer
  where public.is_member(p_list);
$$;

revoke all on function public.offer_details_for_list(uuid) from public, anon;
grant execute on function public.offer_details_for_list(uuid) to authenticated, service_role;
