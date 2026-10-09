-- De variant bepaalt het label, voor elk type dezelfde regel.
--
-- Een term die een variant noemt ("paprikapoeder", "tomatensoep", "nasi kruiden") staat alleen voor de artikelen
-- van het type met die variant. De naam van het type zelf ("kruiden", "soep") heeft geen variant en staat
-- voor het hele type. Past geen enkel artikel van het type bij de variant, dan blijft de term voor het hele
-- type staan: een onbekende of anders geschreven variant kost zo nooit een label. Er is geen instelling per
-- type; de vlag variant_narrows uit de vorige migratie vervalt.
--
-- Een artikel heeft maar één variant, terwijl een titel er vaak meer noemt ("AH Tijger volkoren heel" heeft
-- "tijger"). Daarom past een artikel ook als zijn titel elk woord van de variant bevat, op stam, en vanaf
-- 4 letters als begin van een woord ("venkel" vindt "Venkelzaad", "halfvol" vindt "Halfvolle").

-- ---------- Voor welke artikelen staat een term? ----------
-- Noemt de term een variant: eerst de passende artikelen van het merk (als de term een merk noemt), dan die van
-- elk merk. Anders, of als er geen passen: de artikelen van het merk binnen het type, dan het hele type, of bij
-- alleen een merk alles van dat merk.
create or replace function public.term_articles(p_name text)
returns table (supermarket text, article_id text, step smallint)
language plpgsql stable security definer
set search_path to 'public', 'extensions'
as $$
declare
  m record;
  v_variant text;
  v_vraag tsquery;
begin
  select * into m from public.term_match(p_name);
  if not found then return; end if;

  if m.type_id is not null then
    v_variant := public.term_variant(p_name);
  end if;
  if v_variant is not null then
    -- De woorden van de variant als zoekvraag op de titel: allemaal, en vanaf 4 letters ook als begin van een woord
    select to_tsquery('simple', string_agg(quote_literal(l.lexeme) || case when length(l.lexeme) >= 4 then ':*' else '' end, ' & '))
      into v_vraag
      from unnest(v_variant::tsvector) l;
    if m.brand_key is not null then
      return query
        select upper(t.supermarket), t.article_id, m.step
        from public.article_types t
        join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
        where t.type_id = m.type_id and x.brand_key = m.brand_key
          and (t.variant_stem = v_variant
               or to_tsvector('pg_catalog.dutch', public.normalize_search(x.title)) @@ v_vraag);
      if found then return; end if;
    end if;
    return query
      select upper(t.supermarket), t.article_id, m.step
      from public.article_types t
      join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
      where t.type_id = m.type_id
        and (t.variant_stem = v_variant
             or to_tsvector('pg_catalog.dutch', public.normalize_search(x.title)) @@ v_vraag);
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

comment on column public.article_types.variant is
  'De smaak of soort binnen het type, één woord ("tomaat"). Een term die die variant noemt staat voor dit artikel; ook voor de volgorde in het bonuspaneel. Leeg als er geen variant te noemen is.';
comment on column public.term_synonyms.variant is
  'De smaak of soort die de term binnen het type noemt, één woord ("tomaat" bij "tomatensoep"): de term staat alleen voor de artikelen met die variant.';

-- ---------- Een type wijzigen ----------
-- Weer zonder de vlag voor de variant. Bij een andere naam blijft de oude naam werken als naam van het type.
drop function public.update_product_type(uuid, text, text, text, text, boolean, boolean);
create function public.update_product_type(
  p_type uuid, p_name text, p_main_group text, p_scope text, p_excludes text, p_counts boolean)
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
         excludes = nullif(btrim(p_excludes), ''), counts_in_profile = coalesce(p_counts, true)
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

revoke all on function public.update_product_type(uuid, text, text, text, text, boolean) from public, anon;
grant execute on function public.update_product_type(uuid, text, text, text, text, boolean) to authenticated, service_role;

-- ---------- Het overzicht voor het scherm Koppelingen ----------
-- Weer zonder variant_telt.
--   types: [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder, telt_mee, artikelen, namen, aankopen }]
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

-- ---------- De vlag vervalt ----------
alter table public.product_types drop column variant_narrows;
