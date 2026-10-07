-- Niveau 2 van de koppeling artikel → product (roadmap stap 5, deel 2).
--
-- Niveau 1 kent alleen artikelen die op een eigen bon staan. Een ander merk of formaat van hetzelfde product
-- wordt daardoor gemist ("AH Biologisch oranje pompoen" bij "pompoen"). Hier komt de opslag voor voorstellen
-- die een script buiten de app doet (scripts/artikel-voorstellen.py) en die de beheerder goedkeurt in het
-- scherm Producten. Goedgekeurde koppelingen komen in article_products() erbij; Voor jou, het Bonus-label en
-- de groene balk gebruiken die functie al en veranderen niet.
--
-- Een artikel aan een product koppelen is geen samenvoegen: er verandert niets aan products en product_aliases.
-- Er zit geen naamvergelijking in deze functies; de naam is alleen in het script een manier om kandidaten te vinden.
--
-- Wijzigt bestaande dingen: product_merges krijgt twee kolommen, en article_products(),
-- merge_products_internal() en undo_merge() worden vervangen (zelfde signatuur).

-- ---------- Opslag ----------
-- Eén rij per artikel met een oordeel; een artikel zonder rij is nog niet beoordeeld. De primary key maakt
-- dat een artikel bij hooguit één product hoort.
create table public.article_links (
  supermarket text not null,
  article_id text not null,
  status text not null check (status in ('proposed', 'approved', 'no_product')),
  product_id uuid references public.products(id),
  confidence text check (confidence in ('high', 'medium', 'low')),
  reason text,
  source text not null check (source in ('rule', 'ai')),
  judged_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid,
  primary key (supermarket, article_id),
  foreign key (supermarket, article_id) references public.articles(supermarket, article_id),
  check ((status = 'no_product') = (product_id is null))
);
create index article_links_product_idx on public.article_links (product_id);
comment on column public.article_links.status is
  'proposed: voorstel van het script, wacht op de beheerder; approved: goedgekeurd, telt mee in article_products(); no_product: beoordeeld, hoort bij geen enkel product.';
comment on column public.article_links.source is
  'rule: de subcategorie van het artikel is gelijk aan de productnaam; ai: oordeel van het model.';
comment on column public.article_links.judged_at is
  'Wanneer het script de kandidaat-producten las. Een artikel met no_product wordt opnieuw beoordeeld tegen producten die daarna zijn aangemaakt.';

-- Een afwijzing geldt voor de combinatie van artikel en product: die wordt nooit opnieuw voorgesteld,
-- hetzelfde artikel bij een ander product wel.
create table public.article_link_rejections (
  supermarket text not null,
  article_id text not null,
  product_id uuid not null references public.products(id),
  rejected_at timestamptz not null default now(),
  rejected_by uuid,
  primary key (supermarket, article_id, product_id),
  foreign key (supermarket, article_id) references public.articles(supermarket, article_id)
);
create index article_link_rejections_product_idx on public.article_link_rejections (product_id);

-- Geen policies en geen rechten: alleen de functies hieronder komen bij deze tabellen
alter table public.article_links enable row level security;
alter table public.article_link_rejections enable row level security;
revoke all on table public.article_links, public.article_link_rejections from public, anon, authenticated;

-- Wat er bij het samenvoegen van de bron kwam, zodat losmaken het terugzet (zoals de kolom aliases)
alter table public.product_merges add column article_links jsonb not null default '[]'::jsonb;
alter table public.product_merges add column article_rejections jsonb not null default '[]'::jsonb;

-- ---------- Artikel → product ----------
-- Niveau 1, ongewijzigd: het artikelnummer staat op een bon (de oude inhoud van article_products()).
create function public.receipt_articles()
returns table (supermarket text, article_id text, product_id uuid)
language sql stable security definer
set search_path to 'public'
as $$
  select distinct upper(btrim(r.store)), a.article_id, pa.product_id
  from public.purchases a
  join public.receipts r on r.id = a.receipt_id
  join public.product_aliases pa on pa.normalized_name = a.normalized_name
  where a.article_id is not null
    and btrim(r.store) <> '';
$$;

-- Staat dit artikel op een bon? Dan wint de bon en doet niveau 2 voor dit artikel niet mee.
create function public.article_on_receipt(p_supermarket text, p_article_id text) returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from public.purchases a
    join public.receipts r on r.id = a.receipt_id
    join public.product_aliases pa on pa.normalized_name = a.normalized_name
    where a.article_id = p_article_id
      and upper(btrim(r.store)) = upper(p_supermarket));
$$;

