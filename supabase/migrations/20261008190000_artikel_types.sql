-- Artikelen krijgen een producttype (overstap naar producttypes, fase 2).
--
-- Elk artikel uit de aanbiedingen hoort bij hooguit één type uit product_types. De Edge Function
-- artikelen-classificeren beoordeelt de artikelen die nog geen oordeel hebben met de AI (titel, merk en
-- categorie als invoer) en slaat dat hier op; scripts/ah-bonus-opslaan.py roept haar aan na het ophalen
-- van de bonus. Er is geen goedkeuring vooraf: de beheerder controleert en corrigeert later.
--
-- Deze migratie verandert niets aan bestaande tabellen of functies. article_links, article_products() en
-- alles wat daarop rekent blijven werken tot de omschakeling; niets leest article_types nog.

-- ---------- Opslag ----------
-- Eén rij per beoordeeld artikel; een artikel zonder rij is nog niet beoordeeld.
create table public.article_types (
  supermarket text not null,
  article_id text not null,
  type_id uuid references public.product_types(id),
  suggested_type text,
  confidence text check (confidence in ('high', 'medium', 'low')),
  reason text,
  source text not null check (source in ('receipt', 'catalog', 'ai', 'manual')),
  judged_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid,
  primary key (supermarket, article_id),
  foreign key (supermarket, article_id) references public.articles(supermarket, article_id)
);
create index article_types_type_idx on public.article_types (type_id);
comment on column public.article_types.type_id is
  'Het type van het artikel. Leeg: beoordeeld, maar er is geen passend type.';
comment on column public.article_types.suggested_type is
  'Alleen zonder type: de naam van het type dat volgens de AI in de lijst ontbreekt.';
comment on column public.article_types.source is
  'ai: oordeel van het model; receipt en catalog: overgenomen uit de oude catalogus (bon of goedgekeurde koppeling); manual: gezet door de beheerder. Alleen een ai-rij die nog niet is nagekeken wordt door een nieuw oordeel vervangen.';
comment on column public.article_types.judged_at is
  'Wanneer de typelijst voor dit oordeel is gelezen. Een artikel zonder type wordt opnieuw beoordeeld als er daarna types zijn bijgekomen.';

-- Geen policies en geen rechten: alleen de functies komen bij deze tabel
alter table public.article_types enable row level security;
revoke all on table public.article_types from public, anon, authenticated;

-- ---------- Het werk voor de Edge Function ----------
-- { gelezen_op, nog,
--   types: [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder }],   -- de hele typelijst, vaste volgorde
--   artikelen: [{ supermarket, article_id, titel, merk, inhoud, categorie }] }   -- hooguit p_limit
-- Te beoordelen: het artikel heeft nog geen oordeel, of de AI vond geen type en er zijn sindsdien types
-- bijgekomen. nog telt alles wat te beoordelen is, ook wat niet in deze portie zit. De artikelen komen per
-- categorie, zodat wat op elkaar lijkt samen wordt beoordeeld.
create function public.article_type_work(p_limit integer default 120) returns jsonb
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

-- ---------- Oordelen opslaan ----------
-- p_rows: [{ supermarket, article_id, type_id, suggested_type, confidence, reason }]; type_id null is "geen type".
-- p_judged_at: gelezen_op uit article_type_work, zodat types die tijdens het beoordelen zijn bijgekomen
-- later nog een herbeoordeling geven. Overgeslagen worden: onbekende artikelen en types, een ongeldige
-- zekerheid, en artikelen met een oordeel dat niet van de AI is of dat de beheerder al heeft nagekeken.
create function public.save_article_types(p_rows jsonb, p_judged_at timestamptz default null) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_met integer;
  v_zonder integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen oordelen om op te slaan'; end if;
  with rij as (
    select btrim(r->>'supermarket') as sm, btrim(r->>'article_id') as aid,
           nullif(r->>'type_id', '')::uuid as tid,
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
      (supermarket, article_id, type_id, suggested_type, confidence, reason, source, judged_at)
    select g.sm, g.aid, g.tid, case when g.tid is null then left(g.voorstel, 80) end,
           g.zekerheid, left(g.reden, 300), 'ai', coalesce(p_judged_at, now())
    from geldig g
    on conflict (supermarket, article_id) do update set
      type_id = excluded.type_id,
      suggested_type = excluded.suggested_type,
      confidence = excluded.confidence,
      reason = excluded.reason,
      judged_at = excluded.judged_at
    where t.source = 'ai' and t.reviewed_at is null
    returning t.type_id
  )
  select count(*) filter (where op.type_id is not null), count(*) filter (where op.type_id is null)
    into v_met, v_zonder
  from op;
  return jsonb_build_object(
    'met_type', v_met, 'geen_type', v_zonder,
    'overgeslagen', jsonb_array_length(p_rows) - v_met - v_zonder);
end $$;

-- Alleen voor de Edge Function artikelen-classificeren, die met de service role werkt; niet voor de app
revoke all on function public.article_type_work(integer) from public, anon, authenticated;
revoke all on function public.save_article_types(jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.article_type_work(integer) to service_role;
grant execute on function public.save_article_types(jsonb, timestamptz) to service_role;
