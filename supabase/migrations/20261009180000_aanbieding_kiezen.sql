-- Een aanbieding kiezen bij een item (roadmap stap 7, deel 2).
--
-- In het bonuspaneel van de lijst kies je per item de aanbieding die je gaat kopen, eventueel met de
-- artikelen erbij. De keuze vervangt het item: er komt geen tweede rij (anders dan add_offer_item vanuit
-- "Voor jou"). Het item onthoudt wat er oorspronkelijk stond en valt daarop terug als de aanbieding is
-- verlopen. Alles loopt via items, dus Realtime laat het meteen aan alle leden zien.

-- ---------- Opslag ----------
alter table public.items
  add column original_name text,
  add column offer_choice jsonb;
comment on column public.items.original_name is
  'Wat er stond voordat een aanbieding werd gekozen ("tomatensoep"). Leeg bij een item zonder keuze.';
comment on column public.items.offer_choice is
  'De gekozen aanbieding zoals ze was bij het kiezen: { titel, korting, geldig_tot, supermarkt, artikelen: [{ artikel_id, titel }] }. artikelen is leeg als de aanbieding als geheel is gekozen.';

-- Een gekochte keuze: per gekozen artikel een aankoop. article_supermarket maakt het artikel vindbaar zonder
-- bon; item_choice is het item zoals het was, zodat ongedaan maken het precies terugzet.
alter table public.purchases
  add column original_name text,
  add column article_supermarket text,
  add column item_choice jsonb;
comment on column public.purchases.original_name is
  'Bij een aankoop van een gekozen aanbieding: wat er oorspronkelijk op de lijst stond.';
comment on column public.purchases.article_supermarket is
  'De supermarkt bij article_id als de aankoop niet van een bon komt (een gekozen aanbieding); bij een bon zegt receipts.store het.';
comment on column public.purchases.item_choice is
  'Alleen bij een gekozen aanbieding: { name, original_name, offer_id, offer_choice, article_supermarket, article_id, type_id } van het item, voor undo_purchase.';

-- ---------- Wat valt er te kiezen ----------
-- De artikelen van een aanbieding, voor het item waarbij je kiest:
--   [{ artikel_id, titel, zelfde, past, gekozen }]
-- zelfde: dezelfde variant als de oorspronkelijke term; past: de term staat voor dit artikel (zelfde type of
-- merk); gekozen: zit al in de keuze van het item. Volgorde: zelfde, past, titel.
create function public.offer_choice_options(p_item uuid, p_offer uuid) returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  i public.items;
  v_term text;
  v_variant text;
begin
  select * into i from public.items where id = p_item;
  if not found or not public.is_member(i.list_id) then raise exception 'Item niet gevonden'; end if;
  v_term := coalesce(i.original_name, i.name);
  v_variant := public.term_variant(v_term);
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'artikel_id', k.article_id, 'titel', k.title, 'zelfde', k.zelfde, 'past', k.past, 'gekozen', k.gekozen)
           order by k.zelfde desc, k.past desc, k.title, k.article_id), '[]'::jsonb)
    from (
      select x.article_id, x.title,
             coalesce(a.variant_stem = v_variant, false) as zelfde,
             exists (select 1 from public.term_articles(v_term) ta
                     where ta.supermarket = upper(x.supermarket) and ta.article_id = x.article_id) as past,
             coalesce(i.offer_id = p_offer and i.offer_choice->'artikelen' @> jsonb_build_array(jsonb_build_object('artikel_id', x.article_id)), false) as gekozen
      from public.offer_articles oa
      join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
      left join public.article_types a on a.supermarket = x.supermarket and a.article_id = x.article_id
      where oa.offer_id = p_offer
    ) k);
end $$;

