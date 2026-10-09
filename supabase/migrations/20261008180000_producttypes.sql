-- Producttypes (overstap van de catalogus met samenvoegen naar een vaste typelijst, fase 1).
--
-- Tot nu toe is een product een verzameling namen die de beheerder met de hand samenvoegt. Daarvoor in de
-- plaats komt een vaste lijst producttypes met de hoofdcategorie van de supermarkt als hoofdgroep, waar
-- artikelen, getypte termen en aankopen later automatisch aan gekoppeld worden.
--
-- Deze migratie legt alleen de lijst zelf vast en verandert niets aan bestaande tabellen of functies:
-- products, product_aliases en alles wat daarop rekent blijven werken tot de omschakeling.
--   scripts/producttypes-voorstellen.py  leest type_proposal_work() en laat de AI een typelijst voorstellen;
--   de beheerder leest docs/producttypes.csv na;
--   scripts/producttypes-laden.py        zet de lijst in de database via save_product_types().

-- ---------- Opslag ----------
-- Een type is het niveau waarop een koper wisselt bij een aanbieding (docs/productregels.md): "brood",
-- "pizza", "cola zero". key is de naam in sleutelvorm, zodat "ice tea" en "icetea" niet naast elkaar bestaan.
create table public.product_types (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  key text generated always as (public.match_key(name)) stored,
  main_group text not null check (btrim(main_group) <> ''),
  scope text,
  excludes text,
  counts_in_profile boolean not null default true,
  created_at timestamptz not null default now(),
  constraint product_types_key_uniek unique (key),
  constraint product_types_key_check check (key <> '')
);
create index product_types_main_group_idx on public.product_types (main_group);
comment on column public.product_types.main_group is
  'Hoofdgroep: de hoofdcategorie van de supermarkt (bij AH het deel vóór de "/" in articles.category), of "Geen boodschappen".';
comment on column public.product_types.scope is
  'Wat er onder dit type valt, in één zin. Gaat mee naar de AI die artikelen en termen aan een type koppelt.';
comment on column public.product_types.excludes is
  'Wat er niet onder valt en waar dat dan wel hoort: de varianten waar je niet tussen wisselt.';
comment on column public.product_types.counts_in_profile is
  'false: telt niet mee in het aankoopprofiel (draagtas, kleding), wel in uitgegeven en bespaard.';

-- Geen policies en geen rechten: alleen de functies komen bij deze tabel
alter table public.product_types enable row level security;
revoke all on table public.product_types from public, anon, authenticated;

-- ---------- Voor het script dat de typelijst voorstelt ----------
-- Alles waar de typelijst op gebaseerd wordt, als JSON:
--   { hoofdgroepen: [{ naam, artikelen,
--                      subcategorieen: [{ naam, artikelen, voorbeelden: [titel],
--                                         lijstnamen: [{ naam, artikelen }] }] }],
--     producten: [{ id, naam, namen: [naam], aankopen, items, telt_mee, hoofdgroep }],
--     termen: [term] }
-- hoofdgroepen: alle artikelen die ooit in een aanbieding zaten, per hoofd- en subcategorie. Een artikel dat
--   alleen als losse aanbieding is gezien heeft alleen een subcategorie; het krijgt de hoofdcategorie waar
--   die subcategorie verder onder staat, en anders de hoofdgroep null.
-- voorbeelden: hooguit 8 titels, een vaste willekeurige greep (niet alfabetisch, dat geeft alleen huismerk).
-- lijstnamen: de eerste lijstnaam van de artikelen (article_names, position 1): het product volgens de regels.
-- producten: de huidige catalogus. hoofdgroep is de hoofdcategorie van de meeste artikelen van het product
--   (via de bon of een goedgekeurde koppeling), of null als het geen artikelen heeft.
-- termen: wat op een lijst is getypt en nergens op matchte.
-- Er gaan geen aankopen, lijsten of gebruikers mee, alleen namen en aantallen.
create function public.type_proposal_work() returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan de typelijst voorstellen'; end if;
  with ruw as materialized (
    select x.supermarket, x.article_id, x.title,
           case when x.category like '%/%' then nullif(btrim(split_part(x.category, '/', 1)), '') end as hoofd,
           nullif(btrim(case when x.category like '%/%' then split_part(x.category, '/', 2) else x.category end), '') as sub
    from public.articles x
  ),
  -- Onder welke hoofdcategorie een subcategorie het vaakst staat
  sub_hoofd as (
    select distinct on (t.sub) t.sub, t.hoofd
    from (select r.sub, r.hoofd, count(*) as n from ruw r
          where r.hoofd is not null and r.sub is not null group by r.sub, r.hoofd) t
    order by t.sub, t.n desc, t.hoofd
  ),
  art as materialized (
    select r.supermarket, r.article_id, r.title, coalesce(r.hoofd, sh.hoofd) as hoofd, r.sub
    from ruw r
    left join sub_hoofd sh on sh.sub = r.sub
  ),
  sub as (
    select a.hoofd, a.sub, count(*)::integer as artikelen,
           -- AANTAL VOORBEELDEN per subcategorie
           (array_agg(a.title order by md5(a.article_id)))[1:8] as voorbeelden
    from art a
    group by a.hoofd, a.sub
  ),
  naam as (
    select a.hoofd, a.sub, n.name, count(*)::integer as aantal
    from art a
    join public.article_names n on n.supermarket = a.supermarket and n.article_id = a.article_id
    where n.position = 1
    group by a.hoofd, a.sub, n.name
  ),
  prod_groep as (
    select ap.product_id, a.hoofd, count(*) as n
    from public.article_products() ap
    join art a on upper(a.supermarket) = ap.supermarket and a.article_id = ap.article_id
    where a.hoofd is not null
    group by ap.product_id, a.hoofd
  ),
  prod as (
    select p.id, p.name, p.counts_in_profile,
           (select array_agg(pa.normalized_name order by pa.normalized_name)
            from public.product_aliases pa where pa.product_id = p.id) as namen,
           (select count(*) from public.purchases c
            join public.product_aliases pa on pa.normalized_name = c.normalized_name
            where pa.product_id = p.id)::integer as aankopen,
           (select count(*) from public.items i
            join public.product_aliases pa on pa.normalized_name = i.normalized_name
            where pa.product_id = p.id)::integer as items,
           (select g.hoofd from prod_groep g where g.product_id = p.id order by g.n desc, g.hoofd limit 1) as hoofd
    from public.products p
  )
  select jsonb_build_object(
    'hoofdgroepen', (
      select coalesce(jsonb_agg(jsonb_build_object('naam', h.hoofd, 'artikelen', h.artikelen, 'subcategorieen', h.subs)
                                order by h.hoofd nulls last), '[]'::jsonb)
      from (
        select s.hoofd, sum(s.artikelen)::integer as artikelen,
               jsonb_agg(jsonb_build_object(
                 'naam', s.sub, 'artikelen', s.artikelen, 'voorbeelden', to_jsonb(s.voorbeelden),
                 'lijstnamen', coalesce((
                   select jsonb_agg(jsonb_build_object('naam', n.name, 'artikelen', n.aantal) order by n.aantal desc, n.name)
                   from naam n
                   where n.hoofd is not distinct from s.hoofd and n.sub is not distinct from s.sub), '[]'::jsonb))
                 order by s.sub nulls last) as subs
        from sub s
        group by s.hoofd
      ) h),
    'producten', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'naam', p.name, 'namen', to_jsonb(p.namen), 'aankopen', p.aankopen, 'items', p.items,
               'telt_mee', p.counts_in_profile, 'hoofdgroep', p.hoofd)
             order by lower(p.name), p.id), '[]'::jsonb)
      from prod p
      where p.namen is not null),
    'termen', (
      select coalesce(jsonb_agg(u.term order by u.times desc, u.term), '[]'::jsonb)
      from public.unmatched_terms u))
  into v;
  return v;
