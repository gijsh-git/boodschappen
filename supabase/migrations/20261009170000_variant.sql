-- Volgorde binnen het type: het kenmerk variant (roadmap stap 7, deel 1).
--
-- Bij "tomatensoep" staan alle soepaanbiedingen door elkaar, omdat het type (soep) het niveau van matchen is.
-- Dat blijft zo. Nieuw is een plat kenmerk naast het type: de variant, één woord zoals "tomaat" of "kip".
-- Artikelen en termen krijgen het van de AI bij dezelfde aanroep die het type bepaalt. De variant bepaalt
-- alleen de volgorde in het bonuspaneel van de lijst: eerst de aanbiedingen met een artikel met dezelfde
-- variant als de term, en binnen een aanbieding die artikelen bovenaan. Er valt nooit iets door weg.
--
-- Vergelijken gaat op de Nederlandse stam (list_stem), zodat "tomaat" en "tomaten" gelijk zijn. Er is geen
-- vaste lijst en geen beheer.

-- ---------- Opslag ----------
-- variant_judged_at zegt dat de AI ernaar heeft gekeken, ook als er geen variant te noemen is. Een rij met een
-- type en zonder dat tijdstip wacht nog op een variant (ook een type dat de beheerder heeft gezet).
alter table public.article_types
  add column variant text,
  add column variant_stem text generated always as (nullif(public.list_stem(variant), '')) stored,
  add column variant_judged_at timestamptz;
comment on column public.article_types.variant is
  'De smaak of soort binnen het type, één woord ("tomaat"). Alleen voor de volgorde in het bonuspaneel; leeg als er geen variant te noemen is.';

alter table public.term_synonyms
  add column variant text,
  add column variant_stem text generated always as (nullif(public.list_stem(variant), '')) stored,
  add column variant_judged_at timestamptz;
comment on column public.term_synonyms.variant is
  'De smaak of soort die de term binnen het type noemt, één woord ("tomaat" bij "tomatensoep"). Alleen voor de volgorde in het bonuspaneel.';

-- ---------- De variant van een term ----------
-- De stam van de variant waar een getypte term voor staat, of null. Volgt de lagen van term_match(): een
-- typenaam of een los merk noemt geen variant, een naam van een type heeft de variant van die naam, ook na
-- stamming, en bij een merk met een soort telt de soort ("unox tomatensoep" is tomaat). De tolerante laag
-- geeft geen variant.
create function public.term_variant(p_name text) returns text
language plpgsql stable security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_key text := public.match_key(p_name);
  v_stem text;
  v_variant text;
  v_woorden text[];
  v_links text;
  v_rechts text;
begin
  if v_key = '' then return null; end if;
  if exists (select 1 from public.product_types p where p.key = v_key) then return null; end if;
  if exists (select 1 from public.articles x where x.brand_key = v_key) then return null; end if;

  select s.variant_stem into v_variant from public.term_synonyms s where s.key = v_key;
  if found then return v_variant; end if;

  v_stem := public.list_stem(p_name);
  if v_stem <> '' then
    if exists (select 1 from public.product_types p where p.stem = v_stem) then return null; end if;
    select s.variant_stem into v_variant
      from public.term_synonyms s where s.stem = v_stem and s.type_id is not null
     order by s.key limit 1;
    if found then return v_variant; end if;
  end if;

  v_woorden := regexp_split_to_array(public.normalize_search(p_name), '\s+');
  if cardinality(v_woorden) between 2 and 6 then
    for i in 1 .. cardinality(v_woorden) - 1 loop
      v_links := array_to_string(v_woorden[1:i], ' ');
      v_rechts := array_to_string(v_woorden[i + 1:cardinality(v_woorden)], ' ');
      if exists (select 1 from public.articles x where x.brand_key = public.match_key(v_links) and x.brand_key <> '')
         and public.name_type(v_rechts) is not null then
        return public.term_variant(v_rechts);
      end if;
      if exists (select 1 from public.articles x where x.brand_key = public.match_key(v_rechts) and x.brand_key <> '')
         and public.name_type(v_links) is not null then
        return public.term_variant(v_links);
      end if;
    end loop;
  end if;
  return null;
