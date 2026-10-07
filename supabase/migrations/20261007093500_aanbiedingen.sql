-- Aanbiedingen van supermarkten met hun artikelen (roadmap stap 3).
--
-- Drie tabellen: articles (een artikel van een supermarkt), offers (een aanbieding met geldigheid en
-- korting) en offer_articles (welke artikelen bij welke aanbieding horen). Ze worden gevuld door
-- save_offers, dat alleen met de service role is aan te roepen. Dat doet de Edge Function
-- aanbiedingen-opslaan, waar scripts/ah-bonus-opslaan.py de opgehaalde week naartoe stuurt.
-- De oude tabel deals met testdata en deals_for_list blijven voorlopig staan; de app gebruikt die nog
-- tot het matchen in stap 5.

-- ---------- Artikelen ----------
-- Een artikel blijft staan, ook als de aanbieding voorbij is: de tabel is tegelijk de vertaling van het
-- artikelnummer op een bon (purchases.article_id) naar titel, merk, inhoud en categorie.
create table public.articles (
  supermarket text not null,
  article_id text not null,
  webshop_id text,
  title text not null,
  brand text,
  size text,
  category text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (supermarket, article_id)
);
comment on column public.articles.article_id is
  'Het artikelnummer in het systeem van de supermarkt, hetzelfde als purchases.article_id. Voor AH het hqId, niet het webshop-ID.';
comment on column public.articles.category is
  'Categorie van de supermarkt. Bij AH "hoofdcategorie/subcategorie", of alleen de subcategorie als het artikel alleen als losse aanbieding is gezien.';

-- ---------- Aanbiedingen ----------
-- offer_id is het nummer van de supermarkt. Samen met valid_from uniek, voor het geval een supermarkt
-- een nummer later opnieuw gebruikt.
create table public.offers (
  id uuid primary key default gen_random_uuid(),
  supermarket text not null,
  offer_id text not null,
  title text not null,
  discount_text text,
  discount_type text,
  labels jsonb not null default '[]'::jsonb,
  category text,
  valid_from date not null,
  valid_to date not null,
  is_group boolean not null default false,
  store_only boolean not null default false,
  created_at timestamptz not null default now(),
  fetched_at timestamptz not null default now(),
  unique (supermarket, offer_id, valid_from),
  check (valid_to >= valid_from)
);
create index offers_valid_to_idx on public.offers (valid_to);
comment on column public.offers.discount_type is
  'De code van het eerste label, bijvoorbeeld DISCOUNT_X_PLUS_Y_FREE of DISCOUNT_PERCENTAGE.';
comment on column public.offers.labels is
  'De kortingslabels zoals de bron ze geeft: per label code, omschrijving en de getallen (aantal, gratis, prijs, percentage, bedrag).';
comment on column public.offers.is_group is
  'true: een groep met meerdere artikelen ("Alle Hak potten"); false: één los artikel.';

-- ---------- Artikelen per aanbieding ----------
-- price is de gewone prijs in die week, bonus_price de actieprijs per stuk als de supermarkt die geeft
-- (bij "2e halve prijs" is die er niet).
create table public.offer_articles (
  offer_id uuid not null references public.offers(id) on delete cascade,
  supermarket text not null,
  article_id text not null,
  price numeric(8,2),
  bonus_price numeric(8,2),
  primary key (offer_id, supermarket, article_id),
  foreign key (supermarket, article_id) references public.articles(supermarket, article_id)
);
create index offer_articles_article_idx on public.offer_articles (supermarket, article_id);

-- Ingelogde gebruikers mogen lezen (het zijn openbare gegevens), niemand mag via de app schrijven
alter table public.articles enable row level security;
alter table public.offers enable row level security;
alter table public.offer_articles enable row level security;
revoke all on table public.articles, public.offers, public.offer_articles from public, anon, authenticated;
grant select on table public.articles, public.offers, public.offer_articles to authenticated;
create policy "ingelogden lezen artikelen" on public.articles for select to authenticated using (true);
create policy "ingelogden lezen aanbiedingen" on public.offers for select to authenticated using (true);
create policy "ingelogden lezen artikelen per aanbieding" on public.offer_articles for select to authenticated using (true);

-- ---------- Opslaan ----------
-- Slaat de aanbiedingen van één supermarkt op. p_offers is een lijst:
--   [{ offer_id, title, discount_text, labels, category, valid_from, valid_to, is_group, store_only,
--      complete, articles: [{ article_id, webshop_id, title, brand, size, category, price, bonus_price }] }]
-- Opnieuw draaien met dezelfde week voegt niets dubbel toe: aanbiedingen en artikelen worden bijgewerkt.
-- Bij complete = false (de artikelen van een groep ophalen is mislukt) blijven de artikelen staan die er
-- al bij stonden. Artikelen zonder article_id worden overgeslagen.
create or replace function public.save_offers(p_supermarket text, p_offers jsonb) returns jsonb
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  -- BEWAARTERMIJN: zo lang blijft een aanbieding na de laatste geldige dag nog staan
  c_bewaren constant integer := 28;
  v_supermarkt text := nullif(trim(p_supermarket), '');
  v_vandaag date := (now() at time zone 'Europe/Amsterdam')::date;
  a jsonb;
  v_offer uuid;
  v_lijst jsonb;
  v_aanbiedingen integer := 0;
  v_koppelingen integer := 0;
  v_rijen integer;
  v_artikelen_voor integer;
  v_artikelen_na integer;
  v_opgeruimd integer;
