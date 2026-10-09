-- De functies voor het scherm Koppelingen (overstap naar producttypes, fase 6, stap 1).
--
-- De beheerder ziet wat de AI heeft gekoppeld, corrigeert wat fout is en ziet welke types ontbreken. Niets
-- wacht op goedkeuring: alles telt al mee. Vanaf hier is de database de bron van de typelijst; het bestand
-- docs/producttypes-export.csv is alleen een afdruk ervan (product_types_export, via een Edge Function).
-- Alles hieronder is alleen voor de beheerder, behalve de export (service role).
-- Verandert bestaande functies: save_term_types_internal (onthoudt het voorgestelde type) en
-- reset_untyped_articles (geeft de AI daarna zelf een seintje).

-- ---------- Het type dat ontbreekt, ook bij termen ----------
alter table public.term_synonyms add column suggested_type text;
comment on column public.term_synonyms.suggested_type is
  'Alleen zonder type: de naam van het type dat volgens de AI in de lijst ontbreekt.';

create or replace function public.save_term_types_internal(p_rows jsonb, p_source text) returns jsonb
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
           r->>'confidence' as zekerheid, nullif(btrim(r->>'reason'), '') as reden,
           nullif(btrim(r->>'suggested_type'), '') as voorstel
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
      (key, term, type_id, brand_key, confidence, reason, suggested_type, source, reviewed_at, reviewed_by)
    select g.sleutel, left(g.term, 120), g.tid, g.merk, g.zekerheid, left(g.reden, 300),
           case when g.tid is null then left(g.voorstel, 80) end, p_source,
           case when p_source = 'manual' then now() end, case when p_source = 'manual' then auth.uid() end
    from geldig g
    on conflict (key) do update set
      term = excluded.term,
      target = null,
      type_id = excluded.type_id,
      brand_key = excluded.brand_key,
      confidence = excluded.confidence,
      reason = excluded.reason,
      suggested_type = excluded.suggested_type,
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

-- ---------- Het overzicht ----------
-- { termen:      [{ sleutel, term, type_id, type, merk, zekerheid, reden, voorstel, op }],
--   artikelen:   [{ supermarkt, artikel_id, titel, merk, inhoud, categorie, type_id, type, zekerheid, reden }],
--   zonder_type: [{ supermarkt, artikel_id, titel, merk, inhoud, categorie, zekerheid, reden, voorstel }],
--   types:       [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder, telt_mee, artikelen, namen, aankopen }] }
-- termen: wat de AI beoordeelde en de beheerder nog niet heeft gezien, de nieuwste eerst.
-- artikelen: de oordelen van de AI met zekerheid middel of laag die nog niet zijn nagekeken. Zekerheid hoog
--   staat hier niet: dat zijn er te veel om na te lopen en ze zijn in te zien via het type (type_details).
-- zonder_type: artikelen waar de AI geen type bij vond en die nog niet zijn nagekeken.
create function public.type_link_overview() returns jsonb
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

-- De namen en de artikelen van één type, pas bij openklappen: ook wat zekerheid hoog heeft of al is nagekeken.
--   { namen:     [{ sleutel, term, merk, bron, zekerheid, nagekeken }],
--     artikelen: [{ supermarkt, artikel_id, titel, merk, inhoud, categorie, bron, zekerheid, reden, nagekeken }] }
create function public.type_details(p_type uuid) returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan de koppelingen bekijken'; end if;
  return jsonb_build_object(
    'namen', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sleutel', s.key, 'term', s.term, 'merk', s.brand_key, 'bron', s.source,
               'zekerheid', s.confidence, 'nagekeken', s.reviewed_at is not null)
             order by lower(s.term))
      from public.term_synonyms s where s.type_id = p_type), '[]'::jsonb),
    'artikelen', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supermarkt', t.supermarket, 'artikel_id', t.article_id, 'titel', x.title, 'merk', x.brand,
               'inhoud', x.size, 'categorie', x.category, 'bron', t.source, 'zekerheid', t.confidence,
               'reden', t.reason, 'nagekeken', t.reviewed_at is not null)
             order by x.title, t.article_id)
      from public.article_types t
      join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
      where t.type_id = p_type), '[]'::jsonb));
end $$;

-- ---------- "Klopt" ----------
-- p_terms: sleutels van namen; p_articles: [{ supermarket, article_id }]. Zet alleen dat de beheerder het
-- oordeel heeft gezien; het type en de bron blijven wat ze zijn. Een nagekeken oordeel vervangt de AI niet meer.
create function public.mark_links_reviewed(p_terms text[], p_articles jsonb) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_termen integer := 0;
  v_artikelen integer := 0;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan koppelingen nakijken'; end if;
  update public.term_synonyms s set reviewed_at = now(), reviewed_by = auth.uid()
   where s.key = any (coalesce(p_terms, '{}')) and s.reviewed_at is null;
  get diagnostics v_termen = row_count;
  if p_articles is not null and jsonb_typeof(p_articles) = 'array' then
    update public.article_types t set reviewed_at = now(), reviewed_by = auth.uid()
      from jsonb_array_elements(p_articles) r
     where t.supermarket = r->>'supermarket' and t.article_id = r->>'article_id' and t.reviewed_at is null;
    get diagnostics v_artikelen = row_count;
  end if;
  return jsonb_build_object('termen', v_termen, 'artikelen', v_artikelen);
end $$;

