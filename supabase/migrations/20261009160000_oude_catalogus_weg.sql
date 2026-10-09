-- De oude catalogus opruimen (overstap naar producttypes, fase 8).
--
-- Sinds fase 4 rekent alles op producttypes en sinds fase 6 toont de app de oude catalogus niet meer. Hier
-- verdwijnen de tabellen en functies van het oude model: producten als verzameling namen met samenvoegen
-- (products, product_aliases, product_merges), de voorstellen artikel → product met goedkeuring
-- (article_links, article_link_rejections), de lijstnamen (article_names), en de functies van de eenmalige
-- overzetting. De inhoud van de zes tabellen staat in data/backup/20261009-oude-catalogus.json (niet in git).
-- Dit is niet terug te draaien met een migratie: de gegevens zijn daarna weg uit de database.
--
-- De tabellen gaan zonder "cascade" weg: hangt er nog iets aan wat hier niet eerst is losgemaakt, dan
-- mislukt de hele migratie en verandert er niets.

-- ---------- Eerst losmaken wat blijft ----------
-- add_offer_item: zet geen product_id meer bij het item.
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

  return i;
end $$;

-- merge_product_types, save_term_types_internal en update_product_type: de kolom term_synonyms.target
-- bestaat niet meer.
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
    term = excluded.term, type_id = excluded.type_id, brand_key = null, source = excluded.source,
    reason = excluded.reason, reviewed_at = excluded.reviewed_at, reviewed_by = excluded.reviewed_by;

  return jsonb_build_object('bron', v_bron.name, 'doel', v_doel.name, 'artikelen', v_artikelen, 'namen', v_namen);
end $$;

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

create or replace function public.update_product_type(
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

-- ---------- De oude catalogus houdt zichzelf niet meer bij ----------
drop trigger items_product on public.items;
drop trigger purchases_product on public.purchases;
drop function public.ensure_product();

-- ---------- Functies van het oude model ----------
-- Producten: overzicht, samenvoegen, losmaken, hernoemen, de vlag
drop function public.product_overview();
drop function public.merge_products(uuid, uuid);
drop function public.undo_merge(uuid);
drop function public.merge_products_internal(uuid, uuid, uuid);
drop function public.rename_product(uuid, text);
drop function public.set_product_profile(uuid, boolean);
-- Artikel → product: voorstellen, goedkeuren, afwijzen, nalezen, en de lijstnamen
drop function public.article_link_work();
drop function public.save_article_proposals(jsonb, timestamptz);
drop function public.article_link_overview();
drop function public.approve_article_links(jsonb);
drop function public.reject_article_link(text, text);
drop function public.article_link_review();
drop function public.save_article_names(jsonb);
-- De eenmalige overzetting naar types en het laden van de typelijst uit een bestand
drop function public.type_proposal_work();
drop function public.type_migration_work();
drop function public.save_product_types(jsonb);
-- De oude koppeling artikel → product, als laatste: de functies hierboven gebruikten ze
drop function public.article_products();
drop function public.article_on_receipt(text, text);
drop function public.receipt_articles();

-- ---------- Kolommen ----------
-- items.product_id was een aantekening van het catalogusproduct; items.type_id is ervoor in de plaats gekomen.
-- term_synonyms.target (naam → andere naam) is vervangen door type_id.
drop index public.items_product_idx;
alter table public.items drop column product_id;
alter table public.term_synonyms drop column target;

-- ---------- Tabellen ----------
-- De leespolicy van products kijkt in product_aliases; die moet eerst weg
drop policy "beheerder en lijstleden zien producten" on public.products;
drop table public.article_link_rejections;
drop table public.article_links;
drop table public.article_names;
drop table public.product_merges;
drop table public.product_aliases;
drop table public.products;
