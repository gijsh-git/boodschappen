-- Types ontstaan vanzelf.
--
-- Kon de AI een artikel of een term nergens kwijt, dan stond het met een voorstel in het scherm Koppelingen
-- te wachten tot de beheerder op "Type aanmaken" drukte. Tot dan was er geen Bonus-label. Nu geeft de AI bij
-- een voorstel ook de hoofdgroep en de afbakening, en maakt de database het type meteen aan: het artikel of
-- de term hoort er direct bij en de beheerder kijkt achteraf na (blok "Nieuwe types"), net als bij de
-- koppelingen zelf.
--
-- Een type ontstaat alleen als de AI zeker is (zekerheid hoog), een hoofdgroep uit de bestaande lijst noemt
-- en de naam op geen bestaand type lijkt. Lijkt hij er wel op (zelfde stam, of bijna dezelfde naam), dan
-- gebeurt er niets en staat het voorstel als voorheen onder "Geen type": dat is dan een keuze voor de
-- beheerder. Zonder voorstel (geen gewone boodschap: een apparaat, een starterset) ontstaat er nooit iets.

-- ---------- Opslag ----------
alter table public.product_types
  add column source text not null default 'manual' check (source in ('manual', 'ai')),
  add column reviewed_at timestamptz;
comment on column public.product_types.source is
  'Wie het type heeft aangemaakt: de beheerder (manual) of de AI op een eigen voorstel (ai).';
comment on column public.product_types.reviewed_at is
  'Wanneer de beheerder een type van de AI heeft gezien. Leeg bij bron ai: het staat in Koppelingen onder "Nieuwe types".';

-- ---------- Voorstellen worden types ----------
-- p_rows: de oordelen van de AI over artikelen of termen. Een rij zonder type met zekerheid high, een
-- suggested_type en een suggested_group (met suggested_scope en suggested_excludes) krijgt het type met die
-- naam: het bestaande, of een nieuw. Zo'n rij komt terug met type_id en variant_open (de variant is nog niet
-- beoordeeld: de AI wist het type nog niet). De andere rijen komen ongewijzigd terug.
-- Geeft { rijen, nieuw } terug; nieuw is het aantal aangemaakte types.
create function public.auto_create_types(p_rows jsonb) returns jsonb
language plpgsql security definer
set search_path to 'public', 'extensions'
as $$
declare
  r jsonb;
  v_uit jsonb := '[]'::jsonb;
  v_nieuw integer := 0;
  v_naam text;
  v_sleutel text;
  v_stam text;
  v_groep text;
  v_id uuid;
begin
  for r in select e from jsonb_array_elements(p_rows) e loop
    v_naam := lower(btrim(regexp_replace(coalesce(r->>'suggested_type', ''), '\s+', ' ', 'g')));
    v_sleutel := public.match_key(v_naam);
    v_groep := btrim(coalesce(r->>'suggested_group', ''));
    if nullif(r->>'type_id', '') is not null or r->>'confidence' is distinct from 'high'
       or v_sleutel = '' or char_length(v_naam) > 80 or v_groep = '' then
      v_uit := v_uit || jsonb_build_array(r);
      continue;
    end if;

    -- Hetzelfde voorstel kwam al eerder in deze ronde, of het type is intussen aangemaakt
    select p.id into v_id from public.product_types p where p.key = v_sleutel;
    if not found then
      v_stam := nullif(public.list_stem(v_naam), '');
      if not exists (select 1 from public.product_types p where p.main_group = v_groep)
         or v_groep = 'Geen boodschappen'
         or exists (select 1 from public.product_types p
                    where p.stem = v_stam or similarity(p.name, v_naam) >= 0.7) then
        v_uit := v_uit || jsonb_build_array(r);
        continue;
      end if;

      insert into public.product_types (name, main_group, scope, excludes, source)
      values (v_naam, v_groep, nullif(left(btrim(r->>'suggested_scope'), 400), ''),
              nullif(left(btrim(r->>'suggested_excludes'), 400), ''), 'ai')
      returning id into v_id;
      v_nieuw := v_nieuw + 1;

      -- Als bij "Type aanmaken": de naam is nu een typenaam, en wat al met dit voorstel wachtte hoort erbij
      delete from public.term_synonyms where key = v_sleutel;
      update public.term_synonyms s set type_id = v_id, suggested_type = null
       where s.type_id is null and s.reviewed_at is null and public.match_key(s.suggested_type) = v_sleutel;
      update public.article_types t set type_id = v_id, suggested_type = null
       where t.type_id is null and t.reviewed_at is null and public.match_key(t.suggested_type) = v_sleutel;
      update public.items i set type_id = v_id
       where i.offer_id is null and i.type_id is null and public.match_key(i.name) = v_sleutel;
    end if;

    v_uit := v_uit || jsonb_build_array((r - 'suggested_type') || jsonb_build_object('type_id', v_id, 'variant_open', true));
  end loop;
  return jsonb_build_object('rijen', v_uit, 'nieuw', v_nieuw);
