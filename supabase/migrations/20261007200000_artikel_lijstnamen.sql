-- Lijstnamen per artikel (roadmap stap 5, deel 2): het Bonus-label voor iets wat je voor het eerst op de lijst zet.
--
-- Niveau 2 kent alleen producten die al bestaan en telt pas na goedkeuring. Wie morgen "andijvie" op de lijst
-- zet zou daardoor geen label krijgen, terwijl de andijvie in de bonus is. Daarom legt het script
-- (scripts/artikel-voorstellen.py) bij elk artikel ook hooguit drie lijstnamen vast: de namen die iemand op
-- een lijst zou typen ("AH Andijvie fijngesneden 500 gram" wordt "andijvie"). Een item krijgt het label als
-- zijn naam na Nederlandse stamming gelijk is aan zo'n naam van een artikel in een geldige aanbieding.
--
-- Bewuste uitzondering op "geen naammatching in de database": alleen gelijkheid van de hele naam na stamming
-- (geen "lijkt op", geen deel van de titel), en alleen voor het label op de lijst. Voor jou blijft werken
-- via de bon en de goedgekeurde koppelingen. Er worden geen producten of aliassen voor aangemaakt, en er is
-- geen goedkeuring nodig: een fout kost hooguit een label bij iets wat je toch al wilde kopen.
--
-- Wijzigt bestaande functies (zelfde signatuur): article_link_work(), offers_for_list() en
-- offer_details_for_list().

-- ---------- Stamming ----------
-- De vorm waarin een itemnaam en een lijstnaam worden vergeleken: via normalize_search (kleine letters, zonder
-- accenten) en de Nederlandse stamming van Postgres. "Tomaat" en "tomaten" worden gelijk, de woordvolgorde
-- maakt niet uit en lidwoorden en voegwoorden vallen weg. Leeg als er niets overblijft.
-- Immutable verklaard (de stamming hoort bij de Postgres-versie), nodig voor de berekende kolom hieronder.
create function public.list_stem(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(pg_catalog.strip(pg_catalog.to_tsvector('pg_catalog.dutch'::regconfig, public.normalize_search(p_text)))::text, '');
$$;
comment on function public.list_stem(text) is
  'Stamvorm van een naam op een boodschappenlijst: normalize_search plus Nederlandse stamming. Voor het Bonus-label via article_names.';

-- ---------- Opslag ----------
-- Hooguit drie namen per artikel, van algemeen (position 1) naar specifiek. Blijft staan als een voorstel
-- wordt afgewezen: de naam hoort bij het artikel, niet bij een product.
create table public.article_names (
  supermarket text not null,
  article_id text not null,
  position smallint not null check (position between 1 and 3),
  name text not null check (btrim(name) <> ''),
  stem text generated always as (public.list_stem(name)) stored,
  created_at timestamptz not null default now(),
  primary key (supermarket, article_id, position),
  foreign key (supermarket, article_id) references public.articles(supermarket, article_id)
);
create index article_names_stem_idx on public.article_names (stem);

-- Geen policies en geen rechten: alleen de functies komen bij deze tabel
alter table public.article_names enable row level security;
revoke all on table public.article_names from public, anon, authenticated;

-- Slaat de lijstnamen van het script op. p_rows is een lijst:
--   [{ supermarket, article_id, names: [naam, ...] }]
-- Vervangt de namen van het artikel. Bewaart hooguit drie namen, in de gegeven volgorde, zonder namen waar na
-- stamming niets van overblijft en zonder dubbele stamvormen. Geeft het aantal artikelen met namen terug.
create function public.save_article_names(p_rows jsonb) returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare
  r jsonb;
  v_supermarkt text;
  v_artikel text;
  v_rijen integer;
  v_aantal integer := 0;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan artikelen koppelen'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen namen om op te slaan'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_supermarkt := r->>'supermarket';
    v_artikel := r->>'article_id';
    if jsonb_typeof(r->'names') <> 'array'
       or not exists (select 1 from public.articles where supermarket = v_supermarkt and article_id = v_artikel) then
      continue;
    end if;
    delete from public.article_names where supermarket = v_supermarkt and article_id = v_artikel;
    insert into public.article_names (supermarket, article_id, position, name)
    select v_supermarkt, v_artikel, row_number() over (order by u.volgorde), u.naam
    from (
      select distinct on (public.list_stem(n.naam)) btrim(n.naam) as naam, n.volgorde
      from jsonb_array_elements_text(r->'names') with ordinality as n(naam, volgorde)
      where public.list_stem(n.naam) <> '' and char_length(btrim(n.naam)) <= 60
      order by public.list_stem(n.naam), n.volgorde
    ) u
    order by u.volgorde
    limit 3;
    get diagnostics v_rijen = row_count;
    if v_rijen > 0 then v_aantal := v_aantal + 1; end if;
  end loop;
  return v_aantal;
end $$;

-- ---------- Voor het script ----------
-- Als voorheen, met per artikel erbij wat er nodig is:
--   naam_nodig:    het artikel heeft nog geen lijstnamen (geldt ook voor artikelen die op een bon staan);
--   product_nodig: het artikel staat niet op een bon, en heeft geen status of "geen product" terwijl er
--                  sindsdien kandidaten zijn bijgekomen.
-- Een artikel komt in het werk als één van de twee waar is. nieuwe_producten is alleen gevuld bij een
-- herbeoordeling (product_nodig met een eerder oordeel).
create or replace function public.article_link_work() returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan artikelen koppelen'; end if;
  with bon as materialized (
    select distinct b.supermarket, b.article_id from public.receipt_articles() b
  ),
  kandidaat as materialized (
    select p.id, p.name, p.created_at
    from public.products p
    where exists (
      select 1 from public.product_aliases pa
      where pa.product_id = p.id
        and (exists (select 1 from public.purchases a where a.normalized_name = pa.normalized_name)
          or exists (select 1 from public.items i where i.normalized_name = pa.normalized_name)))
  ),
  alle as (
    select x.supermarket, x.article_id, x.title, x.brand, x.size, x.category, l.judged_at,
           not exists (
             select 1 from public.article_names n
             where n.supermarket = x.supermarket and n.article_id = x.article_id) as naam_nodig,
           not exists (
             select 1 from bon b where b.supermarket = upper(x.supermarket) and b.article_id = x.article_id)
           and (l.article_id is null
             or (l.status = 'no_product' and exists (select 1 from kandidaat k where k.created_at > l.judged_at))) as product_nodig
    from public.articles x
    left join public.article_links l on l.supermarket = x.supermarket and l.article_id = x.article_id
  ),
  werk as (
    select * from alle a where a.naam_nodig or a.product_nodig
  )
  select jsonb_build_object(
    'gelezen_op', now(),
    'producten', (
      select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'naam', k.name, 'zoek', public.normalize_search(k.name))
                                order by lower(k.name), k.id), '[]'::jsonb)
      from kandidaat k),
    'artikelen', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'supermarket', w.supermarket, 'article_id', w.article_id, 'titel', w.title, 'merk', w.brand,
               'inhoud', w.size, 'categorie', w.category,
               'subcategorie_zoek', public.normalize_search(regexp_replace(w.category, '^[^/]*/', '')),
               'naam_nodig', w.naam_nodig, 'product_nodig', w.product_nodig,
               'afgewezen', (
                 select coalesce(jsonb_agg(r.product_id), '[]'::jsonb)
                 from public.article_link_rejections r
                 where r.supermarket = w.supermarket and r.article_id = w.article_id),
               'nieuwe_producten', case when w.product_nodig and w.judged_at is not null then (
                 select coalesce(jsonb_agg(k.id), '[]'::jsonb) from kandidaat k where k.created_at > w.judged_at) end)
             order by w.supermarket, w.category nulls last, w.title, w.article_id), '[]'::jsonb)
      from werk w))
  into v;
  return v;
