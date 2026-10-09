-- Een merk met een soort erbij ("nivea shampoo", "sensodyne tandpasta").
--
-- De titellaag is in fase 4 vervallen, en daarmee vond een term als "sensodyne tandpasta" niets meer tot de
-- AI hem beoordeelt. Dit hoeft de AI niet: is het ene deel van de term een merk en het andere een type (of
-- een naam daarvan), dan staat de term voor de artikelen van dat merk binnen dat type. term_articles() valt
-- terug op het hele type als het merk daar geen artikelen in heeft. De rest van term_match() is ongewijzigd.

create or replace function public.term_match(p_name text)
returns table (step smallint, type_id uuid, brand_key text)
language plpgsql stable security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_key text := public.match_key(p_name);
  v_stem text;
  v_grens real;
  v_woorden text[];
  v_links text;
  v_rechts text;
  v_type uuid;
begin
  if v_key = '' then return; end if;

  -- 1. de naam van een type
  return query select 1::smallint, p.id, null::text from public.product_types p where p.key = v_key;
  if found then return; end if;

  -- 3. een merk
  if exists (select 1 from public.articles x where x.brand_key = v_key) then
    return query select 3::smallint, null::uuid, v_key;
    return;
  end if;

  -- 2. een naam van een type, eventueel met een merk erbij
  return query select 2::smallint, s.type_id, s.brand_key from public.term_synonyms s where s.key = v_key;
  if found then return; end if;

  -- 1 en 2 na stamming
  v_stem := public.list_stem(p_name);
  if v_stem <> '' then
    return query select 1::smallint, p.id, null::text
                 from public.product_types p where p.stem = v_stem order by p.name limit 1;
    if found then return; end if;
    return query select 2::smallint, s.type_id, s.brand_key
                 from public.term_synonyms s where s.stem = v_stem and s.type_id is not null
                 order by s.key limit 1;
    if found then return; end if;
  end if;

  -- 3. een merk met een soort erbij, in beide volgordes: "nivea shampoo", "tandpasta oral b".
  -- MEESTE WOORDEN: daarboven is het geen merk met een soort meer
  v_woorden := regexp_split_to_array(public.normalize_search(p_name), '\s+');
  if cardinality(v_woorden) between 2 and 6 then
    for i in 1 .. cardinality(v_woorden) - 1 loop
      v_links := array_to_string(v_woorden[1:i], ' ');
      v_rechts := array_to_string(v_woorden[i + 1:cardinality(v_woorden)], ' ');
      if exists (select 1 from public.articles x where x.brand_key = public.match_key(v_links) and x.brand_key <> '') then
        v_type := public.name_type(v_rechts);
        if v_type is not null then
          return query select 3::smallint, v_type, public.match_key(v_links);
          return;
        end if;
      end if;
      if exists (select 1 from public.articles x where x.brand_key = public.match_key(v_rechts) and x.brand_key <> '') then
        v_type := public.name_type(v_links);
        if v_type is not null then
          return query select 3::smallint, v_type, public.match_key(v_rechts);
          return;
        end if;
      end if;
    end loop;
  end if;

  -- 4. tolerant. KORTSTE TERM: onder de 5 tekens lijkt te veel op elkaar ("ham" en "hak")
  if char_length(v_key) >= 5 then
    select coalesce((select value from public.settings where key = 'fuzzy_min_similarity_pct'), 55) / 100.0
      into v_grens;
    return query
      with kandidaat as (
        select 1 as rang, p.key as sleutel, p.id as soort, null::text as merk, similarity(p.key, v_key) as score
        from public.product_types p
        union all
        select 2, s.key, s.type_id, s.brand_key, similarity(s.key, v_key)
        from public.term_synonyms s where s.type_id is not null
        union all
        select 3, b.brand_key, null::uuid, b.brand_key, similarity(b.brand_key, v_key)
        from (select distinct x.brand_key from public.articles x where x.brand_key <> '') b
      )
      select 4::smallint, k.soort, k.merk
      from kandidaat k
      where k.score >= v_grens
      order by k.score desc, k.rang, k.sleutel
      limit 1;
  end if;
end $$;
