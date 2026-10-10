-- Aanbiedingen van meer dan één supermarkt opslaan (roadmap stap 9, deel 1). PLUS komt in de database, nog
-- niet in de app.
--
-- 1. articles krijgt het EAN en de inhoud als hoeveelheid en eenheid; save_offers neemt ze aan.
-- 2. known_article_ids: welke artikelen van een winkel hebben al een EAN. Het ophaalscript van PLUS vraagt
--    dat via de Edge Function aanbiedingen-opslaan en haalt de productpagina alleen voor de rest op.
-- 3. shown_supermarkets: de winkels waarvan de app aanbiedingen toont. Voorlopig alleen AH, voor iedereen;
--    deel 2 ("Mijn winkels") vervangt dit door de keuze per persoon. De drie functies die aanbiedingen bij
--    een naam of een profiel zoeken kijken ernaar: offers_for_list, offer_details_for_list en
--    offers_for_me_all.
-- 4. De terugval bij favorieten in offers_for_me_all gebruikt de hoofdgroep van het type van het artikel,
--    niet meer het deel vóór de "/" in de categorie van de winkel (dat was de vorm van AH).

-- ---------- 1. Artikelen: EAN, hoeveelheid en eenheid ----------
alter table public.articles
  add column ean text,
  add column quantity numeric(12,3),
  add column unit text,
  add constraint articles_unit_check check (unit is null or unit in ('g', 'ml', 'st')),
  add constraint articles_quantity_check check ((quantity is null) = (unit is null) and (quantity is null or quantity > 0));
create index articles_ean_idx on public.articles (ean) where ean is not null;
comment on column public.articles.article_id is
  'Het artikelnummer in het systeem van de supermarkt, hetzelfde als purchases.article_id. Voor AH het hqId (het nummer op de kassabon), niet het webshop-ID. Voor PLUS het artikelnummer van de webshop: een bon van PLUS heeft geen artikelnummers.';
comment on column public.articles.ean is
  'De streepjescode van het artikel, als de bron die geeft (PLUS: van de productpagina; AH: niet). Hetzelfde EAN bij twee supermarkten is hetzelfde artikel.';
comment on column public.articles.quantity is
  'De inhoud als getal, in de eenheid van unit: "6 x 330 ml" is 1980. Leeg als de inhoud geen gewicht, volume of aantal is ("20 wasbeurten"). Voor de prijs per eenheid.';
comment on column public.articles.unit is
  'g, ml of st. Kilo en liter zijn omgerekend naar gram en milliliter.';
comment on column public.articles.category is
  'Categorie van de supermarkt, alleen invoer voor de AI die het type kiest. Een pad met "/" ("Zuivel, eieren/Kwark") of alleen het diepste niveau als de bron niet meer gaf. De indeling van de app zelf is product_types.main_group.';

-- p_offers als voorheen, met per artikel ook ean, quantity en unit. Wat de bron deze keer niet meegeeft blijft staan.
create or replace function public.save_offers(p_supermarket text, p_offers jsonb) returns jsonb
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  -- BEWAARTERMIJN: zo lang blijft een aanbieding na de laatste geldige dag nog staan
  c_bewaren constant integer := 28;
  v_supermarkt text := nullif(trim(p_supermarket), '');
  v_vandaag date := (now() at time zone 'Europe/Amsterdam')::date;
  a jsonb;
  v_offer uuid;
  v_lijst jsonb;
  v_aanbiedingen integer := 0;
  v_koppelingen integer := 0;
  v_rijen integer;
  v_artikelen_voor integer;
  v_artikelen_na integer;
  v_opgeruimd integer;