end $$;

-- ---------- Artikelen: het werk voor de Edge Function ----------
-- Als voorheen, en nu ook de artikelen die wel een type hebben maar nog geen variant.
create or replace function public.article_type_work(p_limit integer default 120) returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with te_doen as materialized (
    select x.supermarket, x.article_id, x.title, x.brand, x.size, x.category
    from public.articles x
    left join public.article_types t on t.supermarket = x.supermarket and t.article_id = x.article_id
    where t.article_id is null
       or (t.type_id is null and t.source = 'ai' and t.reviewed_at is null
           and exists (select 1 from public.product_types p where p.created_at > t.judged_at))
       or (t.type_id is not null and t.variant_judged_at is null)
  )
  select jsonb_build_object(
    'gelezen_op', now(),
    'nog', (select count(*) from te_doen),
    'types', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'naam', p.name, 'hoofdgroep', p.main_group,
               'valt_eronder', p.scope, 'valt_er_niet_onder', p.excludes)
             order by p.main_group, p.name, p.id), '[]'::jsonb)
      from public.product_types p),
    'artikelen', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'supermarket', o.supermarket, 'article_id', o.article_id, 'titel', o.title, 'merk', o.brand,
               'inhoud', o.size, 'categorie', o.category)
             order by o.category nulls last, o.title, o.article_id), '[]'::jsonb)
      from (
        select * from te_doen o2
        order by o2.category nulls last, o2.title, o2.article_id
        limit greatest(1, least(coalesce(p_limit, 120), 500))
      ) o));
$$;

-- ---------- Artikelen: oordelen opslaan ----------
-- p_rows: [{ supermarket, article_id, type_id, variant, suggested_type, confidence, reason }].
-- Een artikel dat al een type heeft houdt dat type, wat de AI er nu ook van vindt: daar wordt alleen de
-- variant ingevuld (één keer). De rest gaat als voorheen: alleen een ai-rij zonder type die nog niet is
-- nagekeken wordt vervangen. Bij "geen type" is er geen variant.
create or replace function public.save_article_types(p_rows jsonb, p_judged_at timestamptz default null) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_met integer;
  v_zonder integer;
  v_variant integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen oordelen om op te slaan'; end if;

  update public.article_types t
     set variant = nullif(left(lower(btrim(r.variant)), 40), ''), variant_judged_at = now()
    from (select distinct on (btrim(e->>'supermarket'), btrim(e->>'article_id'))
                 btrim(e->>'supermarket') as sm, btrim(e->>'article_id') as aid, e->>'variant' as variant
          from jsonb_array_elements(p_rows) e
          where e->>'confidence' in ('high', 'medium', 'low')
          order by 1, 2) r
   where t.supermarket = r.sm and t.article_id = r.aid
     and t.type_id is not null and t.variant_judged_at is null;
  get diagnostics v_variant = row_count;

  with rij as (
    select btrim(r->>'supermarket') as sm, btrim(r->>'article_id') as aid,
           nullif(r->>'type_id', '')::uuid as tid,
           nullif(left(lower(btrim(r->>'variant')), 40), '') as variant,
           nullif(btrim(r->>'suggested_type'), '') as voorstel,
           r->>'confidence' as zekerheid, nullif(btrim(r->>'reason'), '') as reden
    from jsonb_array_elements(p_rows) r
  ),
  geldig as (
    select distinct on (rij.sm, rij.aid) rij.*
    from rij
    join public.articles x on x.supermarket = rij.sm and x.article_id = rij.aid
    where rij.zekerheid in ('high', 'medium', 'low')
      and (rij.tid is null or exists (select 1 from public.product_types p where p.id = rij.tid))
    order by rij.sm, rij.aid
  ),
  op as (
    insert into public.article_types as t
      (supermarket, article_id, type_id, suggested_type, confidence, reason, source, judged_at, variant, variant_judged_at)
    select g.sm, g.aid, g.tid, case when g.tid is null then left(g.voorstel, 80) end,
           g.zekerheid, left(g.reden, 300), 'ai', coalesce(p_judged_at, now()),
           case when g.tid is not null then g.variant end, case when g.tid is not null then now() end
    from geldig g
    on conflict (supermarket, article_id) do update set
      type_id = excluded.type_id,
      suggested_type = excluded.suggested_type,
      confidence = excluded.confidence,
      reason = excluded.reason,
      judged_at = excluded.judged_at,
      variant = excluded.variant,
      variant_judged_at = excluded.variant_judged_at
    where t.source = 'ai' and t.reviewed_at is null and t.type_id is null
    returning t.type_id
  )
  select count(*) filter (where op.type_id is not null), count(*) filter (where op.type_id is null)
    into v_met, v_zonder
  from op;
  return jsonb_build_object(
    'met_type', v_met, 'geen_type', v_zonder, 'variant', v_variant,
    'overgeslagen', jsonb_array_length(p_rows) - v_met - v_zonder - v_variant);