-- Niveau 1 plus de goedgekeurde koppelingen van niveau 2. Staat het artikelnummer op een bon, dan telt alleen de bon.
create or replace function public.article_products()
returns table (supermarket text, article_id text, product_id uuid)
language sql stable security definer
set search_path to 'public'
as $$
  with bon as materialized (
    select b.supermarket, b.article_id, b.product_id from public.receipt_articles() b
  )
  select b.supermarket, b.article_id, b.product_id from bon b
  union
  select upper(l.supermarket), l.article_id, l.product_id
  from public.article_links l
  where l.status = 'approved'
    and not exists (
      select 1 from bon b where b.supermarket = upper(l.supermarket) and b.article_id = l.article_id);
$$;

-- ---------- Voor het script ----------
-- Het werk voor scripts/artikel-voorstellen.py, als JSON:
--   { gelezen_op,
--     producten: [{ id, naam, zoek }],        -- kandidaten: minstens één aankoop of een item op een lijst
--     artikelen: [{ supermarket, article_id, titel, merk, inhoud, categorie, subcategorie_zoek,
--                   afgewezen: [product-id],   -- combinaties die nooit meer voorgesteld mogen worden
--                   nieuwe_producten }] }      -- null: nog nooit beoordeeld, tegen alle kandidaten;
--                                              -- anders alleen tegen deze product-id's (bijgekomen sinds het oordeel)
-- Te beoordelen: het artikel staat niet op een bon, en heeft geen status, of "geen product" terwijl er
-- sindsdien kandidaten zijn bijgekomen. zoek en subcategorie_zoek zijn in de vorm van normalize_search,
-- zodat het script de vaste regel (subcategorie gelijk aan de productnaam) zonder eigen normalisatie toepast.
-- De subcategorie is het deel na de "/" in de categorie, of de hele categorie als er geen "/" in staat.
create function public.article_link_work() returns jsonb
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
  werk as (
    select x.supermarket, x.article_id, x.title, x.brand, x.size, x.category, l.judged_at
    from public.articles x
    left join public.article_links l on l.supermarket = x.supermarket and l.article_id = x.article_id
    where not exists (
            select 1 from bon b where b.supermarket = upper(x.supermarket) and b.article_id = x.article_id)
      and (l.article_id is null
        or (l.status = 'no_product' and exists (select 1 from kandidaat k where k.created_at > l.judged_at)))
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
               'afgewezen', (
                 select coalesce(jsonb_agg(r.product_id), '[]'::jsonb)
                 from public.article_link_rejections r
                 where r.supermarket = w.supermarket and r.article_id = w.article_id),
               'nieuwe_producten', case when w.judged_at is not null then (
                 select coalesce(jsonb_agg(k.id), '[]'::jsonb) from kandidaat k where k.created_at > w.judged_at) end)
             order by w.supermarket, w.category nulls last, w.title, w.article_id), '[]'::jsonb)
      from werk w))
  into v;
  return v;
end $$;

-- Slaat de oordelen van het script op. p_rows is een lijst:
--   [{ supermarket, article_id, product_id (leeg = geen product), confidence, reason, source }]
-- Schrijft alleen "proposed" of "no_product"; goedkeuren kan alleen de beheerder, per voorstel.
-- Overgeslagen en apart geteld: een artikel dat op een bon staat, een artikel dat al een voorstel of een
-- goedgekeurde koppeling heeft, een afgewezen combinatie, en een onbekend artikel of product.
-- p_judged_at is gelezen_op uit article_link_work(): een product dat tijdens het draaien bijkomt telt
-- daardoor de volgende keer als nieuw.
create function public.save_article_proposals(p_rows jsonb, p_judged_at timestamptz default null) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  r jsonb;
  v_supermarkt text;
  v_artikel text;
  v_product uuid;
  v_status text;
  v_moment timestamptz := least(coalesce(p_judged_at, now()), now());
  v_voorstellen integer := 0;
  v_geen integer := 0;
  v_op_bon integer := 0;
  v_bestaand integer := 0;
  v_afgewezen integer := 0;
  v_onbekend integer := 0;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan artikelen koppelen'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen oordelen om op te slaan'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_supermarkt := r->>'supermarket';
    v_artikel := r->>'article_id';
    v_product := nullif(r->>'product_id', '')::uuid;

    if not exists (select 1 from public.articles where supermarket = v_supermarkt and article_id = v_artikel)
       or (v_product is not null and not exists (select 1 from public.products where id = v_product)) then
      v_onbekend := v_onbekend + 1;
      continue;
    end if;
    if public.article_on_receipt(v_supermarkt, v_artikel) then
      v_op_bon := v_op_bon + 1;
      continue;
    end if;
    if v_product is not null and exists (
         select 1 from public.article_link_rejections
         where supermarket = v_supermarkt and article_id = v_artikel and product_id = v_product) then
      v_afgewezen := v_afgewezen + 1;
      continue;
    end if;
    select status into v_status from public.article_links
      where supermarket = v_supermarkt and article_id = v_artikel for update;
    if found and v_status in ('proposed', 'approved') then
      v_bestaand := v_bestaand + 1;
      continue;
    end if;

    insert into public.article_links (supermarket, article_id, status, product_id, confidence, reason, source, judged_at)
    values (v_supermarkt, v_artikel, case when v_product is null then 'no_product' else 'proposed' end, v_product,
            nullif(r->>'confidence', ''), nullif(btrim(r->>'reason'), ''), coalesce(nullif(r->>'source', ''), 'ai'), v_moment)
    on conflict (supermarket, article_id) do update set
      status = excluded.status,
      product_id = excluded.product_id,
      confidence = excluded.confidence,
      reason = excluded.reason,
      source = excluded.source,
      judged_at = excluded.judged_at,
      reviewed_at = null,
      reviewed_by = null;
    if v_product is null then v_geen := v_geen + 1; else v_voorstellen := v_voorstellen + 1; end if;
  end loop;

  return jsonb_build_object(
    'voorstellen', v_voorstellen, 'geen_product', v_geen, 'op_bon', v_op_bon,
    'bestaand', v_bestaand, 'afgewezen', v_afgewezen, 'onbekend', v_onbekend);
