-- De omschakeling: profiel, Voor jou en het Bonus-label rekenen op producttypes (fase 4).
--
-- Tot hier werkte alles op de catalogus (products, product_aliases, article_products()). Vanaf hier:
--   aankoop  → type via purchase_types(): het artikel op de bon, anders de naam;
--   artikel  → type via article_types;
--   term     → type of merk via term_match(), waar term_articles() de artikelen bij zoekt.
-- De functies die de app aanroept houden hun signatuur en hun JSON: purchase_profile, offers_for_me,
-- offers_for_list, offer_details_for_list, match_receipt_items en add_offer_item. De app verandert niet.
--
-- De oude tabellen en ensure_product() blijven ongewijzigd staan en worden nog bijgehouden, zodat terug kan
-- met één migratie die de functies hieronder terugzet. Het scherm Producten toont nog de oude catalogus; die
-- stuurt vanaf nu niets meer aan (fase 6 vervangt het scherm). term_synonyms.target blijft tot het opruimen.

-- ---------- Stamvorm bij types en namen ----------
-- "tomaat" is "tomaten": de naam na Nederlandse stamming, zoals eerder bij de lijstnamen.
alter table public.product_types
  add column stem text generated always as (public.list_stem(name)) stored;
alter table public.term_synonyms
  add column stem text generated always as (public.list_stem(term)) stored;
create index product_types_stem_idx on public.product_types (stem);
create index term_synonyms_stem_idx on public.term_synonyms (stem);

-- Het type van een item op de lijst: een aantekening van het moment van toevoegen, zoals product_id was.
-- Het label rekent er niet op (dat gaat via de naam of de aanbieding).
alter table public.items
  add column type_id uuid references public.product_types(id) on delete set null;
create index items_type_idx on public.items (type_id);

-- ---------- Waar staat een term voor? ----------
-- Eén rij als de term bekend is, geen rij als hij nergens op matcht. De eerste laag met een treffer wint:
--   1 de naam van een type ("soep"); die is door de beheerder vastgesteld en gaat altijd voor;
--   3 een merk ("nivea"): wie precies een merk typt bedoelt alles van dat merk, ook als de naam in de
--     catalogus aan één type hing;
--   2 een naam in term_synonyms ("tomatensoep" voor soep, "sensodyne tandpasta" voor tandpasta van dat merk).
--     Zonder type is de term beoordeeld en hoort hij nergens bij: wel een rij, geen artikelen;
--   1/2 hetzelfde na stamming ("tomaat" voor tomaten);
--   4 tolerant: de best gelijkende typenaam, naam of merk, vanaf de grens in settings en vanaf 5 tekens.
-- step houdt de nummers van voorheen: 1 exact, 2 synoniem, 3 merk, 4 tolerant. De titellaag (5) is vervallen:
-- een term die hier niets vindt gaat naar handle_unmatched_term().
create function public.term_match(p_name text)
returns table (step smallint, type_id uuid, brand_key text)
language plpgsql stable security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_key text := public.match_key(p_name);
  v_stem text;
  v_grens real;
begin
  if v_key = '' then return; end if;

  -- 1. de naam van een type
  return query select 1::smallint, p.id, null::text from public.product_types p where p.key = v_key;
  if found then return; end if;

  -- 3. een merk
  if exists (select 1 from public.articles x where x.brand_key = v_key) then
    return query select 3::smallint, null::uuid, v_key;
    return;
  end if;

  -- 2. een naam van een type, eventueel met een merk erbij
  return query select 2::smallint, s.type_id, s.brand_key from public.term_synonyms s where s.key = v_key;
  if found then return; end if;

  -- 1 en 2 na stamming
  v_stem := public.list_stem(p_name);
  if v_stem <> '' then
    return query select 1::smallint, p.id, null::text
                 from public.product_types p where p.stem = v_stem order by p.name limit 1;
    if found then return; end if;
    return query select 2::smallint, s.type_id, s.brand_key
                 from public.term_synonyms s where s.stem = v_stem and s.type_id is not null
                 order by s.key limit 1;
    if found then return; end if;
  end if;

  -- 4. tolerant. KORTSTE TERM: onder de 5 tekens lijkt te veel op elkaar ("ham" en "hak")
  if char_length(v_key) >= 5 then
    select coalesce((select value from public.settings where key = 'fuzzy_min_similarity_pct'), 55) / 100.0
      into v_grens;
    return query
      with kandidaat as (
        select 1 as rang, p.key as sleutel, p.id as soort, null::text as merk, similarity(p.key, v_key) as score
        from public.product_types p
        union all
        select 2, s.key, s.type_id, s.brand_key, similarity(s.key, v_key)
        from public.term_synonyms s where s.type_id is not null
        union all
        select 3, b.brand_key, null::uuid, b.brand_key, similarity(b.brand_key, v_key)
        from (select distinct x.brand_key from public.articles x where x.brand_key <> '') b
      )
      select 4::smallint, k.soort, k.merk
      from kandidaat k
      where k.score >= v_grens
      order by k.score desc, k.rang, k.sleutel
      limit 1;
  end if;