-- ---------- Kiezen ----------
-- p_articles: de aangevinkte artikelen van de aanbieding; leeg is de aanbieding als geheel. Het item heet
-- daarna naar het artikel (bij precies één) of naar de aanbieding. Opnieuw kiezen bij een item dat al een
-- keuze heeft vervangt de keuze; de oorspronkelijke invoer blijft die van de eerste keer.
create function public.choose_offer(p_item uuid, p_offer uuid, p_articles text[] default null) returns public.items
language plpgsql security definer
set search_path to 'public'
as $$
declare
  i public.items;
  o public.offers;
  v_titel text;
  v_artikelen jsonb;
  v_aantal integer;
  v_supermarkt text;
  v_artikel text;
  v_artikeltitel text;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  select * into i from public.items where id = p_item for update;
  if not found or not public.is_member(i.list_id) then raise exception 'Item niet gevonden'; end if;
  if exists (select 1 from public.lists where id = i.list_id and archived_at is not null) then
    raise exception 'Deze lijst is gearchiveerd';
  end if;
  select * into o from public.offers
   where id = p_offer and (now() at time zone 'Europe/Amsterdam')::date between valid_from and valid_to;
  if not found then raise exception 'Deze aanbieding is niet meer geldig'; end if;
  -- MEESTE ARTIKELEN: meer dan dit is geen keuze meer maar de aanbieding als geheel
  if coalesce(cardinality(p_articles), 0) > 20 then raise exception 'Kies hooguit 20 artikelen'; end if;

  v_titel := btrim(regexp_replace(o.title, '\s*\*+$', ''));
  v_titel := upper(left(v_titel, 1)) || substr(v_titel, 2);

  select coalesce(jsonb_agg(jsonb_build_object('artikel_id', x.article_id, 'titel', x.title) order by x.title, x.article_id), '[]'::jsonb),
         count(*), min(x.supermarket), min(x.article_id), min(x.title)
    into v_artikelen, v_aantal, v_supermarkt, v_artikel, v_artikeltitel
    from public.offer_articles oa
    join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
   where oa.offer_id = p_offer and oa.article_id = any (coalesce(p_articles, '{}'));

  update public.items
     set original_name = coalesce(original_name, name),
         name = left(case when v_aantal = 1 then v_artikeltitel else v_titel end, 120),
         offer_id = p_offer,
         offer_choice = jsonb_build_object(
           'titel', v_titel, 'korting', o.discount_text, 'geldig_tot', o.valid_to,
           'supermarkt', o.supermarket, 'artikelen', v_artikelen),
         article_supermarket = case when v_aantal = 1 then v_supermarkt end,
         article_id = case when v_aantal = 1 then v_artikel end
   where id = p_item
  returning * into i;
  return i;
end $$;

-- ---------- Keuze wissen, en terugvallen na afloop ----------
-- Het item heet weer wat er oorspronkelijk stond; aanbieding en artikelen gaan eraf.
create function public.clear_offer_choice(p_item uuid) returns public.items
language plpgsql security definer
set search_path to 'public'
as $$
declare
  i public.items;
begin
  update public.items
     set name = original_name, original_name = null, offer_choice = null, offer_id = null,
         article_supermarket = null, article_id = null
   where id = p_item and original_name is not null and public.is_member(list_id)
  returning * into i;
  if not found then raise exception 'Item niet gevonden'; end if;
  return i;
end $$;

-- De app roept dit aan bij het laden van de lijst. Verlopen is: de laatste geldige dag van de gekozen
-- aanbieding is voorbij (Amsterdamse dagen), of de aanbieding is intussen opgeruimd. save_offers ruimt pas
-- na 28 dagen op, dus de datum uit de keuze is leidend. Geeft terug hoeveel items zijn teruggezet.
create function public.reset_expired_choices(p_list uuid) returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_aantal integer;
begin
  if not public.is_member(p_list) then return 0; end if;
  update public.items
     set name = original_name, original_name = null, offer_choice = null, offer_id = null,
         article_supermarket = null, article_id = null
   where list_id = p_list and original_name is not null
     and (offer_id is null
          or (offer_choice->>'geldig_tot')::date < (now() at time zone 'Europe/Amsterdam')::date);
  get diagnostics v_aantal = row_count;
  return v_aantal;
end $$;

-- ---------- Gekocht ----------
-- Een gekozen aanbieding met artikelen wordt per artikel een aankoop (naam en artikel van het artikel); als
-- geheel gekozen of zonder keuze blijft het één aankoop onder de naam van het item. Geeft het id van (de
-- eerste van) de aankopen.
create or replace function public.buy_item(p_item uuid) returns uuid
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  i public.items;
  v_id uuid;
  v_zoals jsonb;
