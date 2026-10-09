-- Bestaande namen en artikelen aan een producttype koppelen (overstap naar producttypes, fase 3).
--
-- term_synonyms wordt de ene tabel "naam → type": de namen uit de catalogus (product_aliases) komen erin met
-- bron catalog, wat de AI koppelt met bron ai, wat de beheerder zet met bron manual. De oude kolom target
-- (naam → andere naam) blijft staan tot term_articles() in fase 4 op types rekent; de tabel was nog leeg.
-- scripts/naar-producttypes.py doet de overzetting zelf, via de functies hieronder.
--
-- Niets wat de app gebruikt leest dit al: products, product_aliases, article_products() en term_articles()
-- werken ongewijzigd door. purchase_types() is er alvast, om het profiel oud en nieuw naast elkaar te leggen
-- (docs/producttypes-controle.sql).

-- ---------- Naam → type ----------
alter table public.term_synonyms
  alter column target drop not null,
  add column type_id uuid references public.product_types(id),
  add column brand_key text,
  add column confidence text check (confidence in ('high', 'medium', 'low')),
  add column reason text,
  add column reviewed_at timestamptz,
  add column reviewed_by uuid;
alter table public.term_synonyms drop constraint term_synonyms_source_check;
alter table public.term_synonyms
  add constraint term_synonyms_source_check check (source in ('manual', 'ai', 'catalog'));
create index term_synonyms_type_idx on public.term_synonyms (type_id);
comment on column public.term_synonyms.type_id is
  'Het type waar de term voor staat. Leeg (en geen target): beoordeeld, er is geen passend type.';
comment on column public.term_synonyms.brand_key is
  'Optioneel: de term noemt ook een merk ("sensodyne tandpasta"), in sleutelvorm zoals articles.brand_key.';
comment on column public.term_synonyms.source is
  'catalog: uit de oude catalogus of een lijstnaam; ai: oordeel van het model; manual: gezet door de beheerder. manual gaat voor catalog, catalog voor ai.';

-- ---------- Het werk voor scripts/naar-producttypes.py ----------
-- { gelezen_op,
--   types:      [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder }],
--   producten:  [{ id, naam, namen: [{ naam, aankopen, items }] }],     -- de catalogus met alle namen
--   lijstnamen: [{ sleutel, naam, artikelen, zonder_type, onbeoordeeld, types: [{ type_id, artikelen }] }],
--   artikelen:  [{ supermarket, article_id, titel, categorie, bron, product_id,
--                  type_id, zekerheid, type_bron }],
--   synoniemen: [{ sleutel, bron }] }                                    -- wat er al in term_synonyms staat
-- lijstnamen: per lijstnaam (article_names, in sleutelvorm) hoe de artikelen met die naam over de types
--   verdeeld zijn; zonder_type heeft het oordeel "geen type", onbeoordeeld heeft nog geen oordeel.
-- artikelen: de artikelen die in de oude catalogus bij een product horen, met bron receipt (het artikelnummer
--   staat op een bon) of catalog (goedgekeurde koppeling), en daarnaast het huidige oordeel in article_types.
--   Een artikel op een bon kan onder twee namen gekocht zijn en staat er dan twee keer in.
create function public.type_migration_work() returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan de catalogus overzetten'; end if;
  with bon as materialized (
    select distinct b.supermarket, b.article_id from public.receipt_articles() b
  ),
  koopnaam as (
    select c.normalized_name, count(*)::integer as n from public.purchases c group by c.normalized_name
  ),
  itemnaam as (
    select i.normalized_name, count(*)::integer as n from public.items i group by i.normalized_name
  ),
  lijstnaam as (
    select n.key, min(n.name) as naam, n.supermarket, n.article_id
    from public.article_names n
    where n.key <> ''
    group by n.key, n.supermarket, n.article_id
  )
  select jsonb_build_object(
    'gelezen_op', now(),
    'types', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'naam', p.name, 'hoofdgroep', p.main_group,
               'valt_eronder', p.scope, 'valt_er_niet_onder', p.excludes)
             order by p.main_group, p.name, p.id), '[]'::jsonb)
      from public.product_types p),
    'producten', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'naam', p.name,
               'namen', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'naam', pa.normalized_name, 'aankopen', coalesce(k.n, 0), 'items', coalesce(i.n, 0))
                        order by pa.normalized_name), '[]'::jsonb)
                 from public.product_aliases pa
                 left join koopnaam k on k.normalized_name = pa.normalized_name
                 left join itemnaam i on i.normalized_name = pa.normalized_name
                 where pa.product_id = p.id))
             order by lower(p.name), p.id), '[]'::jsonb)
      from public.products p),
    'lijstnamen', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'sleutel', g.key, 'naam', g.naam, 'artikelen', g.artikelen,
               'zonder_type', g.zonder_type, 'onbeoordeeld', g.onbeoordeeld, 'types', g.types)
             order by g.key), '[]'::jsonb)
      from (
        select l.key, min(l.naam) as naam, count(*)::integer as artikelen,
               count(*) filter (where t.article_id is not null and t.type_id is null)::integer as zonder_type,
               count(*) filter (where t.article_id is null)::integer as onbeoordeeld,
               coalesce((
                 select jsonb_agg(jsonb_build_object('type_id', x.type_id, 'artikelen', x.n) order by x.n desc)
                 from (
                   select t2.type_id, count(*)::integer as n
                   from lijstnaam l2
                   join public.article_types t2 on t2.supermarket = l2.supermarket and t2.article_id = l2.article_id
                   where l2.key = l.key and t2.type_id is not null
                   group by t2.type_id
                 ) x), '[]'::jsonb) as types
        from lijstnaam l
        left join public.article_types t on t.supermarket = l.supermarket and t.article_id = l.article_id
        group by l.key
      ) g),
    'artikelen', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'supermarket', x.supermarket, 'article_id', x.article_id, 'titel', x.title, 'categorie', x.category,
               'bron', case when b.article_id is not null then 'receipt' else 'catalog' end,
               'product_id', ap.product_id,
               'type_id', t.type_id, 'zekerheid', t.confidence, 'type_bron', t.source)
             order by x.category nulls last, x.title, x.article_id), '[]'::jsonb)
      from public.article_products() ap
      join public.articles x on upper(x.supermarket) = ap.supermarket and x.article_id = ap.article_id
      left join bon b on b.supermarket = ap.supermarket and b.article_id = ap.article_id
      left join public.article_types t on t.supermarket = x.supermarket and t.article_id = x.article_id),
    'synoniemen', (
      select coalesce(jsonb_agg(jsonb_build_object('sleutel', s.key, 'bron', s.source)), '[]'::jsonb)
      from public.term_synonyms s))
  into v;
  return v;
