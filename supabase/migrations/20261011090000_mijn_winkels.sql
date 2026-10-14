-- Mijn winkels (roadmap stap 9, deel 2): per persoon aanvinken welke supermarkten meedoen.
--
-- 1. user_stores: de keuze per persoon, altijd als rij. Iedereen heeft er minstens één; de laatste is niet
--    weg te halen. Bestaande en nieuwe gebruikers krijgen AH.
-- 2. my_supermarkets() en list_supermarkets(p_list) vervangen shown_supermarkets(): Voor jou en de
--    favorieten gebruiken je eigen winkels, een lijst de winkels van alle leden samen.
-- 3. offers_for_list, offer_details_for_list en offers_for_me_all lezen die twee in plaats van het slot.

-- ---------- 1. De tabel ----------
create table public.user_stores (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  supermarket text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, supermarket),
  -- In hoofdletters, zoals offers.supermarket vergeleken wordt; een nieuwe winkel is een nieuwe waarde hier
  constraint user_stores_supermarket_check check (supermarket in ('AH', 'PLUS'))
);
comment on table public.user_stores is
  'De supermarkten die voor deze persoon meedoen (Mijn winkels). Altijd minstens één rij; de laatste is niet te verwijderen.';

alter table public.user_stores enable row level security;
revoke all on table public.user_stores from public, anon, authenticated;
grant select, insert, delete on table public.user_stores to authenticated;
create policy "eigen winkels zien" on public.user_stores for select to authenticated
  using (user_id = auth.uid());
create policy "eigen winkel toevoegen" on public.user_stores for insert to authenticated
  with check (user_id = auth.uid());
create policy "eigen winkel weghalen" on public.user_stores for delete to authenticated
  using (user_id = auth.uid());

-- De laatste winkel blijft staan. Verdwijnt de gebruiker zelf (cascade vanuit auth.users), dan mag het wel.
create function public.keep_last_store() returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if exists (select 1 from auth.users u where u.id = old.user_id)
     and not exists (select 1 from public.user_stores s
                     where s.user_id = old.user_id and s.supermarket <> old.supermarket) then
    raise exception 'Je moet minstens één winkel overhouden';
  end if;
  return old;
end $$;
create trigger user_stores_laatste before delete on public.user_stores
  for each row execute function public.keep_last_store();

-- Iedereen begint met AH
insert into public.user_stores (user_id, supermarket)
select u.id, 'AH' from auth.users u
on conflict do nothing;

create function public.give_default_store() returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  insert into public.user_stores (user_id, supermarket) values (new.id, 'AH') on conflict do nothing;
  return new;
end $$;
create trigger auth_users_winkel after insert on auth.users
  for each row execute function public.give_default_store();

-- ---------- 2. De winkels die tellen ----------
-- In hoofdletters. Zonder rijen (zou niet moeten) valt het terug op AH, zodat er nooit een leeg scherm komt.
create function public.my_supermarkets() returns text[]
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce(array_agg(s.supermarket order by s.supermarket), array['AH'])
  from public.user_stores s
  where s.user_id = auth.uid();
$$;
comment on function public.my_supermarkets() is
  'De supermarkten van de ingelogde gebruiker (Mijn winkels), in hoofdletters. Voor Voor jou en de favorieten.';
revoke all on function public.my_supermarkets() from public, anon;
grant execute on function public.my_supermarkets() to authenticated, service_role;

create function public.list_supermarkets(p_list uuid) returns text[]
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce(array_agg(distinct s.supermarket order by s.supermarket), array['AH'])
  from public.list_members m
  join public.user_stores s on s.user_id = m.user_id
  where m.list_id = p_list and public.is_member(p_list);
$$;
comment on function public.list_supermarkets(uuid) is
  'De supermarkten van alle leden van de lijst samen, in hoofdletters. Voor het bonus-label en het bonuspaneel.';
revoke all on function public.list_supermarkets(uuid) from public, anon;
grant execute on function public.list_supermarkets(uuid) to authenticated, service_role;

-- ---------- 3. De functies die erop filteren ----------
-- Een aanbieding die zelf op de lijst staat (items.offer_id) blijft zichtbaar, ook als de winkel daarna uit
-- iemands profiel gaat: die tak kijkt niet naar de winkels.
create or replace function public.offers_for_list(p_list uuid)
returns table (item_id uuid, supermarkt text, aantal integer, weggeklikt integer, korting text, geldig_tot date)
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket, o.discount_text, o.valid_to
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  treffer as (
    select i.id as item, g.id as offer, g.supermarket,
           exists (select 1 from public.offer_dismissals w
                   where w.item_id = i.id and w.offer_id = g.id and w.dismissed) as weg,
           null::text as korting, null::date as geldig_tot
    from public.items i
    cross join lateral public.term_articles(i.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list and public.is_member(p_list) and i.original_name is null
      and i.offer_id is distinct from g.id
      and upper(g.supermarket) = any (public.list_supermarkets(p_list))
    union
    select i.id, g.id, g.supermarket, false, g.discount_text, g.valid_to
    from public.items i
    join geldig g on g.id = i.offer_id
    where i.list_id = p_list
  )
  select t.item, t.supermarket,
         (count(distinct t.offer) filter (where not t.weg))::integer,
         (count(distinct t.offer) filter (where t.weg))::integer,
         max(t.korting), max(t.geldig_tot)
  from treffer t
  where public.is_member(p_list)
  group by t.item, t.supermarket;
$$;

-- Het bonuspaneel: hetzelfde.
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
         order by d.created_at, d.id, (p.zelfde > 0) desc, g.title, g.id), '[]'::jsonb)
  from per p
  join geldig g on g.id = p.offer
  join ding d on d.id = p.item
  left join public.offer_dismissals w on w.item_id = p.item and w.offer_id = p.offer and w.dismissed
  where public.is_member(p_list);
$$;


-- ---------- Voor jou ----------
-- Alleen de getoonde winkels. De hoofdgroep van een artikel is die van zijn type (product_types.main_group);
-- een artikel zonder type heeft er geen. Ze telt alleen bij een favoriet waarvan de term geen type is.
create or replace function public.offers_for_me_all() returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.*
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
      and upper(o.supermarket) = any (public.my_supermarkets())
  ),
  art as materialized (
    select g.id as offer, x.supermarket, x.article_id, x.title,
           public.normalize_search(x.brand) as merk,
           array_remove(regexp_split_to_array(public.normalize_search(x.title), '[^[:alnum:]]+'), '') as woorden,
           public.normalize_search(pt.main_group) as hoofd,
           t.type_id as soort
    from geldig g
    join public.offer_articles oa on oa.offer_id = g.id
    join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
    left join public.article_types t on t.supermarket = x.supermarket and t.article_id = x.article_id
    left join public.product_types pt on pt.id = t.type_id
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

-- ---------- Het slot is niet meer nodig ----------
drop function public.shown_supermarkets();
