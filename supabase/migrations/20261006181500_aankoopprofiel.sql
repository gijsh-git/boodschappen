-- Aankoopprofiel (stap 3b): een vlag per product om het buiten het profiel te houden,
-- en één functie die het hele profiel in één keer teruggeeft.

-- ---------- Vlag "telt niet mee in profiel" ----------
-- Voor dingen als draagtas en plastic zak (zie docs/productregels.md). Zulke producten tellen
-- niet mee in het aantal aankopen, het aantal producten en de top 10, wel in uitgegeven en bespaard.
alter table public.products add column counts_in_profile boolean not null default true;

-- Bij samenvoegen verdwijnt het bronproduct; de vlag wordt bewaard zodat losmaken hem precies terugzet
alter table public.product_merges add column source_counts_in_profile boolean not null default true;

create or replace function public.set_product_profile(p_product uuid, p_counts boolean) returns public.products
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare p public.products;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan dit wijzigen'; end if;
  update public.products set counts_in_profile = coalesce(p_counts, true) where id = p_product returning * into p;
  if not found then raise exception 'Product niet gevonden'; end if;
  return p;
end $$;

revoke all on function public.set_product_profile(uuid, boolean) from public, anon;
grant execute on function public.set_product_profile(uuid, boolean) to authenticated, service_role;

create or replace function public.merge_products_internal(p_source uuid, p_target uuid, p_by uuid) returns uuid
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  v_naam text;
  v_telt boolean;
  v_namen text[];
  v_id uuid;
begin
  if p_source = p_target then raise exception 'Kies twee verschillende producten'; end if;
  select name, counts_in_profile into v_naam, v_telt from public.products where id = p_source for update;
  if not found then raise exception 'Product niet gevonden'; end if;
  if not exists (select 1 from public.products where id = p_target) then
    raise exception 'Product niet gevonden';
  end if;
  select coalesce(array_agg(normalized_name order by normalized_name), '{}') into v_namen
    from public.product_aliases where product_id = p_source;
  insert into public.product_merges (target_id, source_id, source_name, aliases, merged_by, source_counts_in_profile)
    values (p_target, p_source, v_naam, v_namen, p_by, v_telt) returning id into v_id;
  update public.product_aliases set product_id = p_target where product_id = p_source;
  delete from public.products where id = p_source;
  return v_id;
end $$;

create or replace function public.undo_merge(p_merge uuid) returns void
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  m public.product_merges;
  v_aantal integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan producten losmaken'; end if;
  select * into m from public.product_merges where id = p_merge and undone_at is null for update;
  if not found then raise exception 'Samenvoeging niet gevonden'; end if;
  if not exists (select 1 from public.products where id = m.target_id) then
    raise exception 'Maak eerst de latere samenvoeging los';
  end if;
  insert into public.products (id, name, counts_in_profile)
    values (m.source_id, m.source_name, m.source_counts_in_profile);
  update public.product_aliases set product_id = m.source_id
    where normalized_name = any(m.aliases) and product_id = m.target_id;
  get diagnostics v_aantal = row_count;
  if v_aantal <> cardinality(m.aliases) then raise exception 'Maak eerst de latere samenvoeging los'; end if;
  update public.product_merges set undone_at = now(), undone_by = auth.uid() where id = p_merge;
end $$;

-- Het scherm Producten toont de vlag erbij
create or replace function public.product_overview() returns jsonb
    language sql stable security definer
    set search_path to 'public'
    as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'namen', t.namen, 'aankopen', t.aankopen,
                                               'telt_mee', t.counts_in_profile)
                            order by lower(t.name), t.id), '[]'::jsonb)
  from (
    select p.id, p.name, p.counts_in_profile,
           coalesce(array_agg(a.normalized_name order by a.normalized_name) filter (where a.normalized_name is not null), '{}') as namen,
           coalesce(sum(c.aantal), 0)::integer as aankopen
    from public.products p
    left join public.product_aliases a on a.product_id = p.id
    left join (
      select normalized_name, count(*) as aantal from public.purchases group by normalized_name
    ) c on c.normalized_name = a.normalized_name
    where public.is_admin()
    group by p.id
  ) t;
$$;