end $$;

-- ---------- Namen opslaan ----------
-- p_rows: [{ term, type_id, brand, confidence, reason }]; type_id null is "geen type". p_source: manual, ai of
-- catalog. De sleutel is de term in sleutelvorm. Overgeslagen worden: een lege sleutel, een onbekend type, een
-- term die zelf de naam van een type is (de typenaam gaat altijd voor), en een bestaande rij die voorgaat:
-- manual wordt alleen door manual vervangen, catalog niet door ai, en een nagekeken rij alleen door manual.
-- Zonder rolcontrole: voor save_term_types hieronder en later voor de Edge Function die termen beoordeelt.
create function public.save_term_types_internal(p_rows jsonb, p_source text) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_opgeslagen integer;
begin
  if p_source not in ('manual', 'ai', 'catalog') then raise exception 'Onbekende bron: %', p_source; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen namen om op te slaan'; end if;
  with rij as (
    select public.match_key(r->>'term') as sleutel, btrim(r->>'term') as term,
           nullif(r->>'type_id', '')::uuid as tid,
           nullif(public.match_key(r->>'brand'), '') as merk,
           r->>'confidence' as zekerheid, nullif(btrim(r->>'reason'), '') as reden
    from jsonb_array_elements(p_rows) r
  ),
  geldig as (
    select distinct on (rij.sleutel) rij.*
    from rij
    where rij.sleutel <> ''
      and (rij.tid is null or exists (select 1 from public.product_types p where p.id = rij.tid))
      and (rij.zekerheid is null or rij.zekerheid in ('high', 'medium', 'low'))
      and not exists (select 1 from public.product_types p where p.key = rij.sleutel)
    order by rij.sleutel
  ),
  op as (
    insert into public.term_synonyms as s
      (key, term, type_id, brand_key, confidence, reason, source, reviewed_at, reviewed_by)
    select g.sleutel, left(g.term, 120), g.tid, g.merk, g.zekerheid, left(g.reden, 300), p_source,
           case when p_source = 'manual' then now() end, case when p_source = 'manual' then auth.uid() end
    from geldig g
    on conflict (key) do update set
      term = excluded.term,
      target = null,
      type_id = excluded.type_id,
      brand_key = excluded.brand_key,
      confidence = excluded.confidence,
      reason = excluded.reason,
      source = excluded.source,
      created_at = now(),
      reviewed_at = excluded.reviewed_at,
      reviewed_by = excluded.reviewed_by
    where p_source = 'manual'
       or (s.source <> 'manual' and s.reviewed_at is null and not (s.source = 'catalog' and p_source = 'ai'))
    returning 1
  )
  select count(*) into v_opgeslagen from op;
  return jsonb_build_object('opgeslagen', v_opgeslagen, 'overgeslagen', jsonb_array_length(p_rows) - v_opgeslagen);
