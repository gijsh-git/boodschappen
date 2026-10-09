-- Een aanbieding wegklikken (roadmap stap 7, deel 3).
--
-- "Niet deze week" bij een aanbieding van een item verbergt die aanbieding bij dat item voor alle leden van
-- de lijst, tot de aanbieding verloopt. Wie het deed staat erbij en het is terug te halen. In "Voor jou" kan
-- het ook, daar alleen voor jezelf. Een aanbieding is een rij in offers per week (valid_from), dus komt
-- dezelfde actie later terug, dan is dat een nieuwe rij en is hij weer zichtbaar. Zijn alle aanbiedingen van
-- een item weggeklikt, dan verdwijnt het Bonus-label op dat item.

-- ---------- Opslag ----------
-- Met item: voor de hele lijst (list_id erbij voor Realtime en de policy). Zonder item: alleen voor user_id,
-- in "Voor jou". Terughalen zet dismissed uit in plaats van de rij te verwijderen: een UPDATE is op de lijst
-- te filteren in Realtime, een DELETE niet.
create table public.offer_dismissals (
  id uuid primary key default gen_random_uuid(),
  offer_id uuid not null references public.offers(id) on delete cascade,
  item_id uuid references public.items(id) on delete cascade,
  list_id uuid references public.lists(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  dismissed boolean not null default true,
  created_at timestamptz not null default now(),
  check ((item_id is null) = (list_id is null))
);
create unique index offer_dismissals_item_idx on public.offer_dismissals (item_id, offer_id) where item_id is not null;
create unique index offer_dismissals_user_idx on public.offer_dismissals (user_id, offer_id) where item_id is null;
create index offer_dismissals_list_idx on public.offer_dismissals (list_id) where list_id is not null;
comment on table public.offer_dismissals is
  'Weggeklikte aanbiedingen ("Niet deze week"). Met item_id: bij dat item, voor de hele lijst; user_id is wie het deed. Zonder item_id: in Voor jou, alleen voor user_id. Verdwijnt vanzelf met de aanbieding.';

-- Lezen mag (voor Realtime): leden van de lijst, en je eigen rijen. Schrijven gaat alleen via de functies.
alter table public.offer_dismissals enable row level security;
revoke all on table public.offer_dismissals from public, anon, authenticated;
grant select on table public.offer_dismissals to authenticated;
create policy "leden zien weggeklikte aanbiedingen" on public.offer_dismissals for select
  using ((list_id is not null and public.is_member(list_id)) or (list_id is null and user_id = auth.uid()));
alter publication supabase_realtime add table public.offer_dismissals;

-- ---------- Wegklikken en terughalen bij een item ----------
create function public.dismiss_offer(p_item uuid, p_offer uuid) returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_lijst uuid;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  select list_id into v_lijst from public.items where id = p_item;
  if not found or not public.is_member(v_lijst) then raise exception 'Item niet gevonden'; end if;
  if not exists (select 1 from public.offers where id = p_offer) then raise exception 'Aanbieding niet gevonden'; end if;
  insert into public.offer_dismissals (offer_id, item_id, list_id, user_id)
  values (p_offer, p_item, v_lijst, auth.uid())
  on conflict (item_id, offer_id) where item_id is not null
  do update set dismissed = true, user_id = excluded.user_id, created_at = now();
end $$;

create function public.restore_offer(p_item uuid, p_offer uuid) returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  update public.offer_dismissals
     set dismissed = false
   where item_id = p_item and offer_id = p_offer and public.is_member(list_id);
end $$;

-- In "Voor jou": alleen voor jezelf, tot de aanbieding verloopt
create function public.dismiss_offer_for_me(p_offer uuid) returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  if not exists (select 1 from public.offers where id = p_offer) then raise exception 'Aanbieding niet gevonden'; end if;
  insert into public.offer_dismissals (offer_id, user_id)
  values (p_offer, auth.uid())
  on conflict (user_id, offer_id) where item_id is null
  do update set dismissed = true, created_at = now();
end $$;

-- ---------- Voor jou ----------
-- De bestaande functie blijft het zoeken en de volgorde doen, onder een andere naam; offers_for_me() laat
-- daaruit weg wat je zelf hebt weggeklikt.
alter function public.offers_for_me() rename to offers_for_me_all;
revoke all on function public.offers_for_me_all() from public, anon, authenticated;
grant execute on function public.offers_for_me_all() to service_role;

create function public.offers_for_me() returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(e.aanbieding order by e.nr), '[]'::jsonb)
  from jsonb_array_elements(public.offers_for_me_all()) with ordinality as e(aanbieding, nr)
  where not exists (
    select 1 from public.offer_dismissals w
    where w.item_id is null and w.user_id = auth.uid() and w.dismissed
      and w.offer_id = (e.aanbieding->>'id')::uuid);
$$;
revoke all on function public.offers_for_me() from public, anon;
grant execute on function public.offers_for_me() to authenticated, service_role;

-- ---------- Bonus-label op de lijst ----------
-- Als voorheen, met een kolom erbij: aantal telt alleen de aanbiedingen die niet zijn weggeklikt, weggeklikt
-- telt de rest. Een rij met aantal 0 geeft geen label; de app toont de balk dan nog wel, om terug te halen.
-- Wegklikken geldt voor de route via de naam; een aanbieding die zelf op de lijst staat (items.offer_id)
-- blijft.
drop function public.offers_for_list(uuid);
create function public.offers_for_list(p_list uuid)
returns table (item_id uuid, supermarkt text, aantal integer, weggeklikt integer)
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  treffer as (
    select i.id as item, g.id as offer, g.supermarket,
           exists (select 1 from public.offer_dismissals w
                   where w.item_id = i.id and w.offer_id = g.id and w.dismissed) as weg
    from public.items i
    cross join lateral public.term_articles(i.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list and public.is_member(p_list) and i.original_name is null
      and i.offer_id is distinct from g.id
    union
    select i.id, g.id, g.supermarket, false
    from public.items i
    join geldig g on g.id = i.offer_id
    where i.list_id = p_list
  )
  select t.item, t.supermarket,
         (count(distinct t.offer) filter (where not t.weg))::integer,
         (count(distinct t.offer) filter (where t.weg))::integer
  from treffer t
  where public.is_member(p_list)
  group by t.item, t.supermarket;
$$;
revoke all on function public.offers_for_list(uuid) from public, anon;
grant execute on function public.offers_for_list(uuid) to authenticated, service_role;

-- weggeklikt_door: wie de aanbieding bij dit item heeft weggeklikt, of leeg. De app zet die onderaan.
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

-- ---------- Rechten ----------
revoke all on function public.dismiss_offer(uuid, uuid) from public, anon;
revoke all on function public.restore_offer(uuid, uuid) from public, anon;
revoke all on function public.dismiss_offer_for_me(uuid) from public, anon;
grant execute on function public.dismiss_offer(uuid, uuid) to authenticated, service_role;
grant execute on function public.restore_offer(uuid, uuid) to authenticated, service_role;
grant execute on function public.dismiss_offer_for_me(uuid) to authenticated, service_role;