end $$;

revoke all on function public.auto_create_types(jsonb) from public, anon, authenticated;
grant execute on function public.auto_create_types(jsonb) to service_role;

-- ---------- Artikelen: oordelen opslaan ----------
-- Als voorheen, met eerst auto_create_types(). Een artikel dat zo zijn type kreeg wacht nog op een variant:
-- article_type_work() biedt het in de volgende ronde opnieuw aan.
create or replace function public.save_article_types(p_rows jsonb, p_judged_at timestamptz default null) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_met integer;
  v_zonder integer;
  v_variant integer;
  v_auto jsonb;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen oordelen om op te slaan'; end if;
  v_auto := public.auto_create_types(p_rows);
  p_rows := v_auto->'rijen';

  update public.article_types t
     set variant = nullif(left(lower(btrim(r.variant)), 40), ''), variant_judged_at = now()
    from (select distinct on (btrim(e->>'supermarket'), btrim(e->>'article_id'))
                 btrim(e->>'supermarket') as sm, btrim(e->>'article_id') as aid, e->>'variant' as variant
          from jsonb_array_elements(p_rows) e
          where e->>'confidence' in ('high', 'medium', 'low') and e->>'variant_open' is null
          order by 1, 2) r
   where t.supermarket = r.sm and t.article_id = r.aid
     and t.type_id is not null and t.variant_judged_at is null;
  get diagnostics v_variant = row_count;

  with rij as (
    select btrim(r->>'supermarket') as sm, btrim(r->>'article_id') as aid,
           nullif(r->>'type_id', '')::uuid as tid,
           nullif(left(lower(btrim(r->>'variant')), 40), '') as variant,
           nullif(btrim(r->>'suggested_type'), '') as voorstel,
           r->>'confidence' as zekerheid, nullif(btrim(r->>'reason'), '') as reden,
           r->>'variant_open' is not null as open
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
           case when g.tid is not null and not g.open then g.variant end,
           case when g.tid is not null and not g.open then now() end
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
    'met_type', v_met, 'geen_type', v_zonder, 'variant', v_variant, 'nieuwe_types', (v_auto->>'nieuw')::integer,
    'overgeslagen', jsonb_array_length(p_rows) - v_met - v_zonder - v_variant);
end $$;