begin
  if v_supermarkt is null then
    raise exception 'Geen supermarkt opgegeven';
  end if;
  if p_offers is null or jsonb_typeof(p_offers) <> 'array' or jsonb_array_length(p_offers) = 0 then
    raise exception 'Geen aanbiedingen om op te slaan';
  end if;

  select count(*) into v_artikelen_voor from public.articles where supermarket = v_supermarkt;

  -- Artikelen: nieuwe erbij, bekende bijwerken. Een categorie met hoofdcategorie ("Zuivel, eieren/Kwark")
  -- wordt niet vervangen door alleen de subcategorie van een losse aanbieding.
  insert into public.articles (supermarket, article_id, webshop_id, title, brand, size, category, ean, quantity, unit)
  select distinct on (trim(x->>'article_id'))
         v_supermarkt, trim(x->>'article_id'), nullif(trim(x->>'webshop_id'), ''), trim(x->>'title'),
         nullif(trim(x->>'brand'), ''), nullif(trim(x->>'size'), ''), nullif(trim(x->>'category'), ''),
         nullif(trim(x->>'ean'), ''),
         case when x->>'unit' in ('g', 'ml', 'st') then nullif(x->>'quantity', '')::numeric end,
         case when x->>'unit' in ('g', 'ml', 'st') and nullif(x->>'quantity', '') is not null then x->>'unit' end
  from jsonb_array_elements(p_offers) o
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(o->'articles') = 'array' then o->'articles' else '[]'::jsonb end) x
  where nullif(trim(x->>'article_id'), '') is not null
    and nullif(trim(x->>'title'), '') is not null
  order by trim(x->>'article_id'), (x->>'category' like '%/%') desc nulls last
  on conflict (supermarket, article_id) do update set
    webshop_id = coalesce(excluded.webshop_id, articles.webshop_id),
    title = excluded.title,
    brand = coalesce(excluded.brand, articles.brand),
    size = coalesce(excluded.size, articles.size),
    category = case
      when excluded.category is null then articles.category
      when articles.category like '%/%' and excluded.category not like '%/%' then articles.category
      else excluded.category end,
    ean = coalesce(excluded.ean, articles.ean),
    quantity = coalesce(excluded.quantity, articles.quantity),
    unit = case when excluded.quantity is not null then excluded.unit else articles.unit end,
    last_seen_at = now();

  select count(*) into v_artikelen_na from public.articles where supermarket = v_supermarkt;

  for a in select * from jsonb_array_elements(p_offers) loop
    v_lijst := case when jsonb_typeof(a->'labels') = 'array' then a->'labels' else '[]'::jsonb end;
    insert into public.offers (supermarket, offer_id, title, discount_text, discount_type, labels, category,
                               valid_from, valid_to, is_group, store_only)
    values (v_supermarkt, trim(a->>'offer_id'), trim(a->>'title'), nullif(trim(a->>'discount_text'), ''),
            nullif(v_lijst->0->>'code', ''), v_lijst, nullif(trim(a->>'category'), ''),
            (a->>'valid_from')::date, (a->>'valid_to')::date,
            coalesce((a->>'is_group')::boolean, false), coalesce((a->>'store_only')::boolean, false))
    on conflict (supermarket, offer_id, valid_from) do update set
      title = excluded.title,
      discount_text = excluded.discount_text,
      discount_type = excluded.discount_type,
      labels = excluded.labels,
      category = excluded.category,
      valid_to = excluded.valid_to,
      is_group = excluded.is_group,
      store_only = excluded.store_only,
      fetched_at = now()
    returning id into v_offer;
    v_aanbiedingen := v_aanbiedingen + 1;

    if coalesce((a->>'complete')::boolean, true) then
      delete from public.offer_articles where offer_id = v_offer;
      insert into public.offer_articles (offer_id, supermarket, article_id, price, bonus_price)
      select distinct on (trim(x->>'article_id'))
             v_offer, v_supermarkt, trim(x->>'article_id'),
             nullif(x->>'price', '')::numeric, nullif(x->>'bonus_price', '')::numeric
      from jsonb_array_elements(
        case when jsonb_typeof(a->'articles') = 'array' then a->'articles' else '[]'::jsonb end) x
      where nullif(trim(x->>'article_id'), '') is not null
        and nullif(trim(x->>'title'), '') is not null
      order by trim(x->>'article_id');
      get diagnostics v_rijen = row_count;
      v_koppelingen := v_koppelingen + v_rijen;
    end if;
  end loop;

  -- Oude aanbiedingen opruimen, van alle supermarkten. De artikelen blijven staan.
  delete from public.offers where valid_to < v_vandaag - c_bewaren;
  get diagnostics v_opgeruimd = row_count;

  return jsonb_build_object(
    'aanbiedingen', v_aanbiedingen,
    'artikelen_in_aanbiedingen', v_koppelingen,
    'nieuwe_artikelen', v_artikelen_na - v_artikelen_voor,
    'artikelen_totaal', v_artikelen_na,
    'opgeruimd', v_opgeruimd);
end $$;

-- ---------- 2. Welke artikelen zijn al bekend ----------
create function public.known_article_ids(p_supermarket text) returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(x.article_id order by x.article_id), '[]'::jsonb)
  from public.articles x
  where x.supermarket = btrim(p_supermarket) and x.ean is not null;
$$;
comment on function public.known_article_ids(text) is
  'De artikelnummers van een supermarkt die al een EAN hebben. Voor het ophaalscript, dat de productpagina alleen voor de andere artikelen opvraagt.';
revoke all on function public.known_article_ids(text) from public, anon, authenticated;
grant execute on function public.known_article_ids(text) to service_role;

-- ---------- 3. De winkels die de app toont ----------
-- In hoofdletters. Een winkel die hier niet staat kan in de database staan (artikelen, types, Koppelingen)
-- zonder dat iemand er een label of een regel in Voor jou van ziet.
create function public.shown_supermarkets() returns text[]
language sql stable
set search_path to 'public'
as $$
  select array['AH'];
$$;
comment on function public.shown_supermarkets() is
  'De supermarkten waarvan de app aanbiedingen toont, in hoofdletters. Voorlopig alleen AH; wordt de keuze per persoon ("Mijn winkels", roadmap stap 9 deel 2).';
revoke all on function public.shown_supermarkets() from public, anon, authenticated;
grant execute on function public.shown_supermarkets() to service_role;

-- Bonus-label op de lijst: de route via de naam kijkt alleen naar de getoonde winkels. Een aanbieding die
-- zelf op de lijst staat (items.offer_id) blijft, van welke winkel ook.
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
      and upper(g.supermarket) = any (public.shown_supermarkets())
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
      and upper(g.supermarket) = any (public.shown_supermarkets())
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

-- ---------- 4. Voor jou ----------
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
      and upper(o.supermarket) = any (public.shown_supermarkets())
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