end $$;

create function public.save_term_types(p_rows jsonb, p_source text) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan namen aan een type koppelen'; end if;
  return public.save_term_types_internal(p_rows, p_source);
end $$;

-- ---------- Het type van een artikel zetten ----------
-- p_rows: [{ supermarket, article_id, type_id }]; type_id null is "geen type". p_source: receipt of catalog
-- (overgenomen uit de oude catalogus) of manual (de beheerder). Het oordeel geldt daarna als nagekeken, en
-- de AI vervangt het niet meer. Een rij van de beheerder (manual) wordt alleen door manual vervangen.
-- De zekerheid en reden van een eerder oordeel blijven staan als het type hetzelfde blijft.
create function public.set_article_types(p_rows jsonb, p_source text) returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_aantal integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan artikelen aan een type koppelen'; end if;
  if p_source not in ('receipt', 'catalog', 'manual') then raise exception 'Onbekende bron: %', p_source; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen artikelen om op te slaan'; end if;
  with rij as (
    select distinct on (btrim(r->>'supermarket'), btrim(r->>'article_id'))
           btrim(r->>'supermarket') as sm, btrim(r->>'article_id') as aid, nullif(r->>'type_id', '')::uuid as tid
    from jsonb_array_elements(p_rows) r
    order by btrim(r->>'supermarket'), btrim(r->>'article_id')
  ),
  op as (
    insert into public.article_types as t (supermarket, article_id, type_id, source, reviewed_at, reviewed_by)
    select rij.sm, rij.aid, rij.tid, p_source, now(), auth.uid()
    from rij
    join public.articles x on x.supermarket = rij.sm and x.article_id = rij.aid
    where rij.tid is null or exists (select 1 from public.product_types p where p.id = rij.tid)
    on conflict (supermarket, article_id) do update set
      confidence = case when t.type_id is not distinct from excluded.type_id then t.confidence end,
      reason = case when t.type_id is not distinct from excluded.type_id then t.reason end,
      suggested_type = null,
      type_id = excluded.type_id,
      source = excluded.source,
      reviewed_at = excluded.reviewed_at,
      reviewed_by = excluded.reviewed_by
    where p_source = 'manual' or t.source <> 'manual'
    returning 1
  )
  select count(*) into v_aantal from op;
  return v_aantal;
end $$;

-- ---------- Het type van een aankoop ----------
-- Afgeleid, niet opgeslagen: eerst het artikel van de aankoop (artikelnummer plus de supermarkt van de bon),
-- anders de naam: zelf de naam van een type, of een naam in term_synonyms. Zonder treffer is type_id leeg.
-- Een correctie in article_types of term_synonyms werkt zo vanzelf door in het profiel.
create function public.purchase_types()
returns table (purchase_id uuid, type_id uuid)
language sql stable security definer
set search_path to 'public'
as $$
  select a.id, coalesce(t.type_id, p.id, s.type_id)
  from public.purchases a
  left join public.receipts r on r.id = a.receipt_id
  left join public.article_types t
    on a.article_id is not null and t.article_id = a.article_id and upper(t.supermarket) = upper(btrim(r.store))
  left join public.product_types p on p.key = public.match_key(a.name)
  left join public.term_synonyms s on s.key = public.match_key(a.name);
$$;

-- ---------- Rechten ----------
revoke all on function public.type_migration_work() from public, anon;
revoke all on function public.save_term_types(jsonb, text) from public, anon;
revoke all on function public.set_article_types(jsonb, text) from public, anon;
grant execute on function public.type_migration_work() to authenticated, service_role;
grant execute on function public.save_term_types(jsonb, text) to authenticated, service_role;
grant execute on function public.set_article_types(jsonb, text) to authenticated, service_role;
-- De hulpfuncties: geen rolcontrole, of ze lezen aankopen van alle huishoudens
revoke all on function public.save_term_types_internal(jsonb, text) from public, anon, authenticated;
revoke all on function public.purchase_types() from public, anon, authenticated;
grant execute on function public.save_term_types_internal(jsonb, text) to service_role;
grant execute on function public.purchase_types() to service_role;