end $$;

-- ---------- Termen: het werk voor de Edge Function ----------
-- Als voorheen. Met p_variants ook de namen die al een type hebben maar nog geen variant (aanvullen wat er al
-- stond, en namen uit de catalogus of van de beheerder): die vullen de portie aan en zijn gemerkt met
-- alleen_variant, want hun type blijft wat het is. Alleen het wekelijkse script vraagt daarom; het seintje
-- bij een onbekende term niet, zodat het label even snel komt als voorheen.
drop function public.term_work(integer);
create function public.term_work(p_limit integer default 40, p_variants boolean default false) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_max integer := greatest(1, least(coalesce(p_limit, 40), 200));
  v_termen jsonb;
  v_extra jsonb;
  v_nog integer := 0;
begin
  update public.unmatched_terms u set judged_at = now()
   where u.judged_at is null
     and (exists (select 1 from public.term_synonyms s where s.key = u.key)
          or exists (select 1 from public.product_types p where p.key = u.key));

  with kies as (
    select u.key from public.unmatched_terms u
    where u.judged_at is null
      -- OPNIEUW OPPAKKEN: na zoveel tijd geldt een eerdere aanroep als mislukt
      and (u.claimed_at is null or u.claimed_at < now() - interval '3 minutes')
    order by u.last_seen desc
    limit v_max
    for update skip locked
  ),
  pak as (
    update public.unmatched_terms u set claimed_at = now()
    from kies where u.key = kies.key
    returning u.key, u.term
  )
  select coalesce(jsonb_agg(jsonb_build_object('sleutel', pak.key, 'term', pak.term) order by pak.term), '[]'::jsonb)
    into v_termen from pak;

  if coalesce(p_variants, false) then
    select count(*) into v_nog
      from public.term_synonyms s where s.type_id is not null and s.variant_judged_at is null;
    if jsonb_array_length(v_termen) < v_max then
      select coalesce(jsonb_agg(jsonb_build_object('sleutel', k.key, 'term', k.term, 'alleen_variant', true)
                                order by k.term), '[]'::jsonb)
        into v_extra
      from (select s.key, s.term from public.term_synonyms s
            where s.type_id is not null and s.variant_judged_at is null
            order by s.key
            limit v_max - jsonb_array_length(v_termen)) k;
      v_termen := v_termen || v_extra;
    end if;
  end if;

  return jsonb_build_object(
    'gelezen_op', now(),
    'termen', v_termen,
    'nog_varianten', v_nog,
    'types', case when jsonb_array_length(v_termen) = 0 then '[]'::jsonb else (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'naam', p.name, 'hoofdgroep', p.main_group,
               'valt_eronder', p.scope, 'valt_er_niet_onder', p.excludes)
             order by p.main_group, p.name, p.id), '[]'::jsonb)
      from public.product_types p) end);
