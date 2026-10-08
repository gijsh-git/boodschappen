-- Gelaagd matchen van wat iemand op de lijst typt (het Bonus-label).
--
-- Tot nu toe kreeg een item het label alleen bij exacte gelijkheid: via zijn product, of doordat zijn naam
-- na stamming gelijk was aan een lijstnaam. "proteine drank" (spatie), "chocola", "tandenpasta" en een merk
-- als "nivea" vielen daardoor buiten de boot. Vanaf hier is er één functie, term_articles(), die zegt voor
-- welke artikelen een term staat. De eerste laag die iets oplevert wint:
--   1. exact:    via het product, of gelijk aan een lijstnaam (zonder spaties en leestekens, of na stamming);
--   2. synoniem: term_synonyms zegt voor welke naam de term staat, en die gaat door laag 1;
--   3. merk:     de term is het merk van een artikel;
--   4. tolerant: de term lijkt genoeg op een lijstnaam of een merk (pg_trgm, grens in settings);
--   5. titel:    alle woorden van de term staan in het merk en de titel van een artikel.
-- Wat daarna niets oplevert komt in unmatched_terms, via handle_unmatched_term(): het ene punt waar later
-- een AI-stap aanhaakt die zo'n term aan een naam koppelt en dat als synoniem opslaat.
--
-- term_articles() kijkt naar alle artikelen die ooit in een aanbieding zaten, niet alleen die van deze week:
-- "tandpasta" in een week zonder tandpasta-aanbieding is geen onbekende term. Welke aanbiedingen nu gelden
-- bepalen offers_for_list() en offer_details_for_list(), die hier dezelfde signatuur houden.
-- Voor jou (offers_for_me) en het aankoopprofiel veranderen niet; een synoniem voegt geen producten samen.