end $$;

-- ---------- Voor het scherm Producten ----------
-- De voorstellen die op de beheerder wachten en de goedgekeurde koppelingen, als JSON:
--   { voorstellen: [rij], gekoppeld: [rij] }
--   rij: { supermarkt, artikel_id, titel, merk, inhoud, categorie, product_id, product, zekerheid, reden, bron }
-- Zonder artikelen die intussen op een bon staan: daar telt de bon. Een niet-beheerder krijgt twee lege lijsten.
create function public.article_link_overview() returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with rij as (
    select l.status,
           jsonb_build_object(
             'supermarkt', l.supermarket, 'artikel_id', l.article_id, 'titel', x.title, 'merk', x.brand,
             'inhoud', x.size, 'categorie', x.category, 'product_id', p.id, 'product', p.name,
             'zekerheid', l.confidence, 'reden', l.reason, 'bron', l.source) as inhoud,
           lower(p.name) as product, x.title
    from public.article_links l
    join public.articles x on x.supermarket = l.supermarket and x.article_id = l.article_id
    join public.products p on p.id = l.product_id
    where public.is_admin()
      and l.status in ('proposed', 'approved')
      and not public.article_on_receipt(l.supermarket, l.article_id)
  )
  select jsonb_build_object(
    'voorstellen', coalesce((select jsonb_agg(r.inhoud order by r.product, r.title) from rij r where r.status = 'proposed'), '[]'::jsonb),
    'gekoppeld', coalesce((select jsonb_agg(r.inhoud order by r.product, r.title) from rij r where r.status = 'approved'), '[]'::jsonb));
$$;

-- Keurt voorstellen goed: één, of een hele groep bij "alles goedkeuren". p_rows is een lijst
--   [{ supermarket, article_id, product_id }]
-- Het product gaat mee zodat alleen wordt goedgekeurd wat de beheerder zag: is het voorstel intussen
-- veranderd, dan blijft het staan. Geeft het aantal goedgekeurde voorstellen terug.
create function public.approve_article_links(p_rows jsonb) returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare v_aantal integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan voorstellen goedkeuren'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen voorstellen om goed te keuren'; end if;
  update public.article_links l
     set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    from jsonb_array_elements(p_rows) r
   where l.supermarket = r->>'supermarket'
     and l.article_id = r->>'article_id'
     and l.product_id = nullif(r->>'product_id', '')::uuid
     and l.status = 'proposed';
  get diagnostics v_aantal = row_count;
  return v_aantal;
end $$;

-- Wijst een voorstel af, of maakt een goedgekeurde koppeling los; dat telt als afwijzing van die combinatie.
-- De rij verdwijnt, zodat het artikel weer "zonder status" is en het script het later tegen andere
-- producten mag beoordelen.
create function public.reject_article_link(p_supermarket text, p_article_id text) returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare v_product uuid;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan voorstellen afwijzen'; end if;
  delete from public.article_links
   where supermarket = p_supermarket and article_id = p_article_id and status in ('proposed', 'approved')
  returning product_id into v_product;
  if not found then raise exception 'Koppeling niet gevonden'; end if;
  insert into public.article_link_rejections (supermarket, article_id, product_id, rejected_by)
  values (p_supermarket, p_article_id, v_product, auth.uid())
  on conflict do nothing;
