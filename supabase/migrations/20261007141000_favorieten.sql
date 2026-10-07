-- Favorieten (roadmap stap 4): per gebruiker een zoekterm, een merk of allebei, waarvan die wil weten of het
-- in de aanbieding is. Alleen vastleggen en beheren; het matchen met aanbiedingen komt in stap 5.
--
-- Een favoriet loopt niet via products en product_aliases: hij wordt straks rechtstreeks vergeleken met
-- articles (title, brand, category). Hier komt dus niets in de gedeelde catalogus bij.

-- ---------- Normalisatie ----------
-- Kleine letters, zonder accenten, zonder dubbele spaties: "Calvé" en "calve" zijn hetzelfde.
-- unaccent zelf is niet immutable (het woordenboek kan wijzigen); met het woordenboek vast erbij kan deze
-- functie dat wel zijn, en dat is nodig voor de berekende kolommen hieronder.
create function public.normalize_search(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary,
               btrim(regexp_replace(p_text, '\s+', ' ', 'g'))));
$$;
comment on function public.normalize_search(text) is
  'Zoekvorm van een tekst: kleine letters, zonder accenten, spaties ingedikt. Voor favorieten en het matchen daarvan.';

-- ---------- Tabel ----------
create table public.favorites (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  term text,
  brand text,
  category text,
  normalized_term text generated always as (public.normalize_search(term)) stored,
  normalized_brand text generated always as (public.normalize_search(brand)) stored,
  created_at timestamptz not null default now(),
  -- Term en merk mogen elk ontbreken, niet allebei. Leeg is null, geen lege tekst.
  constraint favorites_iets_ingevuld check (term is not null or brand is not null),
  constraint favorites_term_check check (term is null or (btrim(term) <> '' and char_length(term) <= 60)),
  constraint favorites_brand_check check (brand is null or (btrim(brand) <> '' and char_length(brand) <= 60)),
  -- De categorie hoort bij de term (gekozen uit de suggesties); zonder term is er geen
  constraint favorites_category_check check (category is null or (term is not null and btrim(category) <> '' and char_length(category) <= 120))
);
comment on column public.favorites.term is
  'Zoekterm, bijvoorbeeld "pindakaas". Matcht straks op hele woorden in de titel van een artikel.';
comment on column public.favorites.brand is
  'Merk, bijvoorbeeld "Calvé". Matcht straks exact (zonder hoofdletters en accenten) op articles.brand.';
comment on column public.favorites.category is
  'Hoofdcategorie van de supermarkt ("Koffie, thee"), het deel vóór de "/" in articles.category. Gevuld als de term uit de suggesties is gekozen, anders leeg.';

-- Dezelfde term met hetzelfde merk kan maar één keer per gebruiker, los van hoofdletters en accenten
create unique index favorites_uniek on public.favorites
  (user_id, coalesce(normalized_term, ''), coalesce(normalized_brand, ''));

-- Alleen je eigen favorieten: anderen zien ze niet, ook lijstgenoten niet
alter table public.favorites enable row level security;
revoke all on table public.favorites from public, anon, authenticated;
grant select, insert, update, delete on table public.favorites to authenticated;
create policy "eigen favorieten zien" on public.favorites for select to authenticated
  using (user_id = auth.uid());
create policy "eigen favoriet toevoegen" on public.favorites for insert to authenticated
  with check (user_id = auth.uid());
create policy "eigen favoriet wijzigen" on public.favorites for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "eigen favoriet verwijderen" on public.favorites for delete to authenticated
  using (user_id = auth.uid());

-- ---------- Suggesties ----------
-- Merken die beginnen met wat er getypt is, of waarin een woord daarmee begint. "AH" en "AH Excellent"
-- zijn losse merken. Bron is alles wat ooit in een aanbieding zat, niet alleen de lopende week.
create function public.suggest_favorite_brands(p_query text)
returns table (brand text, articles integer)
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (select public.normalize_search(p_query) as zoek),
  merk as (
    select public.normalize_search(a.brand) as zoekvorm, min(a.brand) as brand, count(*)::integer as aantal
    from public.articles a
    where a.brand is not null
    group by 1
  )
  select m.brand, m.aantal
  from merk m, q
  where q.zoek <> ''
    and (starts_with(m.zoekvorm, q.zoek) or position(' ' || q.zoek in m.zoekvorm) > 0)
  order by starts_with(m.zoekvorm, q.zoek) desc, m.aantal desc, m.brand
  limit 8;
$$;

-- Termen met de hoofdcategorie erbij. Twee bronnen:
--   1. de subcategorie van een artikel, gesplitst op komma's ("Appelmoes, appelcompote" → twee termen);
--   2. de losse woorden in de titel, zonder de woorden van het merk en zonder woorden onder de 3 letters.
-- De hoofdcategorie is het deel vóór de "/". Een artikel dat alleen als losse aanbieding is gezien heeft
-- alleen een subcategorie; de suggestie komt dan zonder categorie terug.
create function public.suggest_favorite_terms(p_query text)
returns table (term text, category text, articles integer)
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (select public.normalize_search(p_query) as zoek),
  art as (
    -- Alleen artikelen waar de zoektekst ergens in titel of categorie staat; de rest hoeft niet in woorden geknipt
    select a.supermarket, a.article_id, lower(a.title) as titel,
           coalesce(public.normalize_search(a.brand), '') as merk,
           case when a.category like '%/%' then nullif(btrim(split_part(a.category, '/', 1)), '') end as hoofd,
           case when a.category like '%/%' then split_part(a.category, '/', 2) else a.category end as sub
    from public.articles a, q
    where char_length(q.zoek) >= 2
      and (position(q.zoek in public.normalize_search(a.title)) > 0
        or position(q.zoek in coalesce(public.normalize_search(a.category), '')) > 0)
  ),
  kandidaat as (
    -- 1. delen van de subcategorie
    select art.supermarket, art.article_id, art.hoofd, btrim(lower(deel)) as term
    from art, regexp_split_to_table(coalesce(art.sub, ''), ',') as deel
    where btrim(deel) <> ''
    union
    -- 2. woorden uit de titel
    select art.supermarket, art.article_id, art.hoofd, woord
    from art, regexp_split_to_table(art.titel, '[^[:alnum:]]+') as woord
    where char_length(woord) >= 3
      and woord !~ '^[0-9]'
      and position(' ' || public.normalize_search(woord) || ' ' in ' ' || art.merk || ' ') = 0
  ),
  geteld as (
    select public.normalize_search(k.term) as zoekvorm, min(k.term) as term, k.hoofd,
           count(distinct (k.supermarket, k.article_id))::integer as aantal
    from kandidaat k
    group by 1, k.hoofd
  )
  select g.term, g.hoofd, g.aantal
  from geteld g, q
  where starts_with(g.zoekvorm, q.zoek) or position(' ' || q.zoek in g.zoekvorm) > 0
  order by (g.zoekvorm = q.zoek) desc, starts_with(g.zoekvorm, q.zoek) desc, g.aantal desc, g.term, g.hoofd nulls last
  limit 8;
$$;

revoke all on function public.normalize_search(text) from public, anon;
revoke all on function public.suggest_favorite_brands(text) from public, anon;
revoke all on function public.suggest_favorite_terms(text) from public, anon;
grant execute on function public.normalize_search(text) to authenticated, service_role;
grant execute on function public.suggest_favorite_brands(text) to authenticated, service_role;
grant execute on function public.suggest_favorite_terms(text) to authenticated, service_role;