-- ---------- Sleutelvorm ----------
-- normalize_search (kleine letters, zonder accenten) en daarna alles weg wat geen letter of cijfer is:
-- "Proteïne-drank", "proteine drank" en "proteinedrank" worden gelijk. Leeg als er niets overblijft.
create function public.match_key(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(regexp_replace(public.normalize_search(p_text), '[^a-z0-9]', '', 'g'), '');
$$;
comment on function public.match_key(text) is
  'Sleutelvorm van een lijstterm: normalize_search zonder spaties en leestekens. Voor het matchen in term_articles.';

alter table public.article_names
  add column key text generated always as (public.match_key(name)) stored;
create index article_names_key_idx on public.article_names (key);

-- Het merk in sleutelvorm ("Oral-B" en "oral b" zijn gelijk), en merk plus titel als doorzoekbare tekst
alter table public.articles
  add column brand_key text generated always as (public.match_key(brand)) stored,
  add column title_search tsvector generated always as (
    to_tsvector('pg_catalog.dutch'::regconfig, public.normalize_search(coalesce(brand, '') || ' ' || title))) stored;
create index articles_brand_key_idx on public.articles (brand_key);
create index articles_title_search_idx on public.articles using gin (title_search);

-- ---------- Synoniemen ----------
-- Een term staat voor een andere naam: "chocola" voor "chocolade". Telt alleen voor het Bonus-label.
-- Beheer voorlopig in de SQL Editor (het zijn gegevens, geen structuur), zie docs/matching-controle.sql:
--   insert into public.term_synonyms (key, term, target, source)
--   values (public.match_key('chocola'), 'chocola', 'chocolade', 'manual');
-- source: 'manual' (de beheerder) of 'ai' (de latere AI-stap). Geen policies en geen rechten.
create table public.term_synonyms (
  key text primary key check (key <> ''),
  term text not null check (btrim(term) <> ''),
  target text not null check (btrim(target) <> ''),
  source text not null check (source in ('manual', 'ai')),
  created_at timestamptz not null default now()
);
alter table public.term_synonyms enable row level security;
revoke all on table public.term_synonyms from public, anon, authenticated;

-- ---------- Logboek ----------
-- Termen die bij het toevoegen aan een lijst nergens op matchten. Zonder gebruiker of lijst: alleen de term,
-- hoe vaak en wanneer. judged_at is voor de AI-stap: wanneer die de term beoordeeld heeft, ook als er niets
-- bij paste, zodat hij niet steeds opnieuw wordt gevraagd. Geen policies en geen rechten.
create table public.unmatched_terms (
  key text primary key check (key <> ''),
  term text not null,
  times integer not null default 1,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  judged_at timestamptz
);
alter table public.unmatched_terms enable row level security;
revoke all on table public.unmatched_terms from public, anon, authenticated;

-- GRENS TOLERANT: vanaf welke gelijkenis (pg_trgm, in procenten) een term bij een lijstnaam of merk hoort
insert into public.settings (key, value, description) values
  ('fuzzy_min_similarity_pct', 55, 'Tolerant matchen: minstens zoveel procent gelijkenis met een lijstnaam of merk');

-- ---------- Laag 1: exact ----------
-- De artikelen van een naam: via het product (naam → product_aliases → article_products()), of doordat de
-- naam gelijk is aan een lijstnaam, in sleutelvorm of na stamming. supermarket in hoofdletters.
create function public.term_articles_exact(p_name text)
returns table (supermarket text, article_id text)
language sql stable security definer
set search_path to 'public'
as $$
  select ap.supermarket, ap.article_id
  from public.product_aliases pa
  join public.article_products() ap on ap.product_id = pa.product_id
  where pa.normalized_name = lower(btrim(p_name))
  union
  select upper(n.supermarket), n.article_id
  from public.article_names n
  where (n.key = public.match_key(p_name) and n.key <> '')
     or (n.stem = public.list_stem(p_name) and n.stem <> '');
$$;

-- ---------- Alle lagen ----------
-- Voor welke artikelen staat deze term? De eerste laag met een treffer wint; step zegt welke dat was.
-- Geeft niets terug als de term nergens op matcht. supermarket in hoofdletters.
create function public.term_articles(p_name text)
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

  -- 5. titel: alle woorden van de term (gestemd) in merk en titel
  v_vraag := plainto_tsquery('pg_catalog.dutch'::regconfig, public.normalize_search(p_name));
  if numnode(v_vraag) > 0 then
    return query select upper(x.supermarket), x.article_id, 5::smallint
                 from public.articles x where x.title_search @@ v_vraag;
  end if;
end $$;

-- ---------- Niet-gematchte termen ----------
-- Het ene punt waar een term terechtkomt die nergens op matcht. Nu: bijhouden in unmatched_terms.
-- Later: een script leest die tabel (judged_at leeg, en term_articles geeft nog steeds niets), vraagt de AI
-- bij welke naam de term hoort en schrijft dat in term_synonyms met source 'ai'. Laag 2 pakt het dan op.
create function public.handle_unmatched_term(p_name text) returns void
language sql security definer
set search_path to 'public'
as $$
  insert into public.unmatched_terms (key, term)
  select public.match_key(p_name), btrim(p_name)
  where public.match_key(p_name) <> ''
  on conflict (key) do update
    set term = excluded.term, times = public.unmatched_terms.times + 1, last_seen = now();
$$;

-- Bij een nieuw item of een nieuwe naam. Een item uit Voor jou (offer_id) heeft zijn aanbieding al.
-- Een fout in het matchen mag het toevoegen van een boodschap nooit tegenhouden: dan alleen een waarschuwing.
create function public.check_item_term() returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  begin
    if new.offer_id is null and not exists (select 1 from public.term_articles(new.name)) then
      perform public.handle_unmatched_term(new.name);
    end if;
  exception when others then
    raise warning 'check_item_term: %', sqlerrm;
  end;
  return new;
end $$;

create trigger items_term after insert or update of name on public.items
  for each row execute function public.check_item_term();

-- ---------- Bonus-label op de lijst ----------
-- Per item bij welke supermarkt er hoeveel geldige aanbiedingen zijn. Twee routes, elke aanbieding telt één keer:
--   1. via de naam: term_articles() zegt voor welke artikelen het item staat;
--   2. via de aanbieding waarmee het item op de lijst is gezet (items.offer_id).
create or replace function public.offers_for_list(p_list uuid)
returns table (item_id uuid, supermarkt text, aantal integer)
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  treffer as (
    select i.id as item, g.id as offer, g.supermarket
    from public.items i
    cross join lateral public.term_articles(i.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list and public.is_member(p_list)
    union
    select i.id, g.id, g.supermarket
    from public.items i
    join geldig g on g.id = i.offer_id
    where i.list_id = p_list
  )
  select t.item, t.supermarket, count(distinct t.offer)::integer
  from treffer t
  where public.is_member(p_list)
  group by t.item, t.supermarket;
$$;

-- Wat er precies in de aanbieding is bij de items op de lijst: dezelfde twee routes als offers_for_list.
-- artikelen zijn de artikelen waar het om gaat: via de naam de artikelen waar de term voor staat, via
-- items.offer_id alle artikelen van de aanbieding.
create or replace function public.offer_details_for_list(p_list uuid) returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket, o.title, o.discount_text, o.valid_to
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  treffer as (
    select i.id as item, g.id as offer, oa.supermarket, oa.article_id
    from public.items i
    cross join lateral public.term_articles(i.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list and public.is_member(p_list)
    union
    select i.id, g.id, oa.supermarket, oa.article_id
    from public.items i
    join geldig g on g.id = i.offer_id
    left join public.offer_articles oa on oa.offer_id = g.id
    where i.list_id = p_list
  ),
  per as (
    select t.item, t.offer, count(x.article_id)::integer as totaal,
           -- AANTAL TITELS: zoveel artikelen worden hooguit bij naam genoemd
           coalesce((array_agg(x.title order by x.title) filter (where x.article_id is not null))[1:6], '{}') as artikelen
    from treffer t
    left join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
    group by t.item, t.offer
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', p.item, 'id', g.id, 'supermarkt', g.supermarket, 'titel', g.title,
           'korting', g.discount_text, 'geldig_tot', g.valid_to,
           'artikelen', to_jsonb(p.artikelen), 'artikelen_totaal', p.totaal)
         order by g.title, g.id, p.item), '[]'::jsonb)
  from per p
  join geldig g on g.id = p.offer
  where public.is_member(p_list);
$$;

-- ---------- Rechten ----------
-- De hulpfuncties lezen artikelen en aankopen van alle huishoudens: niet voor de app-rollen.
revoke all on function public.match_key(text) from public, anon;
grant execute on function public.match_key(text) to authenticated, service_role;
revoke all on function public.term_articles_exact(text) from public, anon, authenticated;
revoke all on function public.term_articles(text) from public, anon, authenticated;
revoke all on function public.handle_unmatched_term(text) from public, anon, authenticated;
revoke all on function public.check_item_term() from public, anon, authenticated;
grant execute on function public.term_articles_exact(text) to service_role;
grant execute on function public.term_articles(text) to service_role;
grant execute on function public.handle_unmatched_term(text) to service_role;