end $$;

-- ---------- De typelijst opslaan ----------
-- p_rows: [{ name, main_group, scope, excludes, counts_in_profile }], de hele lijst uit docs/producttypes.csv.
-- Een type wordt herkend aan zijn naam in sleutelvorm: bestaat het al, dan worden hoofdgroep, afbakening en
-- vlag bijgewerkt (en de schrijfwijze van de naam); anders komt het erbij. Er wordt nooit een type verwijderd:
-- niet_in_bestand telt de types die wel in de database staan maar niet in p_rows.
create function public.save_product_types(p_rows jsonb) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  r jsonb;
  v_naam text;
  v_groep text;
  v_nieuw_rij boolean;
  v_nieuw integer := 0;
  v_bijgewerkt integer := 0;
  v_gelijk integer := 0;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan de typelijst opslaan'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Geen types om op te slaan';
  end if;
  select min(x->>'name') into v_naam
  from jsonb_array_elements(p_rows) x
  group by public.match_key(x->>'name')
  having count(*) > 1
  limit 1;
  if v_naam is not null then raise exception 'Het type "%" staat meer dan één keer in de lijst', v_naam; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_naam := btrim(regexp_replace(coalesce(r->>'name', ''), '\s+', ' ', 'g'));
    v_groep := btrim(coalesce(r->>'main_group', ''));
    if public.match_key(v_naam) = '' or char_length(v_naam) > 80 then
      raise exception 'Ongeldige typenaam: "%"', v_naam;
    end if;
    if v_groep = '' then raise exception 'Het type "%" heeft geen hoofdgroep', v_naam; end if;

    insert into public.product_types as t (name, main_group, scope, excludes, counts_in_profile)
    values (v_naam, v_groep, nullif(btrim(r->>'scope'), ''), nullif(btrim(r->>'excludes'), ''),
            coalesce((r->>'counts_in_profile')::boolean, true))
    on conflict on constraint product_types_key_uniek do update set
      name = excluded.name,
      main_group = excluded.main_group,
      scope = excluded.scope,
      excludes = excluded.excludes,
      counts_in_profile = excluded.counts_in_profile
    where (t.name, t.main_group, t.scope, t.excludes, t.counts_in_profile)
          is distinct from (excluded.name, excluded.main_group, excluded.scope, excluded.excludes, excluded.counts_in_profile)
    returning (xmax = 0) into v_nieuw_rij;
    if not found then v_gelijk := v_gelijk + 1;
    elsif v_nieuw_rij then v_nieuw := v_nieuw + 1;
    else v_bijgewerkt := v_bijgewerkt + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'nieuw', v_nieuw, 'bijgewerkt', v_bijgewerkt, 'ongewijzigd', v_gelijk,
    'totaal', (select count(*) from public.product_types),
    'niet_in_bestand', (
      select count(*) from public.product_types t
      where not exists (
        select 1 from jsonb_array_elements(p_rows) x where public.match_key(x->>'name') = t.key)));
end $$;

revoke all on function public.type_proposal_work() from public, anon;
revoke all on function public.save_product_types(jsonb) from public, anon;
grant execute on function public.type_proposal_work() to authenticated, service_role;
grant execute on function public.save_product_types(jsonb) to authenticated, service_role;