end $$;

-- Het type van een naam, of leeg: voor bonregels en items. Anders dan bij het label gaat het merk hier niet
-- voor: een aankoop "fanta" telt als sinas, zoals purchase_types() dat ook doet. Niet tolerant.
create function public.name_type(p_name text) returns uuid
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_key text := public.match_key(p_name);
  v_stem text;
  v_type uuid;
begin
  if v_key = '' then return null; end if;
  select p.id into v_type from public.product_types p where p.key = v_key;
  if found then return v_type; end if;
  -- Een naam die beoordeeld is zonder type hoort nergens bij, ook niet na stamming
  select s.type_id into v_type from public.term_synonyms s where s.key = v_key;
  if found then return v_type; end if;
  v_stem := public.list_stem(p_name);
  if v_stem = '' then return null; end if;
  select p.id into v_type from public.product_types p where p.stem = v_stem order by p.name limit 1;
  if found then return v_type; end if;
  select s.type_id into v_type from public.term_synonyms s
   where s.stem = v_stem and s.type_id is not null order by s.key limit 1;
  return v_type;
end $$;

-- ---------- Voor welke artikelen staat een term? ----------
-- Zelfde signatuur als voorheen; offers_for_list() en offer_details_for_list() blijven ongewijzigd.
-- Een type: alle artikelen van dat type. Een merk: alle artikelen van dat merk. Allebei: de artikelen van
-- dat merk binnen het type, en als dat er geen zijn het hele type.
drop function public.term_articles(text);
drop function public.term_articles_exact(text);
create function public.term_articles(p_name text)
returns table (supermarket text, article_id text, step smallint)
language plpgsql stable security definer
set search_path to 'public', 'extensions'
as $$
declare
  m record;
begin
  select * into m from public.term_match(p_name);
  if not found then return; end if;

  if m.type_id is not null and m.brand_key is not null then
    return query
      select upper(t.supermarket), t.article_id, m.step
      from public.article_types t
      join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
      where t.type_id = m.type_id and x.brand_key = m.brand_key;
    if found then return; end if;
  end if;
  if m.type_id is not null then
    return query select upper(t.supermarket), t.article_id, m.step
                 from public.article_types t where t.type_id = m.type_id;
  elsif m.brand_key is not null then
    return query select upper(x.supermarket), x.article_id, m.step
                 from public.articles x where x.brand_key = m.brand_key;
  end if;
end $$;

-- Bij een nieuw item of een nieuwe naam: een term die nergens voor staat gaat naar handle_unmatched_term().
-- Een bekende term zonder artikelen (een type waar nog niets van in de aanbieding was) is niet onbekend.
create or replace function public.check_item_term() returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  begin
    if new.offer_id is null and not exists (select 1 from public.term_match(new.name)) then
      perform public.handle_unmatched_term(new.name);
    end if;
  exception when others then
    raise warning 'check_item_term: %', sqlerrm;
  end;
  return new;
end $$;

-- ---------- Vaste producten ----------
-- De types die het huishouden van p_user koopt. product_id is nu het id van het type; de kolomnamen blijven.
create or replace function public.regular_products(p_user uuid)
returns table (product_id uuid, naam text, dagen integer, laatste date)
language sql stable security definer
set search_path to 'public'
as $$
  with grens as (
    select (now() at time zone 'Europe/Amsterdam')::date as vandaag,
           (select value from public.settings where key = 'regular_min_days') as min_dagen,
           (select value from public.settings where key = 'regular_max_age_days') as max_oud
  ),
  gekocht as (
    select ty.id, ty.name, (a.bought_at at time zone 'Europe/Amsterdam')::date as dag
    from public.purchases a
    join public.lists l on l.id = a.list_id and l.counts_for_profile
    join public.list_members m on m.list_id = l.id and m.user_id = p_user
    join public.purchase_types() pt on pt.purchase_id = a.id
    join public.product_types ty on ty.id = pt.type_id and ty.counts_in_profile
  )
  select g.id, g.name, count(distinct g.dag)::integer, max(g.dag)
  from gekocht g cross join grens
  group by g.id, g.name, grens.vandaag, grens.min_dagen, grens.max_oud
  having count(distinct g.dag) >= grens.min_dagen
     and max(g.dag) >= grens.vandaag - grens.max_oud;
$$;