end $$;

-- ---------- Samenvoegen en losmaken ----------
-- Koppelingen, voorstellen en afwijzingen van de bron verhuizen mee naar het doel. In product_merges staat
-- wat er verhuisd is. Een afwijzing die het doel zelf al had blijft van het doel ("moved": false).
-- Een voorstel van de bron bij een artikel dat voor het doel al was afgewezen verhuist gewoon mee:
-- het was voor de bron niet afgewezen en moet na losmaken terug kunnen.
create or replace function public.merge_products_internal(p_source uuid, p_target uuid, p_by uuid) returns uuid
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  v_naam text;
  v_telt boolean;
  v_namen text[];
  v_koppelingen jsonb;
  v_afwijzingen jsonb;
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

  with verhuisd as (
    update public.article_links set product_id = p_target where product_id = p_source
    returning supermarket, article_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('supermarket', supermarket, 'article_id', article_id)), '[]'::jsonb)
    into v_koppelingen from verhuisd;

  select coalesce(jsonb_agg(jsonb_build_object(
           'supermarket', r.supermarket, 'article_id', r.article_id,
           'rejected_at', r.rejected_at, 'rejected_by', r.rejected_by,
           'moved', not exists (
             select 1 from public.article_link_rejections t
             where t.supermarket = r.supermarket and t.article_id = r.article_id and t.product_id = p_target))), '[]'::jsonb)
    into v_afwijzingen
    from public.article_link_rejections r where r.product_id = p_source;
  delete from public.article_link_rejections r
   where r.product_id = p_source
     and exists (
       select 1 from public.article_link_rejections t
       where t.supermarket = r.supermarket and t.article_id = r.article_id and t.product_id = p_target);
  update public.article_link_rejections set product_id = p_target where product_id = p_source;

  insert into public.product_merges (target_id, source_id, source_name, aliases, merged_by, source_counts_in_profile,
                                     article_links, article_rejections)
    values (p_target, p_source, v_naam, v_namen, p_by, v_telt, v_koppelingen, v_afwijzingen) returning id into v_id;
  update public.product_aliases set product_id = p_target where product_id = p_source;
  delete from public.products where id = p_source;
  return v_id;
end $$;

-- Losmaken zet terug wat van de bron kwam: de koppelingen en voorstellen die nog bij het doel staan, en de
-- afwijzingen. Wat na het samenvoegen op het doel is goedgekeurd staat niet in product_merges en blijft bij het doel.
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

  update public.article_links l set product_id = m.source_id
    from jsonb_array_elements(m.article_links) k
   where l.supermarket = k->>'supermarket' and l.article_id = k->>'article_id' and l.product_id = m.target_id;

  insert into public.article_link_rejections (supermarket, article_id, product_id, rejected_at, rejected_by)
  select k->>'supermarket', k->>'article_id', m.source_id,
         coalesce((k->>'rejected_at')::timestamptz, now()), nullif(k->>'rejected_by', '')::uuid
  from jsonb_array_elements(m.article_rejections) k
  on conflict do nothing;
  delete from public.article_link_rejections r
   using jsonb_array_elements(m.article_rejections) k
   where (k->>'moved')::boolean
     and r.supermarket = k->>'supermarket' and r.article_id = k->>'article_id' and r.product_id = m.target_id;

  update public.product_merges set undone_at = now(), undone_by = auth.uid() where id = p_merge;
end $$;

-- ---------- Rechten ----------
-- De twee hulpfuncties lezen aankopen van alle huishoudens en zijn alleen voor de functies hierboven
revoke all on function public.receipt_articles() from public, anon, authenticated;
revoke all on function public.article_on_receipt(text, text) from public, anon, authenticated;
grant execute on function public.receipt_articles() to service_role;
grant execute on function public.article_on_receipt(text, text) to service_role;

revoke all on function public.article_link_work() from public, anon;
revoke all on function public.save_article_proposals(jsonb, timestamptz) from public, anon;
revoke all on function public.article_link_overview() from public, anon;
revoke all on function public.approve_article_links(jsonb) from public, anon;
revoke all on function public.reject_article_link(text, text) from public, anon;
grant execute on function public.article_link_work() to authenticated, service_role;
grant execute on function public.save_article_proposals(jsonb, timestamptz) to authenticated, service_role;
grant execute on function public.article_link_overview() to authenticated, service_role;
grant execute on function public.approve_article_links(jsonb) to authenticated, service_role;
grant execute on function public.reject_article_link(text, text) to authenticated, service_role;