begin
  delete from public.items where id = p_item and public.is_member(list_id) returning * into i;
  -- Al weg (bijv. de ander was net eerder) of geen lid: niets te doen
  if not found then return null; end if;
  if i.original_name is null then
    insert into public.purchases (list_id, item_id, name, quantity, added_by, item_created_at, bought_by)
    values (i.list_id, i.id, i.name, i.quantity, i.added_by, i.created_at, auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  v_zoals := jsonb_build_object(
    'name', i.name, 'original_name', i.original_name, 'offer_id', i.offer_id, 'offer_choice', i.offer_choice,
    'article_supermarket', i.article_supermarket, 'article_id', i.article_id, 'type_id', i.type_id);
  if jsonb_array_length(coalesce(i.offer_choice->'artikelen', '[]'::jsonb)) = 0 then
    insert into public.purchases (list_id, item_id, name, quantity, added_by, item_created_at, bought_by,
                                  original_name, item_choice)
    values (i.list_id, i.id, i.name, i.quantity, i.added_by, i.created_at, auth.uid(), i.original_name, v_zoals)
    returning id into v_id;
    return v_id;
  end if;
  with nieuw as (
    insert into public.purchases (list_id, item_id, name, quantity, added_by, item_created_at, bought_by,
                                  original_name, item_choice, article_supermarket, article_id)
    select i.list_id, i.id, left(a->>'titel', 120), i.quantity, i.added_by, i.created_at, auth.uid(),
           i.original_name, v_zoals, i.offer_choice->>'supermarkt', a->>'artikel_id'
    from jsonb_array_elements(i.offer_choice->'artikelen') a
    returning id
  )
  select id into v_id from nieuw limit 1;
  return v_id;
end $$;

-- Ongedaan maken: bij een gekozen aanbieding gaan alle aankopen van dat item weg en komt het item terug
-- zoals het was, met de keuze. Is de aanbieding intussen opgeruimd, dan zonder de koppeling ernaar; het
-- item valt dan bij het laden terug op de oorspronkelijke invoer.
create or replace function public.undo_purchase(p_purchase uuid) returns void
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  a public.purchases;
  z jsonb;
begin
  delete from public.purchases where id = p_purchase and public.is_member(list_id) returning * into a;
  if not found then return; end if;
  z := a.item_choice;
  if z is null then
    insert into public.items (id, list_id, name, quantity, added_by, created_at)
    values (coalesce(a.item_id, gen_random_uuid()), a.list_id, a.name, a.quantity, a.added_by,
            coalesce(a.item_created_at, now()))
    on conflict (id) do nothing;
    return;
  end if;
  delete from public.purchases where list_id = a.list_id and item_id = a.item_id and item_choice is not null;
  insert into public.items (id, list_id, name, quantity, added_by, created_at, original_name, offer_choice,
                            offer_id, article_supermarket, article_id, type_id)
  values (coalesce(a.item_id, gen_random_uuid()), a.list_id, z->>'name', a.quantity, a.added_by,
          coalesce(a.item_created_at, now()), z->>'original_name', z->'offer_choice',
          (select o.id from public.offers o where o.id = nullif(z->>'offer_id', '')::uuid),
          z->>'article_supermarket', z->>'article_id',
          (select p.id from public.product_types p where p.id = nullif(z->>'type_id', '')::uuid))
  on conflict (id) do nothing;
end $$;

-- ---------- Het type van een aankoop ----------
-- Als voorheen; de supermarkt bij het artikel komt van de bon of, zonder bon, van de aankoop zelf.
create or replace function public.purchase_types()
returns table (purchase_id uuid, type_id uuid)
language sql stable security definer
set search_path to 'public'
as $$
  select a.id, coalesce(t.type_id, p.id, s.type_id)
  from public.purchases a
  left join public.receipts r on r.id = a.receipt_id
  left join public.article_types t
    on a.article_id is not null and t.article_id = a.article_id
   and upper(t.supermarket) = upper(coalesce(btrim(r.store), a.article_supermarket))
  left join public.product_types p on p.key = public.match_key(a.name)
  left join public.term_synonyms s on s.key = public.match_key(a.name);
$$;

-- ---------- Een bon haalt producten van de lijst ----------
-- Als voorheen; bij een gekozen aanbieding telt voor "hetzelfde type" ook wat er oorspronkelijk stond.
create or replace function public.match_receipt_items(p_list uuid, p_date date, p_names text[])
returns table(regel integer, item_id uuid, name text, zeker boolean)
language sql stable security definer
set search_path to 'public', 'extensions'
as $$
  with bon as (
    select n.regel::integer as regel, n.naam, public.name_type(n.naam) as soort
    from unnest(p_names) with ordinality as n(naam, regel)
    where trim(n.naam) <> ''
  ),
  lijst as (
    select i.id, i.name, i.normalized_name, i.created_at,
           coalesce(public.name_type(i.name), public.name_type(i.original_name)) as soort
    from public.items i
    where i.list_id = p_list
      and public.is_member(p_list)
      and (i.created_at at time zone 'Europe/Amsterdam')::date <= p_date
  ),
  kandidaten as (
    select b.regel, i.id, i.name, i.created_at,
           (i.normalized_name = lower(trim(b.naam)) or (b.soort is not null and b.soort = i.soort)) as zeker,
           greatest(strict_word_similarity(i.normalized_name, lower(trim(b.naam))),
                    strict_word_similarity(lower(trim(b.naam)), i.normalized_name)) as score
    from bon b
    cross join lijst i
  ),
  -- GEVOELIGHEID: dezelfde drempel als bij de aankopen van dezelfde dag (match_receipt_lines)
  per_regel as (
    select distinct on (k.regel) k.* from kandidaten k where k.zeker or k.score >= 0.5
    order by k.regel, k.zeker desc, k.score desc, k.created_at
  )
  -- een item hoort bij hoogstens één bonregel: de best passende
  select distinct on (p.id) p.regel, p.id, p.name, p.zeker from per_regel p order by p.id, p.zeker desc, p.score desc, p.regel;
$$;

-- Als voorheen. Een item met een gekozen aanbieding wordt een aankoop met de oorspronkelijke invoer erbij; is
-- er niet precies één artikel gekozen, dan heet de aankoop naar de bonregel in plaats van naar de aanbieding.
-- De andere regels van de bon worden gewoon eigen aankopen.
CREATE OR REPLACE FUNCTION "public"."save_receipt"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric, "p_lines" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_bon uuid;
  r jsonb;
  v_naam text;
  v_koppel uuid;
  v_item uuid;
  v_artikel text;
  i public.items;
  v_toegevoegd integer := 0;
  v_gekoppeld integer := 0;
  v_overgeslagen integer := 0;
  v_van_lijst integer := 0;
begin
  if not public.is_member(p_list) then raise exception 'Geen lid van deze lijst'; end if;
  if exists (select 1 from public.lists where id = p_list and archived_at is not null) then
    raise exception 'Deze lijst is gearchiveerd';
  end if;
  if nullif(trim(p_store), '') is null then raise exception 'Vul de supermarkt in'; end if;
  if p_date is null then raise exception 'Vul de datum van de bon in'; end if;
  if p_date > (now() at time zone 'Europe/Amsterdam')::date then
    raise exception 'De datum van de bon ligt in de toekomst';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) not between 1 and 200 then
    raise exception 'Een bon heeft 1 tot 200 regels';
  end if;

  insert into public.receipts (list_id, store, receipt_date, total, added_by)
  values (p_list, trim(p_store), p_date, p_total, auth.uid())
  returning id into v_bon;

  for r in select * from jsonb_array_elements(p_lines) loop
    v_naam := trim(r->>'name');
    if v_naam is null or v_naam = '' then continue; end if;
    v_koppel := nullif(r->>'purchase_id', '')::uuid;
    v_item := nullif(r->>'item_id', '')::uuid;
    v_artikel := nullif(trim(r->>'article_id'), '');

    if v_koppel is not null then
      update public.purchases
        set receipt_id = v_bon,
            receipt_name = nullif(trim(r->>'receipt_name'), ''),
            price = (r->>'price')::numeric,
            discount = (r->>'discount')::numeric,
            article_id = v_artikel,
            quantity = coalesce(quantity, nullif(trim(r->>'quantity'), ''))
        where id = v_koppel and list_id = p_list and receipt_id is null
          and (bought_at at time zone 'Europe/Amsterdam')::date = p_date;
      if found then v_gekoppeld := v_gekoppeld + 1; else v_overgeslagen := v_overgeslagen + 1; end if;
      continue;
    end if;

    if v_item is not null then
      -- Alleen een item dat op of voor de bondatum op de lijst is gezet: later toegevoegd is opnieuw nodig
      delete from public.items
        where id = v_item and list_id = p_list
          and (created_at at time zone 'Europe/Amsterdam')::date <= p_date
        returning * into i;
      if found then
        insert into public.purchases (list_id, item_id, name, quantity, added_by, item_created_at, bought_by, bought_at,
                                      receipt_id, receipt_name, price, discount, article_id, original_name)
        values (p_list, i.id,
                case when i.original_name is not null and i.article_id is null then v_naam else i.name end,
                coalesce(i.quantity, nullif(trim(r->>'quantity'), '')), i.added_by, i.created_at,
                auth.uid(), (p_date + time '12:00') at time zone 'Europe/Amsterdam',
                v_bon, nullif(trim(r->>'receipt_name'), ''), (r->>'price')::numeric, (r->>'discount')::numeric, v_artikel,
                i.original_name);
        v_van_lijst := v_van_lijst + 1;
        continue;
      end if;
      -- Item al weg (bijv. de ander was net eerder): de regel gaat verder als een gewone bonregel
    end if;

    if exists (
      select 1 from public.purchases
      where list_id = p_list and normalized_name = lower(v_naam)
        and (bought_at at time zone 'Europe/Amsterdam')::date = p_date
        -- een ander artikel-ID is een ander artikel; zonder ID aan een van beide kanten telt alleen de naam
        and (article_id is null or v_artikel is null or article_id = v_artikel)
    ) then
      v_overgeslagen := v_overgeslagen + 1;
    else
      -- geen tijd op de bon: midden op de dag, zodat de datum in elke tijdzone klopt
      insert into public.purchases (list_id, name, quantity, bought_by, bought_at, receipt_id, receipt_name, price, discount,
                                    article_id)
      values (p_list, v_naam, nullif(trim(r->>'quantity'), ''), auth.uid(),
              (p_date + time '12:00') at time zone 'Europe/Amsterdam',
              v_bon, nullif(trim(r->>'receipt_name'), ''), (r->>'price')::numeric, (r->>'discount')::numeric, v_artikel);
      v_toegevoegd := v_toegevoegd + 1;
    end if;
  end loop;

  -- Niets toegevoegd of gekoppeld: dan ook geen lege bon bewaren
  if v_toegevoegd + v_gekoppeld + v_van_lijst = 0 then delete from public.receipts where id = v_bon; end if;

  return jsonb_build_object('toegevoegd', v_toegevoegd, 'gekoppeld', v_gekoppeld, 'overgeslagen', v_overgeslagen,
                            'van_lijst', v_van_lijst);