-- ---------- Het aankoopprofiel ----------
-- Alles in één keer, de app toont alleen. Telt de aankopen uit lijsten waarvan je deelnemer bent
-- en die meetellen voor het profiel, ook gearchiveerde. Het is het profiel van het huishouden:
-- alle aankopen van de lijst, ook die van vóór je toetreding.
--   p_period: '4w' (vandaag min 28 dagen), '3m', '12m' of 'alles'; rollend vanaf vandaag
--   p_list:   één lijst, of null voor alle lijsten
-- Dagen en maanden zijn in Nederlandse tijd.
create or replace function public.purchase_profile(p_period text default 'alles', p_list uuid default null) returns jsonb
    language sql stable security definer
    set search_path to 'public'
    as $$
  with tijd as (
    select d.vandaag,
           case p_period
             when '4w' then d.vandaag - 28
             when '3m' then (d.vandaag - interval '3 months')::date
             when '12m' then (d.vandaag - interval '12 months')::date
           end as van
    from (select (now() at time zone 'Europe/Amsterdam')::date as vandaag) d
  ),
  mijn as (
    select l.id, l.name, l.archived_at
    from public.lists l
    join public.list_members m on m.list_id = l.id and m.user_id = auth.uid()
    where l.counts_for_profile
  ),
  -- Alle aankopen die meedoen, los van de periode. Een naam zonder product telt als eigen product.
  basis as materialized (
    select (a.bought_at at time zone 'Europe/Amsterdam')::date as dag,
           coalesce(pr.id::text, a.normalized_name) as product,
           coalesce(pr.name, a.name) as naam,
           coalesce(pr.counts_in_profile, true) as telt,
           a.price,
           coalesce(a.discount, 0) as korting,
           r.store
    from public.purchases a
    join mijn on mijn.id = a.list_id
    left join public.product_aliases pa on pa.normalized_name = a.normalized_name
    left join public.products pr on pr.id = pa.product_id
    left join public.receipts r on r.id = a.receipt_id
    where p_list is null or a.list_id = p_list
  ),
  periode as (
    select b.* from basis b cross join tijd t where t.van is null or b.dag >= t.van
  ),
  -- Geld alleen over aankopen met een prijs; sum() slaat de rijen zonder prijs vanzelf over
  kern as (
    select count(*) filter (where telt) as aankopen,
           count(distinct product) filter (where telt) as producten,
           coalesce(sum(price - korting), 0) as uitgegeven,
           coalesce(sum(korting) filter (where price is not null), 0) as bespaard,
           count(price) as met_prijs,
           count(*) as rijen,
           min(dag) as eerste
    from periode
  ),
  -- Aankoopdagen per product over alle data: meerdere keren op één dag is één keer
  dagen as (
    select distinct product, dag from basis where telt
  ),
  tussen as (
    select product, dag - lag(dag) over (partition by product order by dag) as gat from dagen
  ),
  -- Mediaan van de tussenpozen, pas vanaf 3 aankoopdagen (2 tussenpozen)
  ritme as (
    select product, percentile_cont(0.5) within group (order by gat) as om_de
    from tussen where gat is not null
    group by product having count(*) >= 2
  ),
  laatste as (
    select product, max(dag) as laatste from dagen group by product
  ),
  top as (
    select p.product, min(p.naam) as naam, count(distinct p.dag) as dagen, max(p.dag) as laatste_in_periode
    from periode p where p.telt
    group by p.product
    order by dagen desc, laatste_in_periode desc, naam
    limit 10
  ),
  -- De supermarkt komt van de bon; zonder bon is hij onbekend
  winkels as (
    select mode() within group (order by trim(store)) as winkel,
           count(*) filter (where telt) as aankopen,
           sum(price - korting) as bedrag
    from periode
    group by lower(trim(store))
  ),
  -- Altijd de laatste 12 maanden, los van de periode; bedrag is null als er geen prijzen zijn
  maanden as (
    select to_char(m.maand, 'YYYY-MM') as maand,
           sum(b.price - b.korting) as bedrag,
           m.n = 0 as lopend
    from tijd t
    cross join lateral (
      select n, date_trunc('month', t.vandaag::timestamp) - make_interval(months => n) as maand
      from generate_series(0, 11) n
    ) m
    left join basis b on to_char(b.dag, 'YYYY-MM') = to_char(m.maand, 'YYYY-MM')
    group by m.maand, m.n
  )
  select jsonb_build_object(
    'vandaag', t.vandaag,
    'van', t.van,
    'eerste', k.eerste,
    'lijsten', (
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'gearchiveerd', archived_at is not null)
                                order by archived_at is not null, lower(name)), '[]'::jsonb)
      from mijn),
    'aankopen', k.aankopen,
    'producten', k.producten,
    'uitgegeven', k.uitgegeven,
    'bespaard', k.bespaard,
    'met_prijs', k.met_prijs,
    'rijen', k.rijen,
    'top', (
      select coalesce(jsonb_agg(jsonb_build_object('naam', x.naam, 'dagen', x.dagen, 'om_de', r.om_de, 'laatste', l.laatste)
                                order by x.dagen desc, x.laatste_in_periode desc, x.naam), '[]'::jsonb)
      from top x
      join laatste l on l.product = x.product
      left join ritme r on r.product = x.product),
    'winkels', (
      select coalesce(jsonb_agg(jsonb_build_object('winkel', w.winkel, 'aankopen', w.aankopen, 'bedrag', w.bedrag)
                                order by w.winkel is null, w.aankopen desc, w.winkel), '[]'::jsonb)
      from winkels w),
    'maanden', (
      select jsonb_agg(jsonb_build_object('maand', m.maand, 'bedrag', m.bedrag, 'lopend', m.lopend) order by m.maand)
      from maanden m)
  )
  from tijd t cross join kern k;
$$;

revoke all on function public.purchase_profile(text, uuid) from public, anon;
grant execute on function public.purchase_profile(text, uuid) to authenticated, service_role;