end $$;

-- ---------- Bonus-label op de lijst ----------
-- Per item bij welke supermarkt er hoeveel geldige aanbiedingen zijn. Drie routes, elke aanbieding telt één keer:
--   1. via het product: naam → product_aliases → de artikelen van dat product → aanbiedingen;
--   2. via de aanbieding waarmee het item op de lijst is gezet (items.offer_id);
--   3. via de lijstnaam: de itemnaam is na stamming gelijk aan een lijstnaam van een artikel in de aanbieding.
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
    union
    select i.id, g.id, g.supermarket
    from public.items i
    join public.article_names n on n.stem = public.list_stem(i.name) and n.stem <> ''
    join public.offer_articles oa on oa.supermarket = n.supermarket and oa.article_id = n.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list
  )
  select t.item, t.supermarket, count(distinct t.offer)::integer
  from treffer t
  where public.is_member(p_list)
  group by t.item, t.supermarket;
$$;

-- Wat er precies in de aanbieding is bij de items op de lijst: dezelfde drie routes als offers_for_list.
-- artikelen zijn de artikelen waar het om gaat: via het product of de lijstnaam de artikelen die daarbij
-- horen, via items.offer_id alle artikelen van de aanbieding.
create or replace function public.offer_details_for_list(p_list uuid) returns jsonb
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
    union
    select i.id, g.id, oa.supermarket, oa.article_id
    from public.items i
    join public.article_names n on n.stem = public.list_stem(i.name) and n.stem <> ''
    join public.offer_articles oa on oa.supermarket = n.supermarket and oa.article_id = n.article_id
    join geldig g on g.id = oa.offer_id
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

-- ---------- Rechten ----------
revoke all on function public.list_stem(text) from public, anon;
revoke all on function public.save_article_names(jsonb) from public, anon;
grant execute on function public.list_stem(text) to authenticated, service_role;
grant execute on function public.save_article_names(jsonb) to authenticated, service_role;
