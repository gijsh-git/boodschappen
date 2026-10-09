-- De variant bepaalt het label, per type in te stellen.
--
-- Bij "paprikapoeder" kwam het Bonus-label ook als alleen kaneel in de aanbieding was: beide zijn het type
-- "kruiden", en het type is het niveau van matchen. Voor de meeste types klopt dat ("tomatensoep" toont elke
-- soep, daar wissel je voor een aanbieding). Voor een type als kruiden of kruidenmix niet: daar wissel je niet
-- binnen het type. Zo'n type krijgt de vlag variant_narrows. Een term die een variant noemt staat dan alleen
-- voor de artikelen met dezelfde variant. Kent het type geen enkel artikel met die variant, dan blijft de term
-- voor het hele type staan: twee schrijfwijzen van dezelfde variant kosten zo nooit een label.

-- ---------- Opslag ----------
alter table public.product_types
  add column variant_narrows boolean not null default false;
comment on column public.product_types.variant_narrows is
  'Een term die een variant noemt ("paprikapoeder") staat alleen voor de artikelen met dezelfde variant, niet voor het hele type.';

-- ---------- Voor welke artikelen staat een term? ----------
-- Een type: alle artikelen van dat type. Een merk: alle artikelen van dat merk. Allebei: de artikelen van
-- dat merk binnen het type, en als dat er geen zijn het hele type. Bij een type met variant_narrows gaat de
-- variant van de term voor: eerst die variant van het merk, dan die variant van elk merk.
create or replace function public.term_articles(p_name text)
returns table (supermarket text, article_id text, step smallint)
language plpgsql stable security definer
set search_path to 'public', 'extensions'
as $$
declare
  m record;
  v_variant text;
begin
  select * into m from public.term_match(p_name);
  if not found then return; end if;

  if m.type_id is not null
     and exists (select 1 from public.product_types p where p.id = m.type_id and p.variant_narrows) then
    v_variant := public.term_variant(p_name);
  end if;
  if v_variant is not null then
    if m.brand_key is not null then
      return query
        select upper(t.supermarket), t.article_id, m.step
        from public.article_types t
        join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
        where t.type_id = m.type_id and t.variant_stem = v_variant and x.brand_key = m.brand_key;
      if found then return; end if;
    end if;
    return query select upper(t.supermarket), t.article_id, m.step
                 from public.article_types t where t.type_id = m.type_id and t.variant_stem = v_variant;
    if found then return; end if;
  end if;

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

-- ---------- Een type wijzigen ----------
-- Naam, hoofdgroep, afbakening en de vlaggen "telt niet mee in profiel" en "variant bepaalt het label". Bij
-- een andere naam blijft de oude naam werken als naam van het type. Zonder p_variant blijft die vlag zoals
-- hij was, zodat een client die hem nog niet meestuurt hem niet uitzet.
drop function public.update_product_type(uuid, text, text, text, text, boolean);
create function public.update_product_type(
  p_type uuid, p_name text, p_main_group text, p_scope text, p_excludes text, p_counts boolean,
  p_variant boolean default null)
returns public.product_types
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_naam text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_oud public.product_types;
  v_nieuw public.product_types;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan een type wijzigen'; end if;
  if public.match_key(v_naam) = '' or char_length(v_naam) > 80 then raise exception 'Geef het type een naam van 1 tot 80 tekens'; end if;
  if btrim(coalesce(p_main_group, '')) = '' then raise exception 'Kies een hoofdgroep'; end if;
  select * into v_oud from public.product_types where id = p_type;
  if not found then raise exception 'Type niet gevonden'; end if;
  if exists (select 1 from public.product_types where key = public.match_key(v_naam) and id <> p_type) then
    raise exception 'Er is al een type "%"', v_naam;
  end if;

  update public.product_types
     set name = v_naam, main_group = btrim(p_main_group), scope = nullif(btrim(p_scope), ''),
         excludes = nullif(btrim(p_excludes), ''), counts_in_profile = coalesce(p_counts, true),
         variant_narrows = coalesce(p_variant, variant_narrows)
   where id = p_type
  returning * into v_nieuw;

  if v_nieuw.key <> v_oud.key then
    -- De nieuwe naam is nu een typenaam en kan geen losse naam meer zijn; de oude naam wordt er een
    delete from public.term_synonyms where key = v_nieuw.key;
    insert into public.term_synonyms as s (key, term, type_id, source, reason, reviewed_at, reviewed_by)
    values (v_oud.key, v_oud.name, v_nieuw.id, 'manual', 'De vorige naam van het type', now(), auth.uid())
    on conflict (key) do update set
      term = excluded.term, type_id = excluded.type_id, brand_key = null, source = excluded.source,
      reason = excluded.reason, suggested_type = null, reviewed_at = excluded.reviewed_at, reviewed_by = excluded.reviewed_by;
  end if;
  return v_nieuw;
end $$;

revoke all on function public.update_product_type(uuid, text, text, text, text, boolean, boolean) from public, anon;
grant execute on function public.update_product_type(uuid, text, text, text, text, boolean, boolean) to authenticated, service_role;

-- ---------- Het overzicht voor het scherm Koppelingen ----------
-- Ongewijzigd, op één veld na: bij elk type staat variant_telt.
--   types: [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder, telt_mee, variant_telt, artikelen, namen, aankopen }]
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
               'valt_er_niet_onder', p.excludes, 'telt_mee', p.counts_in_profile, 'variant_telt', p.variant_narrows,
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