-- ---------- Een type aanmaken ----------
-- Voor "Type aanmaken" in het scherm. p_suggestion is het voorstel van de AI waar het type voor komt (mag
-- leeg): de termen en artikelen zonder type met precies dat voorstel horen meteen bij het nieuwe type, en
-- blijven een oordeel van de AI dat nog nagekeken kan worden. De overige artikelen zonder type beoordeelt de
-- AI opnieuw, nu het type bestaat. Een naam die al een naam van een ander type was, hoort vanaf nu bij dit
-- type: de typenaam gaat altijd voor.
create function public.create_product_type(
  p_name text, p_main_group text, p_scope text default null, p_excludes text default null,
  p_counts boolean default true, p_suggestion text default null) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_naam text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_voorstel text := public.match_key(p_suggestion);
  v_type public.product_types;
  v_termen integer := 0;
  v_artikelen integer := 0;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan een type aanmaken'; end if;
  if public.match_key(v_naam) = '' or char_length(v_naam) > 80 then raise exception 'Geef het type een naam van 1 tot 80 tekens'; end if;
  if btrim(coalesce(p_main_group, '')) = '' then raise exception 'Kies een hoofdgroep'; end if;
  if exists (select 1 from public.product_types where key = public.match_key(v_naam)) then
    raise exception 'Het type "%" bestaat al', v_naam;
  end if;

  insert into public.product_types (name, main_group, scope, excludes, counts_in_profile)
  values (v_naam, btrim(p_main_group), nullif(btrim(p_scope), ''), nullif(btrim(p_excludes), ''), coalesce(p_counts, true))
  returning * into v_type;
  delete from public.term_synonyms where key = v_type.key;

  if v_voorstel <> '' then
    update public.term_synonyms s set type_id = v_type.id, suggested_type = null
     where s.type_id is null and s.reviewed_at is null and public.match_key(s.suggested_type) = v_voorstel;
    get diagnostics v_termen = row_count;
    update public.article_types t set type_id = v_type.id, suggested_type = null
     where t.type_id is null and t.reviewed_at is null and public.match_key(t.suggested_type) = v_voorstel;
    get diagnostics v_artikelen = row_count;
  end if;

  return jsonb_build_object('id', v_type.id, 'naam', v_type.name, 'termen', v_termen, 'artikelen', v_artikelen,
                            'opnieuw', public.reset_untyped_articles());
end $$;

-- ---------- Een type wijzigen ----------
-- Naam, hoofdgroep, afbakening en de vlag "telt niet mee in profiel". Bij een andere naam blijft de oude
-- naam werken als naam van het type.
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
      term = excluded.term, target = null, type_id = excluded.type_id, brand_key = null, source = excluded.source,
      reason = excluded.reason, suggested_type = null, reviewed_at = excluded.reviewed_at, reviewed_by = excluded.reviewed_by;
  end if;
  return v_nieuw;
end $$;

-- ---------- Artikelen opnieuw laten beoordelen ----------
-- Zoals voorheen, en nu geeft de database de Edge Function artikelen-classificeren zelf een seintje (via
-- pg_net, adres in Vault onder artikelen_classificeren_url). Zonder dat adres wacht het op de wekelijkse ronde.
create or replace function public.reset_untyped_articles() returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_aantal integer;
  v_url text;
  v_sleutel text;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan artikelen opnieuw laten beoordelen'; end if;
  delete from public.article_types where type_id is null and source = 'ai' and reviewed_at is null;
  get diagnostics v_aantal = row_count;
  if v_aantal > 0 then
    begin
      select decrypted_secret into v_url from vault.decrypted_secrets where name = 'artikelen_classificeren_url';
      select decrypted_secret into v_sleutel from vault.decrypted_secrets where name = 'aanbiedingen_sleutel';
      if coalesce(v_url, '') <> '' and coalesce(v_sleutel, '') <> '' then
        perform net.http_post(
          url := v_url,
          headers := jsonb_build_object('Content-Type', 'application/json', 'x-aanbiedingen-sleutel', v_sleutel),
          body := '{}'::jsonb,
          timeout_milliseconds := 120000);
      end if;
    exception when others then
      raise warning 'reset_untyped_articles: %', sqlerrm;
    end;
  end if;
  return v_aantal;
end $$;

-- ---------- De typelijst als afdruk ----------
-- Voor docs/producttypes-export.csv: de database is de bron, het bestand volgt. Alleen namen, afbakeningen en
-- aantallen; geen aankopen of gebruikers.
create function public.product_types_export() returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'hoofdgroep', p.main_group, 'type', p.name, 'valt_eronder', p.scope, 'valt_er_niet_onder', p.excludes,
           'telt_mee', p.counts_in_profile,
           'artikelen', (select count(*) from public.article_types t where t.type_id = p.id),
           'namen', (select coalesce(jsonb_agg(s.term order by lower(s.term)), '[]'::jsonb)
                     from public.term_synonyms s where s.type_id = p.id))
         order by lower(p.main_group), lower(p.name)), '[]'::jsonb)
  from public.product_types p;
$$;

-- ---------- Rechten ----------
revoke all on function public.type_link_overview() from public, anon;
revoke all on function public.type_details(uuid) from public, anon;
revoke all on function public.mark_links_reviewed(text[], jsonb) from public, anon;
revoke all on function public.create_product_type(text, text, text, text, boolean, text) from public, anon;
revoke all on function public.update_product_type(uuid, text, text, text, text, boolean) from public, anon;
grant execute on function public.type_link_overview() to authenticated, service_role;
grant execute on function public.type_details(uuid) to authenticated, service_role;
grant execute on function public.mark_links_reviewed(text[], jsonb) to authenticated, service_role;
grant execute on function public.create_product_type(text, text, text, text, boolean, text) to authenticated, service_role;
grant execute on function public.update_product_type(uuid, text, text, text, text, boolean) to authenticated, service_role;
revoke all on function public.product_types_export() from public, anon, authenticated;
grant execute on function public.product_types_export() to service_role;
