-- Koppelingen toont alleen nog echte twijfel (10 oktober 2026).
--
-- Na de eerste week van PLUS stonden er 376 artikelen met zekerheid middel of laag om na te kijken; 87% was
-- goed, en van de rest was het meeste een besluit over de indeling en geen fout van de AI. Het scherm toont
-- daarom niet meer wat de AI "waarschijnlijk" vond:
--   - termen: alleen zekerheid laag, of zonder type met een voorstel voor een type dat ontbreekt;
--   - artikelen om na te kijken: alleen zekerheid laag (was middel en laag);
--   - geen type: alleen met een voorstel (een type dat ontbreekt en niet vanzelf is aangemaakt), of zekerheid
--     laag. Wat zonder voorstel geen type heeft is geen gewone boodschap en vraagt niets.
-- De oordelen zelf veranderen niet: alles telt als voorheen meteen mee, en bij het type zelf blijft elk
-- artikel in te zien en te verzetten.
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
      where s.source = 'ai' and s.reviewed_at is null
        and (s.confidence = 'low' or (s.type_id is null and s.suggested_type is not null))), '[]'::jsonb),
    'artikelen', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supermarkt', t.supermarket, 'artikel_id', t.article_id, 'titel', x.title, 'merk', x.brand,
               'inhoud', x.size, 'categorie', x.category, 'type_id', t.type_id, 'type', p.name,
               'zekerheid', t.confidence, 'reden', t.reason)
             order by lower(p.name), (t.confidence = 'low') desc, x.title, t.article_id)
      from public.article_types t
      join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
      join public.product_types p on p.id = t.type_id
      where t.source = 'ai' and t.reviewed_at is null and t.confidence = 'low'), '[]'::jsonb),
    'zonder_type', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supermarkt', t.supermarket, 'artikel_id', t.article_id, 'titel', x.title, 'merk', x.brand,
               'inhoud', x.size, 'categorie', x.category, 'zekerheid', t.confidence, 'reden', t.reason,
               'voorstel', t.suggested_type)
             order by lower(t.suggested_type) nulls last, x.title, t.article_id)
      from public.article_types t
      join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
      where t.type_id is null and t.reviewed_at is null
        and (t.confidence = 'low' or t.suggested_type is not null)), '[]'::jsonb),
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
