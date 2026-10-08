-- Bijstelling van het gelaagd matchen na de eerste proef op alle ooit getypte namen.
--
-- 1. De sleutelvorm gold alleen voor lijstnamen. "proteine drank" matchte daardoor nog steeds niet, terwijl
--    "proteinedrank" een naam van het product eiwitdrank is. Laag 1 vergelijkt nu ook de namen van producten
--    in sleutelvorm (zonder spaties, leestekens en accenten).
-- 2. De titellaag was te ruim bij één woord: "gember" raakte een groentesap met gember, "boter" een
--    smeerkaas, "suiker" pecannoten met suiker. Laag 5 geldt nu alleen voor termen van minstens twee woorden
--    ("sensodyne tandpasta", "mona toetje"). Een los onbekend woord komt in unmatched_terms.

create index product_aliases_key_idx on public.product_aliases (public.match_key(normalized_name));

-- ---------- Laag 1: exact ----------
-- De artikelen van een naam: via het product (naam in sleutelvorm → product_aliases → article_products()),
-- of doordat de naam gelijk is aan een lijstnaam, in sleutelvorm of na stamming. supermarket in hoofdletters.
create or replace function public.term_articles_exact(p_name text)
returns table (supermarket text, article_id text)
language sql stable security definer
set search_path to 'public'
as $$
  select ap.supermarket, ap.article_id
  from public.product_aliases pa
  join public.article_products() ap on ap.product_id = pa.product_id
  where public.match_key(pa.normalized_name) = public.match_key(p_name)
    and public.match_key(p_name) <> ''
  union
  select upper(n.supermarket), n.article_id
  from public.article_names n
  where (n.key = public.match_key(p_name) and n.key <> '')
     or (n.stem = public.list_stem(p_name) and n.stem <> '');
$$;

-- ---------- Alle lagen ----------
create or replace function public.term_articles(p_name text)
returns table (supermarket text, article_id text, step smallint)
language plpgsql stable security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_key text := public.match_key(p_name);
  v_doel text;
  v_grens real;
  v_vraag tsquery;
begin
  if v_key = '' then return; end if;

  -- 1. exact
  return query select e.supermarket, e.article_id, 1::smallint from public.term_articles_exact(p_name) e;
  if found then return; end if;

  -- 2. synoniem: doe alsof de naam erachter is getypt
  select s.target into v_doel from public.term_synonyms s where s.key = v_key;
  if v_doel is not null then
    return query select e.supermarket, e.article_id, 2::smallint from public.term_articles_exact(v_doel) e;
    if found then return; end if;
  end if;

  -- 3. merk
  return query select upper(x.supermarket), x.article_id, 3::smallint
               from public.articles x where x.brand_key = v_key;
  if found then return; end if;

  -- 4. tolerant: de best gelijkende lijstnaam of het best gelijkende merk, boven de grens.
  -- KORTSTE TERM: onder de 5 tekens lijkt te veel op elkaar ("ham" en "hak")
  if char_length(v_key) >= 5 then
    select coalesce((select value from public.settings where key = 'fuzzy_min_similarity_pct'), 55) / 100.0
      into v_grens;
    return query
      with kandidaat as (
        select n.key as sleutel, similarity(n.key, v_key) as score
        from (select distinct an.key from public.article_names an where an.key <> '') n
        union all
        select b.brand_key, similarity(b.brand_key, v_key)
        from (select distinct x.brand_key from public.articles x where x.brand_key <> '') b
      ),
      beste as (
        select k.sleutel from kandidaat k
        where k.score >= v_grens and k.score = (select max(k2.score) from kandidaat k2)
      )
      select upper(n.supermarket), n.article_id, 4::smallint
      from public.article_names n where n.key in (select sleutel from beste)
      union
      select upper(x.supermarket), x.article_id, 4::smallint
      from public.articles x where x.brand_key in (select sleutel from beste);
    if found then return; end if;
  end if;

  -- 5. titel: alle woorden van de term (gestemd) in merk en titel.
  -- MINSTENS TWEE WOORDEN: één los woord in een titel zegt te weinig ("gember" in een groentesap)
  v_vraag := plainto_tsquery('pg_catalog.dutch'::regconfig, public.normalize_search(p_name));
  if numnode(v_vraag) >= 3 then
    return query select upper(x.supermarket), x.article_id, 5::smallint
                 from public.articles x where x.title_search @@ v_vraag;
  end if;
end $$;