end $$;

-- ---------- Bonus-label en bonuspaneel ----------
-- Als voorheen, met één verschil: een item met een gekozen aanbieding telt alleen nog via die aanbieding
-- (items.offer_id). De route via de naam vervalt daar, want de naam is nu die van het artikel of de aanbieding.
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
    where i.list_id = p_list and public.is_member(p_list) and i.original_name is null
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

-- gekozen zegt dat het item deze aanbieding als keuze heeft. De variant komt dan van wat er oorspronkelijk stond.
create or replace function public.offer_details_for_list(p_list uuid) returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket, o.title, o.discount_text, o.valid_to
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  ding as (
    select i.id, i.name, i.offer_id, i.created_at, i.original_name is not null as gekozen,
           public.term_variant(coalesce(i.original_name, i.name)) as variant
    from public.items i
    where i.list_id = p_list and public.is_member(p_list)
  ),
  treffer as (
    select d.id as item, g.id as offer, oa.supermarket, oa.article_id
    from ding d
    cross join lateral public.term_articles(d.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
    where not d.gekozen
    union
    select d.id, g.id, oa.supermarket, oa.article_id
    from ding d
    join geldig g on g.id = d.offer_id
    left join public.offer_articles oa on oa.offer_id = g.id
  ),
  artikel as (
    select t.item, t.offer, x.article_id, x.title,
           coalesce(d.variant = a.variant_stem, false) as zelfde
    from treffer t
    join ding d on d.id = t.item
    left join public.articles x on x.supermarket = t.supermarket and x.article_id = t.article_id
    left join public.article_types a on a.supermarket = x.supermarket and a.article_id = x.article_id
  ),
  per as (
    select k.item, k.offer, count(k.article_id)::integer as totaal,
           (count(*) filter (where k.zelfde))::integer as zelfde,
           -- AANTAL TITELS: zoveel artikelen worden hooguit bij naam genoemd
           coalesce((array_agg(k.title order by k.zelfde desc, k.title) filter (where k.article_id is not null))[1:6], '{}') as artikelen
    from artikel k
    group by k.item, k.offer
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', p.item, 'id', g.id, 'supermarkt', g.supermarket, 'titel', g.title,
           'korting', g.discount_text, 'geldig_tot', g.valid_to,
           'artikelen', to_jsonb(p.artikelen), 'artikelen_totaal', p.totaal, 'artikelen_zelfde', p.zelfde,
           'gekozen', d.gekozen)
         order by d.created_at, d.id, (p.zelfde > 0) desc, g.title, g.id), '[]'::jsonb)
  from per p
  join geldig g on g.id = p.offer
  join ding d on d.id = p.item
  where public.is_member(p_list);
$$;

-- ---------- Rechten ----------
revoke all on function public.offer_choice_options(uuid, uuid) from public, anon;
revoke all on function public.choose_offer(uuid, uuid, text[]) from public, anon;
revoke all on function public.clear_offer_choice(uuid) from public, anon;
revoke all on function public.reset_expired_choices(uuid) from public, anon;
grant execute on function public.offer_choice_options(uuid, uuid) to authenticated, service_role;
grant execute on function public.choose_offer(uuid, uuid, text[]) to authenticated, service_role;
grant execute on function public.clear_offer_choice(uuid) to authenticated, service_role;
grant execute on function public.reset_expired_choices(uuid) to authenticated, service_role;