-- ---------- Voor jou ----------
-- Ongewijzigd, behalve via het profiel: een artikel in de aanbieding hoort bij een type dat het huishouden
-- koopt (article_types), zonder goedkeuring vooraf. Favorieten matchen nog op woorden in de titel (fase 7).
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
           case when x.category like '%/%' then public.normalize_search(split_part(x.category, '/', 1)) end as hoofd
    from geldig g
    join public.offer_articles oa on oa.offer_id = g.id
    join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
  ),
  fav as (
    select f.id, f.term, f.brand, f.normalized_brand, f.created_at,
           array_remove(regexp_split_to_array(coalesce(f.normalized_term, ''), '[^[:alnum:]]+'), '') as woorden,
           public.normalize_search(f.category) as hoofd
    from public.favorites f
    where f.user_id = auth.uid()
  ),
  -- artikel is een voorbeeld uit de aanbieding: bij een favoriet met alleen een merk zet de app die titel op de lijst
  via_fav as (
    select a.offer, f.id, f.term, f.brand, f.created_at, min(a.title) as artikel, count(*)::integer as artikelen
    from fav f
    join art a
      on (f.term is null or (cardinality(f.woorden) > 0 and f.woorden <@ a.woorden))
     and (f.normalized_brand is null or a.merk = f.normalized_brand)
     and (f.hoofd is null or a.hoofd is null or a.hoofd = f.hoofd)
    group by a.offer, f.id, f.term, f.brand, f.created_at
  ),
  via_profiel as (
    select distinct a.offer, v.product_id, v.naam, v.dagen
    from art a
    join public.article_types t on t.supermarket = a.supermarket and t.article_id = a.article_id
    join public.regular_products(auth.uid()) v on v.product_id = t.type_id
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

-- ---------- Het aankoopprofiel ----------
-- Ongewijzigd, behalve de basis: een aankoop telt onder zijn type (purchase_types()), met de vlag
-- "telt niet mee" van het type. Een aankoop zonder type telt onder zijn eigen naam.
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
  -- Alle aankopen die meedoen, los van de periode. Een naam zonder type telt als eigen product.
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
    left join public.purchase_types() pt on pt.purchase_id = a.id
    left join public.product_types pr on pr.id = pt.type_id
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

-- ---------- Een bon haalt producten van de lijst ----------
-- zeker = dezelfde naam of hetzelfde type; anders lijkt alleen de naam erop.
create or replace function public.match_receipt_items(p_list uuid, p_date date, p_names text[])
returns table(regel integer, item_id uuid, name text, zeker boolean)
language sql stable security definer
set search_path to 'public', 'extensions'
as $$
  with bon as (
    select n.regel::integer as regel, n.naam, public.name_type(n.naam) as soort
    from unnest(p_names) with ordinality as n(naam, regel)
    where trim(n.naam) <> ''
  ),
  lijst as (
    select i.id, i.name, i.normalized_name, i.created_at, public.name_type(i.name) as soort
    from public.items i
    where i.list_id = p_list
      and public.is_member(p_list)
      and (i.created_at at time zone 'Europe/Amsterdam')::date <= p_date
  ),
  kandidaten as (
    select b.regel, i.id, i.name, i.created_at,
           (i.normalized_name = lower(trim(b.naam)) or (b.soort is not null and b.soort = i.soort)) as zeker,
           greatest(strict_word_similarity(i.normalized_name, lower(trim(b.naam))),
                    strict_word_similarity(lower(trim(b.naam)), i.normalized_name)) as score
    from bon b
    cross join lijst i
  ),
  -- GEVOELIGHEID: dezelfde drempel als bij de aankopen van dezelfde dag (match_receipt_lines)
  per_regel as (
    select distinct on (k.regel) k.* from kandidaten k where k.zeker or k.score >= 0.5
    order by k.regel, k.zeker desc, k.score desc, k.created_at
  )
  -- een item hoort bij hoogstens één bonregel: de best passende
  select distinct on (p.id) p.regel, p.id, p.name, p.zeker from per_regel p order by p.id, p.zeker desc, p.score desc, p.regel;
$$;

-- ---------- Een aanbieding op de lijst zetten ----------
-- Zoals voorheen een nieuw item met de titel van de aanbieding als naam, de aanbieding en (bij precies één
-- artikel) het artikel. Nieuw: het item onthoudt het type als alle artikelen met een type in de aanbieding
-- hetzelfde type hebben, en de titel wordt dan een naam van dat type, zodat de aankoop straks in het profiel
-- onder het type telt. Er wordt niets meer samengevoegd in de catalogus; product_id blijft een aantekening.
create or replace function public.add_offer_item(p_list uuid, p_offer uuid) returns public.items
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  v_naam text;
  v_artikelen integer;
  v_supermarkt text;
  v_artikel text;
  v_types uuid[];
  v_type uuid;
  i public.items;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  if not public.is_member(p_list) then raise exception 'Lijst niet gevonden'; end if;
  if exists (select 1 from public.lists where id = p_list and archived_at is not null) then
    raise exception 'Deze lijst is gearchiveerd';
  end if;

  select btrim(regexp_replace(title, '\s*\*+$', '')) into v_naam from public.offers where id = p_offer;
  if not found or coalesce(v_naam, '') = '' then raise exception 'Aanbieding niet gevonden'; end if;
  v_naam := upper(left(v_naam, 1)) || substr(v_naam, 2);

  select count(*), min(supermarket), min(article_id) into v_artikelen, v_supermarkt, v_artikel
    from public.offer_articles where offer_id = p_offer;
  if v_artikelen <> 1 then
    v_supermarkt := null;
    v_artikel := null;
  end if;

  select array_agg(distinct t.type_id) into v_types
    from public.offer_articles oa
    join public.article_types t on t.supermarket = oa.supermarket and t.article_id = oa.article_id
   where oa.offer_id = p_offer and t.type_id is not null;
  if cardinality(v_types) = 1 then v_type := v_types[1]; end if;

  -- Alleen een titel die nog nergens voor staat wordt een naam van het type
  if v_type is not null and not exists (select 1 from public.term_match(v_naam) m where m.step < 4) then
    perform public.save_term_types_internal(
      jsonb_build_array(jsonb_build_object(
        'term', v_naam, 'type_id', v_type,
        'reason', 'Titel van een aanbieding die vanuit Voor jou op de lijst is gezet')),
      'catalog');
  end if;

  insert into public.items (list_id, name, offer_id, article_supermarket, article_id, type_id, added_by)
  values (p_list, v_naam, p_offer, v_supermarkt, v_artikel, v_type, auth.uid())
  returning * into i;

  -- ensure_product houdt de oude catalogus nog bij; het product van de naam blijft een aantekening
  update public.items
     set product_id = (select product_id from public.product_aliases where normalized_name = i.normalized_name)
   where id = i.id
  returning * into i;
  return i;
end $$;

-- ---------- Types samenvoegen: ook de items ----------
create or replace function public.merge_product_types(p_source text, p_target text) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_bron public.product_types;
  v_doel public.product_types;
  v_artikelen integer;
  v_namen integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan types samenvoegen'; end if;
  select * into v_bron from public.product_types where key = public.match_key(p_source);
  if not found then raise exception 'Het type "%" bestaat niet', p_source; end if;
  select * into v_doel from public.product_types where key = public.match_key(p_target);
  if not found then raise exception 'Het type "%" bestaat niet', p_target; end if;
  if v_bron.id = v_doel.id then raise exception 'Bron en doel zijn hetzelfde type'; end if;

  update public.article_types set type_id = v_doel.id where type_id = v_bron.id;
  get diagnostics v_artikelen = row_count;
  update public.term_synonyms set type_id = v_doel.id where type_id = v_bron.id;
  get diagnostics v_namen = row_count;
  update public.items set type_id = v_doel.id where type_id = v_bron.id;
  delete from public.product_types where id = v_bron.id;

  -- De naam van de bron is nu vrij en wordt een naam van het doel. Een rij die er toevallig al stond
  -- (de naam was eerder een synoniem) wijst vanaf nu ook naar het doel.
  insert into public.term_synonyms as s (key, term, type_id, source, reason, reviewed_at, reviewed_by)
  values (v_bron.key, v_bron.name, v_doel.id, 'manual', 'Was een eigen type, samengevoegd met "' || v_doel.name || '"',
          now(), auth.uid())
  on conflict (key) do update set
    term = excluded.term, target = null, type_id = excluded.type_id, brand_key = null, source = excluded.source,
    reason = excluded.reason, reviewed_at = excluded.reviewed_at, reviewed_by = excluded.reviewed_by;

  return jsonb_build_object('bron', v_bron.name, 'doel', v_doel.name, 'artikelen', v_artikelen, 'namen', v_namen);
end $$;

-- ---------- Rechten ----------
-- De hulpfuncties lezen artikelen en namen van alle huishoudens: niet voor de app-rollen.
-- De functies die met create or replace zijn vervangen houden hun rechten.
revoke all on function public.term_match(text) from public, anon, authenticated;
revoke all on function public.name_type(text) from public, anon, authenticated;
revoke all on function public.term_articles(text) from public, anon, authenticated;
grant execute on function public.term_match(text) to service_role;
grant execute on function public.name_type(text) to service_role;
grant execute on function public.term_articles(text) to service_role;
