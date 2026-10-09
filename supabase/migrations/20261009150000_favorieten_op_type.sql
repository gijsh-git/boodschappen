-- Favorieten op type (overstap naar producttypes, fase 7).
--
-- Een favoriet is een type, een merk plus een type, of alleen een merk. De tabel favorites verandert niet:
-- de term blijft wat de gebruiker koos of typte, en waar die term voor staat wordt bij het zoeken bepaald
-- (name_type), niet opgeslagen. Zo werkt een correctie van de beheerder of een samengevoegd type vanzelf door.
--   term staat voor een type:  alle artikelen van dat type in de aanbieding ("tandpasta" raakt elke
--                              tandpasta, ook als het woord niet in de titel staat); met een merk erbij
--                              alleen de artikelen van dat merk binnen het type;
--   alleen een merk:           alle artikelen van dat merk, zoals voorheen;
--   term staat nergens voor:   zoals voorheen de woorden van de term in de titel, met de hoofdcategorie.
-- De suggesties bij het typen komen uit de typelijst, met de hoofdgroep erbij. De app verandert niet:
-- offers_for_me() en suggest_favorite_terms() houden hun signatuur en hun JSON.

-- ---------- Suggesties ----------
-- Types waarvan de naam begint met wat er getypt is, of waarin een woord daarmee begint. category is de
-- hoofdgroep, articles het aantal artikelen van het type dat ooit in een aanbieding zat. Security definer,
-- omdat de typelijst voor de app-rollen niet leesbaar is; de functie geeft alleen namen van types terug.
create or replace function public.suggest_favorite_terms(p_query text)
returns table (term text, category text, articles integer)
language sql
stable
security definer
set search_path = ''
as $$
  with q as (select public.normalize_search(p_query) as zoek)
  select p.name, p.main_group,
         (select count(*)::integer from public.article_types t where t.type_id = p.id) as aantal
  from public.product_types p, q
  where char_length(q.zoek) >= 2
    and (starts_with(public.normalize_search(p.name), q.zoek)
      or position(' ' || q.zoek in public.normalize_search(p.name)) > 0)
  order by (public.normalize_search(p.name) = q.zoek) desc,
           starts_with(public.normalize_search(p.name), q.zoek) desc, aantal desc, p.name
  limit 8;
$$;

-- ---------- Voor jou ----------
create or replace function public.offers_for_me() returns jsonb
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
           case when x.category like '%/%' then public.normalize_search(split_part(x.category, '/', 1)) end as hoofd,
           t.type_id as soort
    from geldig g
    join public.offer_articles oa on oa.offer_id = g.id
    join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
    left join public.article_types t on t.supermarket = x.supermarket and t.article_id = x.article_id
  ),
  fav as (
    select f.id, f.term, f.brand, f.normalized_brand, f.created_at,
           array_remove(regexp_split_to_array(coalesce(f.normalized_term, ''), '[^[:alnum:]]+'), '') as woorden,
           public.normalize_search(f.category) as hoofd,
           -- Het type waar de term voor staat, zoals het nu geldt; leeg bij alleen een merk of een onbekende term
           public.name_type(f.term) as soort
    from public.favorites f
    where f.user_id = auth.uid()
  ),
  -- artikel is een voorbeeld uit de aanbieding: bij een favoriet met alleen een merk zet de app die titel op de lijst
  via_fav as (
    select a.offer, f.id, f.term, f.brand, f.created_at, min(a.title) as artikel, count(*)::integer as artikelen
    from fav f
    join art a
      on (case when f.soort is not null then a.soort = f.soort
               else (f.term is null or (cardinality(f.woorden) > 0 and f.woorden <@ a.woorden))
                    and (f.hoofd is null or a.hoofd is null or a.hoofd = f.hoofd) end)
     and (f.normalized_brand is null or a.merk = f.normalized_brand)
    group by a.offer, f.id, f.term, f.brand, f.created_at
  ),
  via_profiel as (
    select distinct a.offer, v.product_id, v.naam, v.dagen
    from art a
    join public.regular_products(auth.uid()) v on v.product_id = a.soort
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