-- ---------- Termen: oordelen opslaan ----------
-- Als voorheen, met eerst auto_create_types(). Een term die zelf de naam van het nieuwe type is krijgt geen
-- rij (de typenaam wint); de items met die naam heeft auto_create_types() al hun type gegeven.
create or replace function public.save_term_judgments(p_rows jsonb, p_variants jsonb default null) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_rijen jsonb;
  v_varianten jsonb := case when jsonb_typeof(p_variants) = 'array' then p_variants else '[]'::jsonb end;
  v_uit jsonb;
  v_items integer;
  v_variant integer;
  v_auto jsonb;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen oordelen om op te slaan'; end if;
  select coalesce(jsonb_agg(
           case when exists (select 1 from public.articles x
                             where x.brand_key = public.match_key(r->>'brand') and x.brand_key <> '')
                then r else r - 'brand' end), '[]'::jsonb)
    into v_rijen
  from jsonb_array_elements(p_rows) r;
  v_auto := public.auto_create_types(v_rijen);
  v_rijen := v_auto->'rijen';

  v_uit := public.save_term_types_internal(v_rijen, 'ai');

  update public.unmatched_terms u set judged_at = now()
   where u.key in (select public.match_key(r->>'term') from jsonb_array_elements(v_rijen) r);

  update public.term_synonyms s
     set variant = nullif(left(lower(btrim(r.variant)), 40), ''), variant_judged_at = now()
    from (select distinct on (public.match_key(e->>'term'))
                 public.match_key(e->>'term') as sleutel, e->>'variant' as variant
          from jsonb_array_elements(v_rijen || v_varianten) e
          where e->>'variant_open' is null
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

  return v_uit || jsonb_build_object('items', v_items, 'varianten', v_variant, 'nieuwe_types', (v_auto->>'nieuw')::integer);
end $$;

-- ---------- Een nieuw type nakijken ----------
-- "Klopt" bij een type van de AI: het verdwijnt uit het blok "Nieuwe types".
create function public.review_product_type(p_type uuid) returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan een type nakijken'; end if;
  update public.product_types set reviewed_at = now() where id = p_type and reviewed_at is null;
end $$;

-- ---------- Een type verwijderen ----------
-- Voor een type dat er niet had moeten zijn. Zijn artikelen en namen blijven achter zonder type en gelden als
-- nagekeken, en de naam van het type zelf ook: zo stelt de AI het niet opnieuw voor. Items en vastgelegde
-- keuzes verliezen alleen hun verwijzing. Hoort het bij een ander type, voeg dan samen in plaats van verwijderen.
create function public.delete_product_type(p_type uuid) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_type public.product_types;
  v_artikelen integer;
  v_namen integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan een type verwijderen'; end if;
  select * into v_type from public.product_types where id = p_type;
  if not found then raise exception 'Type niet gevonden'; end if;

  update public.article_types t
     set type_id = null, suggested_type = null, variant = null, reviewed_at = now(), reviewed_by = auth.uid()
   where t.type_id = p_type;
  get diagnostics v_artikelen = row_count;
  update public.term_synonyms s
     set type_id = null, suggested_type = null, brand_key = null, variant = null, reviewed_at = now(), reviewed_by = auth.uid()
   where s.type_id = p_type;
  get diagnostics v_namen = row_count;
  delete from public.product_types where id = p_type;

  insert into public.term_synonyms as s (key, term, type_id, source, reason, reviewed_at, reviewed_by)
  values (v_type.key, v_type.name, null, 'manual', 'Was een type en is verwijderd', now(), auth.uid())
  on conflict (key) do update set
    type_id = null, brand_key = null, suggested_type = null, source = excluded.source, reason = excluded.reason,
    reviewed_at = excluded.reviewed_at, reviewed_by = excluded.reviewed_by;

  return jsonb_build_object('naam', v_type.name, 'artikelen', v_artikelen, 'namen', v_namen);
end $$;

revoke all on function public.review_product_type(uuid) from public, anon;
revoke all on function public.delete_product_type(uuid) from public, anon;
grant execute on function public.review_product_type(uuid) to authenticated, service_role;
grant execute on function public.delete_product_type(uuid) to authenticated, service_role;

-- ---------- Het overzicht voor het scherm Koppelingen ----------
-- Als voorheen, met bij elk type nieuw: door de AI aangemaakt en nog niet nagekeken.
--   types: [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder, telt_mee, nieuw, artikelen, namen, aankopen }]
create or replace function public.type_link_overview() returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan de koppelingen bekijken'; end if;
  select jsonb_build_object(
    'termen', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sleutel', s.key, 'term', s.term, 'type_id', s.type_id, 'type', p.name, 'merk', s.brand_key,
               'zekerheid', s.confidence, 'reden', s.reason, 'voorstel', s.suggested_type, 'op', s.created_at)
             order by s.created_at desc, s.key)
      from public.term_synonyms s
      left join public.product_types p on p.id = s.type_id
      where s.source = 'ai' and s.reviewed_at is null), '[]'::jsonb),
    'artikelen', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supermarkt', t.supermarket, 'artikel_id', t.article_id, 'titel', x.title, 'merk', x.brand,
               'inhoud', x.size, 'categorie', x.category, 'type_id', t.type_id, 'type', p.name,
               'zekerheid', t.confidence, 'reden', t.reason)
             order by lower(p.name), (t.confidence = 'low') desc, x.title, t.article_id)
      from public.article_types t
      join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
      join public.product_types p on p.id = t.type_id
      where t.source = 'ai' and t.reviewed_at is null and t.confidence in ('medium', 'low')), '[]'::jsonb),
    'zonder_type', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supermarkt', t.supermarket, 'artikel_id', t.article_id, 'titel', x.title, 'merk', x.brand,
               'inhoud', x.size, 'categorie', x.category, 'zekerheid', t.confidence, 'reden', t.reason,
               'voorstel', t.suggested_type)
             order by lower(t.suggested_type) nulls last, x.title, t.article_id)
      from public.article_types t
      join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
      where t.type_id is null and t.reviewed_at is null), '[]'::jsonb),
    'types', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'naam', p.name, 'hoofdgroep', p.main_group, 'valt_eronder', p.scope,
               'valt_er_niet_onder', p.excludes, 'telt_mee', p.counts_in_profile,
               'nieuw', p.source = 'ai' and p.reviewed_at is null,
               'artikelen', coalesce(a.n, 0), 'namen', coalesce(n.n, 0), 'aankopen', coalesce(k.n, 0))
             order by lower(p.name), p.id)
      from public.product_types p
      left join (select type_id, count(*)::integer as n from public.article_types group by type_id) a on a.type_id = p.id
      left join (select type_id, count(*)::integer as n from public.term_synonyms group by type_id) n on n.type_id = p.id
      left join (select type_id, count(*)::integer as n from public.purchase_types() group by type_id) k on k.type_id = p.id
    ), '[]'::jsonb))
  into v;
  return v;
end $$;