end $$;

-- ---------- Termen: oordelen opslaan ----------
-- p_rows als voorheen, met per rij ook variant. p_variants: [{ term, variant }] voor de namen die al een type
-- hadden (alleen_variant): daar verandert alleen de variant. Een variant wordt één keer ingevuld.
drop function public.save_term_judgments(jsonb);
create function public.save_term_judgments(p_rows jsonb, p_variants jsonb default null) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_rijen jsonb;
  v_varianten jsonb := case when jsonb_typeof(p_variants) = 'array' then p_variants else '[]'::jsonb end;
  v_uit jsonb;
  v_items integer;
  v_variant integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen oordelen om op te slaan'; end if;
  select coalesce(jsonb_agg(
           case when exists (select 1 from public.articles x
                             where x.brand_key = public.match_key(r->>'brand') and x.brand_key <> '')
                then r else r - 'brand' end), '[]'::jsonb)
    into v_rijen
  from jsonb_array_elements(p_rows) r;

  v_uit := public.save_term_types_internal(v_rijen, 'ai');

  update public.unmatched_terms u set judged_at = now()
   where u.key in (select public.match_key(r->>'term') from jsonb_array_elements(v_rijen) r);

  update public.term_synonyms s
     set variant = nullif(left(lower(btrim(r.variant)), 40), ''), variant_judged_at = now()
    from (select distinct on (public.match_key(e->>'term'))
                 public.match_key(e->>'term') as sleutel, e->>'variant' as variant
          from jsonb_array_elements(v_rijen || v_varianten) e
          order by 1) r
   where s.key = r.sleutel and s.type_id is not null and s.variant_judged_at is null;
  get diagnostics v_variant = row_count;

  -- Het type zoals het nu geldt: een rij van de beheerder of uit de catalogus gaat voor het oordeel van de AI
  update public.items i set type_id = s.type_id
    from public.term_synonyms s
   where s.key in (select public.match_key(r->>'term') from jsonb_array_elements(v_rijen) r)
     and s.type_id is not null
     and public.match_key(i.name) = s.key
     and i.offer_id is null
     and i.type_id is distinct from s.type_id;
  get diagnostics v_items = row_count;

  return v_uit || jsonb_build_object('items', v_items, 'varianten', v_variant);
end $$;

-- ---------- Het bonuspaneel van de lijst ----------
-- Dezelfde twee routes als voorheen. Nieuw: de aanbiedingen staan per item bij elkaar (in de volgorde van de
-- lijst), en per item eerst de aanbiedingen met een artikel met dezelfde variant als de term. artikelen
-- begint met die artikelen; artikelen_zelfde zegt hoeveel het er zijn (ook boven de zes die bij naam worden
-- genoemd). Een item zonder variant, of dat via items.offer_id op de lijst staat, heeft er nul.
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
    select i.id, i.name, i.offer_id, i.created_at, public.term_variant(i.name) as variant
    from public.items i
    where i.list_id = p_list and public.is_member(p_list)
  ),
  treffer as (
    select d.id as item, g.id as offer, oa.supermarket, oa.article_id
    from ding d
    cross join lateral public.term_articles(d.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
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
           'artikelen', to_jsonb(p.artikelen), 'artikelen_totaal', p.totaal, 'artikelen_zelfde', p.zelfde)
         order by d.created_at, d.id, (p.zelfde > 0) desc, g.title, g.id), '[]'::jsonb)
  from per p
  join geldig g on g.id = p.offer
  join ding d on d.id = p.item
  where public.is_member(p_list);
$$;

-- ---------- Rechten ----------
revoke all on function public.term_variant(text) from public, anon, authenticated;
revoke all on function public.term_work(integer, boolean) from public, anon, authenticated;
revoke all on function public.save_term_judgments(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.term_variant(text) to service_role;
grant execute on function public.term_work(integer, boolean) to service_role;
grant execute on function public.save_term_judgments(jsonb, jsonb) to service_role;
