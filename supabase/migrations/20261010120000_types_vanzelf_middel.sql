-- Types ontstaan vanzelf: ook bij zekerheid middel.
--
-- De zekerheid van de AI zegt bij "geen type" hoe zeker hij is dat geen bestaand type past, en dat is bij een
-- gewone boodschap vaak "middel" ("hazelnoten": de andere noten hebben wel een type). Met alleen "hoog" bleef
-- de helft van de voorstellen op de beheerder wachten. Nu telt of de AI een hoofdgroep bij het voorstel geeft:
-- twijfelt hij of iets een eigen type verdient, dan laat hij die leeg en wacht het voorstel onder "Geen type".
-- Alleen zekerheid laag maakt nooit een type aan. De rest van de functie is ongewijzigd.
--
-- p_rows: de oordelen van de AI over artikelen of termen. Een rij zonder type met zekerheid high of medium,
-- een suggested_type en een suggested_group krijgt het type met die naam: het bestaande, of een nieuw.
create or replace function public.auto_create_types(p_rows jsonb) returns jsonb
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
    if nullif(r->>'type_id', '') is not null or coalesce(r->>'confidence', '') not in ('high', 'medium')
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