begin
  if v_supermarkt is null then
    raise exception 'Geen supermarkt opgegeven';
  end if;
  if p_offers is null or jsonb_typeof(p_offers) <> 'array' or jsonb_array_length(p_offers) = 0 then
    raise exception 'Geen aanbiedingen om op te slaan';
  end if;

  select count(*) into v_artikelen_voor from public.articles where supermarket = v_supermarkt;

  -- Artikelen: nieuwe erbij, bekende bijwerken. Een categorie met hoofdcategorie ("Zuivel, eieren/Kwark")
  -- wordt niet vervangen door alleen de subcategorie van een losse aanbieding.
  insert into public.articles (supermarket, article_id, webshop_id, title, brand, size, category)
  select distinct on (trim(x->>'article_id'))
         v_supermarkt, trim(x->>'article_id'), nullif(trim(x->>'webshop_id'), ''), trim(x->>'title'),
         nullif(trim(x->>'brand'), ''), nullif(trim(x->>'size'), ''), nullif(trim(x->>'category'), '')
  from jsonb_array_elements(p_offers) o
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(o->'articles') = 'array' then o->'articles' else '[]'::jsonb end) x
  where nullif(trim(x->>'article_id'), '') is not null
    and nullif(trim(x->>'title'), '') is not null
  order by trim(x->>'article_id'), (x->>'category' like '%/%') desc nulls last
  on conflict (supermarket, article_id) do update set
    webshop_id = coalesce(excluded.webshop_id, articles.webshop_id),
    title = excluded.title,
    brand = coalesce(excluded.brand, articles.brand),
    size = coalesce(excluded.size, articles.size),
    category = case
      when excluded.category is null then articles.category
      when articles.category like '%/%' and excluded.category not like '%/%' then articles.category
      else excluded.category end,
    last_seen_at = now();

  select count(*) into v_artikelen_na from public.articles where supermarket = v_supermarkt;

  for a in select * from jsonb_array_elements(p_offers) loop
    v_lijst := case when jsonb_typeof(a->'labels') = 'array' then a->'labels' else '[]'::jsonb end;
    insert into public.offers (supermarket, offer_id, title, discount_text, discount_type, labels, category,
                               valid_from, valid_to, is_group, store_only)
    values (v_supermarkt, trim(a->>'offer_id'), trim(a->>'title'), nullif(trim(a->>'discount_text'), ''),
            nullif(v_lijst->0->>'code', ''), v_lijst, nullif(trim(a->>'category'), ''),
            (a->>'valid_from')::date, (a->>'valid_to')::date,
            coalesce((a->>'is_group')::boolean, false), coalesce((a->>'store_only')::boolean, false))
    on conflict (supermarket, offer_id, valid_from) do update set
      title = excluded.title,
      discount_text = excluded.discount_text,
      discount_type = excluded.discount_type,
      labels = excluded.labels,
      category = excluded.category,
      valid_to = excluded.valid_to,
      is_group = excluded.is_group,
      store_only = excluded.store_only,
      fetched_at = now()
    returning id into v_offer;
    v_aanbiedingen := v_aanbiedingen + 1;

    if coalesce((a->>'complete')::boolean, true) then
      delete from public.offer_articles where offer_id = v_offer;
      insert into public.offer_articles (offer_id, supermarket, article_id, price, bonus_price)
      select distinct on (trim(x->>'article_id'))
             v_offer, v_supermarkt, trim(x->>'article_id'),
             nullif(x->>'price', '')::numeric, nullif(x->>'bonus_price', '')::numeric
      from jsonb_array_elements(
        case when jsonb_typeof(a->'articles') = 'array' then a->'articles' else '[]'::jsonb end) x
      where nullif(trim(x->>'article_id'), '') is not null
        and nullif(trim(x->>'title'), '') is not null
      order by trim(x->>'article_id');
      get diagnostics v_rijen = row_count;
      v_koppelingen := v_koppelingen + v_rijen;
    end if;
  end loop;

  -- Oude aanbiedingen opruimen, van alle supermarkten. De artikelen blijven staan.
  delete from public.offers where valid_to < v_vandaag - c_bewaren;
  get diagnostics v_opgeruimd = row_count;

  return jsonb_build_object(
    'aanbiedingen', v_aanbiedingen,
    'artikelen_in_aanbiedingen', v_koppelingen,
    'nieuwe_artikelen', v_artikelen_na - v_artikelen_voor,
    'artikelen_totaal', v_artikelen_na,
    'opgeruimd', v_opgeruimd);
end $$;

-- Alleen voor de Edge Function aanbiedingen-opslaan, die met de service role werkt; niet voor de app
revoke all on function public.save_offers(text, jsonb) from public, anon, authenticated;
grant execute on function public.save_offers(text, jsonb) to service_role;
