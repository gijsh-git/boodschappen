-- Boodschappenlijst: database-schema voor Supabase
-- Uitvoeren in Supabase: SQL Editor > New query > plakken > Run

create extension if not exists pgcrypto;

create table public.lists (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
  created_by uuid not null default auth.uid(),
  -- telt deze lijst mee voor het aankoopprofiel? (uit voor bijv. een feestlijst)
  counts_for_profile boolean not null default true,
  -- gearchiveerd sinds; leeg = actieve lijst. Een gearchiveerde lijst staat niet meer in het
  -- overzicht en er kan niets meer bij, maar de aankopen en bonnen blijven bestaan.
  archived_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.list_members (
  list_id uuid not null references public.lists(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  joined_at timestamptz not null default now(),
  primary key (list_id, user_id)
);

create table public.items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists(id) on delete cascade,
  name text not null,
  -- genormaliseerde naam (kleine letters, getrimd): basis voor later koppelen aan kortingen
  normalized_name text generated always as (lower(trim(name))) stored,
  quantity text,
  added_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create index items_list_idx on public.items(list_id);
create index items_normalized_idx on public.items(normalized_name);

-- Hulpfunctie: is de ingelogde gebruiker lid van deze lijst?
create or replace function public.is_member(p_list uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.list_members where list_id = p_list and user_id = auth.uid());
$$;

alter table public.lists enable row level security;
alter table public.list_members enable row level security;
alter table public.items enable row level security;

create policy "leden zien lijst" on public.lists for select using (public.is_member(id));
create policy "leden zien leden" on public.list_members for select using (public.is_member(list_id));
create policy "leden zien items" on public.items for select using (public.is_member(list_id));
-- Aan een gearchiveerde lijst kan niets meer worden toegevoegd
create policy "leden voegen items toe" on public.items for insert with check (
  public.is_member(list_id)
  and exists (select 1 from public.lists l where l.id = items.list_id and l.archived_at is null)
);
create policy "leden wijzigen items" on public.items for update using (public.is_member(list_id));
create policy "leden verwijderen items" on public.items for delete using (public.is_member(list_id));

-- Nieuwe lijst aanmaken (maker wordt direct lid)
create or replace function public.create_list(p_name text)
returns public.lists language plpgsql security definer set search_path = public as $$
declare l public.lists;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  insert into public.lists (name, created_by) values (p_name, auth.uid()) returning * into l;
  insert into public.list_members (list_id, user_id) values (l.id, auth.uid());
  return l;
end $$;

-- Aansluiten bij een lijst met de uitnodigingscode
create or replace function public.join_list(p_code text)
returns public.lists language plpgsql security definer set search_path = public as $$
declare l public.lists;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  select * into l from public.lists where invite_code = lower(trim(p_code));
  if not found then raise exception 'Code niet gevonden'; end if;
  if l.archived_at is not null then raise exception 'Deze lijst is gearchiveerd'; end if;
  insert into public.list_members (list_id, user_id) values (l.id, auth.uid()) on conflict do nothing;
  return l;
end $$;

-- Instellen of een lijst meetelt voor het aankoopprofiel (alleen leden)
create or replace function public.set_list_profile(p_list uuid, p_counts boolean)
returns public.lists language plpgsql security definer set search_path = public as $$
declare l public.lists;
begin
  if not public.is_member(p_list) then raise exception 'Geen lid van deze lijst'; end if;
  update public.lists set counts_for_profile = p_counts where id = p_list returning * into l;
  return l;
end $$;

-- Lijst archiveren of terugzetten (alleen de maker). Dit is de gewone weg: de aankopen en bonnen,
-- de basis van het aankoopprofiel, blijven dan bestaan.
create or replace function public.archive_list(p_list uuid, p_archived boolean)
returns public.lists language plpgsql security definer set search_path = public as $$
declare l public.lists;
begin
  update public.lists
    set archived_at = case when p_archived then coalesce(archived_at, now()) end
    where id = p_list and created_by = auth.uid() returning * into l;
  if not found then raise exception 'Alleen de maker kan deze lijst archiveren of terugzetten'; end if;
  return l;
end $$;

-- Lijst definitief verwijderen (alleen de maker); items, leden, aankopen en bonnen gaan mee
-- via on delete cascade. De app waarschuwt daarvoor en wijst op archiveren.
create or replace function public.delete_list(p_list uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.lists where id = p_list and created_by = auth.uid();
  if not found then raise exception 'Alleen de maker kan deze lijst verwijderen'; end if;
end $$;

-- Deelnemer verwijderen (alleen de maker). Daarna krijgt de lijst een nieuwe code,
-- anders kan de verwijderde persoon met de oude code zo weer aansluiten.
create or replace function public.remove_member(p_list uuid, p_user uuid)
returns public.lists language plpgsql security definer set search_path = public as $$
declare l public.lists;
begin
  if not exists (select 1 from public.lists where id = p_list and created_by = auth.uid()) then
    raise exception 'Alleen de maker kan deelnemers verwijderen';
  end if;
  if p_user = auth.uid() then raise exception 'Je kunt jezelf niet uit je eigen lijst verwijderen'; end if;
  delete from public.list_members where list_id = p_list and user_id = p_user;
  update public.lists
    set invite_code = substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)
    where id = p_list returning * into l;
  return l;
end $$;

-- Realtime aanzetten voor items, voor leden (wie sluit aan, wie is verwijderd)
-- en voor lijsten (de maker archiveert de lijst terwijl de ander hem open heeft)
alter publication supabase_realtime add table public.items;
alter publication supabase_realtime add table public.list_members;
alter publication supabase_realtime add table public.lists;

-- Profiel per gebruiker: de weergavenaam die andere lijstleden te zien krijgen
create table public.profiles (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 40),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

grant select, insert, update on public.profiles to authenticated;

-- Je ziet je eigen profiel en dat van mensen met wie je een lijst deelt
create policy "eigen profiel en lijstgenoten zien" on public.profiles for select using (
  user_id = auth.uid()
  or exists (
    select 1 from public.list_members m
    where m.user_id = profiles.user_id and public.is_member(m.list_id)
  )
);
create policy "eigen profiel aanmaken" on public.profiles for insert with check (user_id = auth.uid());
create policy "eigen profiel wijzigen" on public.profiles for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- Aanbiedingen ----------
-- pg_trgm: tekst vergelijken op gelijkenis (voor het zoeken van aanbiedingen bij een item)
create extension if not exists pg_trgm with schema extensions;

-- Aanbiedingen van supermarkten. Voor nu handmatige testgegevens (zie seed_deals.sql).
create table public.deals (
  id uuid primary key default gen_random_uuid(),
  supermarkt text not null check (supermarkt in ('AH', 'PLUS')),
  productnaam text not null,
  -- omschrijving van de korting, bijv. "2e halve prijs"
  omschrijving text not null,
  -- prijs in euro's, indien bekend
  prijs numeric(6,2),
  geldig_van date not null,
  geldig_tot date not null,
  created_at timestamptz not null default now(),
  check (geldig_tot >= geldig_van)
);

alter table public.deals enable row level security;

-- Iedereen die is ingelogd mag lezen. Er zijn bewust geen policies om te schrijven:
-- dat kan alleen met de service role (die slaat RLS over), niet vanuit de app.
revoke all on public.deals from anon, authenticated;
grant select on public.deals to authenticated;
create policy "ingelogden lezen deals" on public.deals for select to authenticated using (true);

-- Per item van een lijst: bij welke supermarkt is er nu een aanbieding, en hoeveel?
-- Het zoeken gebeurt hier, zodat de app nooit alle deals hoeft op te halen.
-- security invoker: de RLS op items zorgt dat je alleen je eigen lijsten kunt opvragen.
create or replace function public.deals_for_list(p_list uuid)
returns table (item_id uuid, supermarkt text, aantal integer)
language sql stable security invoker set search_path = public, extensions as $$
  select i.id, d.supermarkt, count(*)::integer
  from public.items i
  join public.deals d
    -- GEVOELIGHEID: de itemnaam moet voor minstens 0.5 (schaal 0-1) lijken op een of meer
    -- hele woorden uit de productnaam. Lager = meer (lossere) matches, hoger = strenger.
    on strict_word_similarity(i.normalized_name, lower(d.productnaam)) >= 0.5
  where i.list_id = p_list
    and (now() at time zone 'Europe/Amsterdam')::date between d.geldig_van and d.geldig_tot
  group by i.id, d.supermarkt;
$$;

-- ---------- Aankopen ----------
-- Wat er echt gekocht is: basis voor het aankoopprofiel. Een item dat als gekocht wordt
-- gemarkeerd verdwijnt uit items en komt hier terecht (alleen bij lijsten die meetellen).
create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists(id) on delete cascade,
  -- gegevens van het oorspronkelijke item, zodat "ongedaan maken" het exact kan terugzetten
  item_id uuid,
  name text not null,
  normalized_name text generated always as (lower(trim(name))) stored,
  quantity text,
  added_by uuid,
  item_created_at timestamptz,
  -- wie het kocht; leeg bij aankopen die zijn omgezet uit oude afgestreepte items
  bought_by uuid default auth.uid(),
  bought_at timestamptz not null default now()
);

create index purchases_list_idx on public.purchases(list_id, bought_at desc);

alter table public.purchases enable row level security;

-- Leden mogen lezen en een aankoop verwijderen (bijv. bij een vergissing). Toevoegen en wijzigen
-- kan bewust niet rechtstreeks: dat gaat alleen via buy_item en undo_purchase.
revoke all on public.purchases from anon, authenticated;
grant select, delete on public.purchases to authenticated;
create policy "leden zien aankopen" on public.purchases for select using (public.is_member(list_id));
create policy "leden verwijderen aankopen" on public.purchases for delete using (public.is_member(list_id));

-- Item als gekocht markeren: het item verdwijnt van de lijst en wordt, als de lijst meetelt
-- voor het aankoopprofiel, bewaard als aankoop. Alles in één keer, zodat het niet half kan lukken.
-- Geeft de id van de aankoop terug (null als er geen aankoop is gemaakt).
create or replace function public.buy_item(p_item uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  i public.items;
  v_id uuid;
begin
  delete from public.items where id = p_item and public.is_member(list_id) returning * into i;
  -- Al weg (bijv. de ander was net eerder) of geen lid: niets te doen
  if not found then return null; end if;
  if exists (select 1 from public.lists where id = i.list_id and counts_for_profile) then
    insert into public.purchases (list_id, item_id, name, quantity, added_by, item_created_at, bought_by)
    values (i.list_id, i.id, i.name, i.quantity, i.added_by, i.created_at, auth.uid())
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- Aankoop ongedaan maken: de aankoop verdwijnt en het item staat weer op de lijst
create or replace function public.undo_purchase(p_purchase uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.purchases;
begin
  delete from public.purchases where id = p_purchase and public.is_member(list_id) returning * into a;
  if not found then return; end if;
  insert into public.items (id, list_id, name, quantity, added_by, created_at)
  values (coalesce(a.item_id, gen_random_uuid()), a.list_id, a.name, a.quantity, a.added_by,
          coalesce(a.item_created_at, now()))
  on conflict (id) do nothing;
end $$;

alter publication supabase_realtime add table public.purchases;

-- ---------- Kassabonnen ----------
-- Een gescande kassabon. De regels van de bon staan als aankopen in purchases (receipt_id);
-- deze tabel is er om dubbele bonnen te herkennen (zelfde supermarkt, datum en totaal).
-- De foto zelf wordt nergens bewaard.
create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists(id) on delete cascade,
  store text not null,
  receipt_date date not null,
  total numeric(8,2),
  added_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create index receipts_list_idx on public.receipts(list_id, receipt_date);

alter table public.receipts enable row level security;

-- Leden mogen lezen; schrijven kan alleen via save_receipt
revoke all on public.receipts from anon, authenticated;
grant select on public.receipts to authenticated;
create policy "leden zien bonnen" on public.receipts for select using (public.is_member(list_id));

-- Bongegevens bij een aankoop: van welke bon, de naam zoals op de bon, regelprijs en korting
alter table public.purchases
  add column receipt_id uuid references public.receipts(id) on delete set null,
  add column receipt_name text,
  add column price numeric(8,2),
  add column discount numeric(8,2);

create index purchases_receipt_idx on public.purchases(receipt_id);

-- Is deze bon al eens toegevoegd? Een bon waarvan alle aankopen weer zijn verwijderd telt niet mee.
create or replace function public.receipt_exists(p_list uuid, p_store text, p_date date, p_total numeric)
returns boolean language sql stable security invoker set search_path = public as $$
  select exists (
    select 1 from public.receipts r
    where r.list_id = p_list
      and lower(r.store) = lower(trim(p_store))
      and r.receipt_date = p_date
      and r.total is not distinct from p_total
      and exists (select 1 from public.purchases a where a.receipt_id = r.id)
  );
$$;

-- Per bonregel (volgnummer in p_names, vanaf 1): de aankoop van dezelfde dag die er het meest op lijkt.
-- Zo telt een product dat al via de lijst als gekocht is gemarkeerd niet dubbel.
-- has_receipt: die aankoop heeft al bongegevens (van een andere bon op dezelfde dag).
-- security invoker: de RLS op purchases zorgt dat je alleen je eigen lijsten kunt opvragen.
create or replace function public.match_receipt_lines(p_list uuid, p_date date, p_names text[])
returns table (regel integer, purchase_id uuid, name text, has_receipt boolean)
language sql stable security invoker set search_path = public, extensions as $$
  with kandidaten as (
    select n.regel::integer as regel, a.id, a.name, a.receipt_id is not null as has_receipt,
           -- in beide richtingen: "kaas" op de lijst past in "jong belegen kaas plakken" op de bon, en andersom
           greatest(strict_word_similarity(a.normalized_name, lower(trim(n.naam))),
                    strict_word_similarity(lower(trim(n.naam)), a.normalized_name)) as score
    from unnest(p_names) with ordinality as n(naam, regel)
    join public.purchases a
      on a.list_id = p_list
     and (a.bought_at at time zone 'Europe/Amsterdam')::date = p_date
  ),
  -- GEVOELIGHEID: dezelfde drempel als bij de aanbiedingen (deals_for_list)
  per_regel as (
    select distinct on (k.regel) k.* from kandidaten k where k.score >= 0.5 order by k.regel, k.score desc
  )
  -- een aankoop hoort bij hoogstens één bonregel: de best passende
  select distinct on (p.id) p.regel, p.id, p.name, p.has_receipt from per_regel p order by p.id, p.score desc;
$$;

-- Bon opslaan: de regels worden aankopen met de bondatum als aankoopdatum. Alles in één keer.
-- p_lines: [{ name, receipt_name, quantity, price, discount, purchase_id }]
-- Een product telt per dag één keer:
--   - met purchase_id: de bestaande aankoop van die dag krijgt de bongegevens erbij (geen nieuwe rij);
--     heeft die al bongegevens, dan wordt de regel overgeslagen
--   - zonder purchase_id: nieuwe aankoop, behalve als er die dag al een met exact dezelfde naam is
-- Geeft terug hoeveel regels zijn toegevoegd, gekoppeld en overgeslagen.
create or replace function public.save_receipt(p_list uuid, p_store text, p_date date, p_total numeric, p_lines jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_bon uuid;
  r jsonb;
  v_naam text;
  v_koppel uuid;
  v_toegevoegd integer := 0;
  v_gekoppeld integer := 0;
  v_overgeslagen integer := 0;
begin
  if not public.is_member(p_list) then raise exception 'Geen lid van deze lijst'; end if;
  if not exists (select 1 from public.lists where id = p_list and counts_for_profile) then
    raise exception 'Deze lijst telt niet mee voor het aankoopprofiel';
  end if;
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

    if v_koppel is not null then
      update public.purchases
        set receipt_id = v_bon,
            receipt_name = nullif(trim(r->>'receipt_name'), ''),
            price = (r->>'price')::numeric,
            discount = (r->>'discount')::numeric,
            quantity = coalesce(quantity, nullif(trim(r->>'quantity'), ''))
        where id = v_koppel and list_id = p_list and receipt_id is null
          and (bought_at at time zone 'Europe/Amsterdam')::date = p_date;
      if found then v_gekoppeld := v_gekoppeld + 1; else v_overgeslagen := v_overgeslagen + 1; end if;
    elsif exists (
      select 1 from public.purchases
      where list_id = p_list and normalized_name = lower(v_naam)
        and (bought_at at time zone 'Europe/Amsterdam')::date = p_date
    ) then
      v_overgeslagen := v_overgeslagen + 1;
    else
      -- geen tijd op de bon: midden op de dag, zodat de datum in elke tijdzone klopt
      insert into public.purchases (list_id, name, quantity, bought_by, bought_at, receipt_id, receipt_name, price, discount)
      values (p_list, v_naam, nullif(trim(r->>'quantity'), ''), auth.uid(),
              (p_date + time '12:00') at time zone 'Europe/Amsterdam',
              v_bon, nullif(trim(r->>'receipt_name'), ''), (r->>'price')::numeric, (r->>'discount')::numeric);
      v_toegevoegd := v_toegevoegd + 1;
    end if;
  end loop;

  -- Niets toegevoegd of gekoppeld: dan ook geen lege bon bewaren
  if v_toegevoegd + v_gekoppeld = 0 then delete from public.receipts where id = v_bon; end if;

  return jsonb_build_object('toegevoegd', v_toegevoegd, 'gekoppeld', v_gekoppeld, 'overgeslagen', v_overgeslagen);
end $$;

-- Bon verwijderen (alleen leden van de lijst). Aankopen die alleen van deze bon kwamen (geen item
-- van de lijst) gaan mee weg; een aankoop die al via de lijst als gekocht was gemarkeerd blijft
-- staan en raakt alleen de bongegevens kwijt.
create or replace function public.delete_receipt(p_receipt uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.receipts where id = p_receipt and public.is_member(list_id)) then
    raise exception 'Bon niet gevonden';
  end if;
  delete from public.purchases where receipt_id = p_receipt and item_id is null;
  update public.purchases
    set receipt_id = null, receipt_name = null, price = null, discount = null
    where receipt_id = p_receipt;
  delete from public.receipts where id = p_receipt;
end $$;

-- ---------- Producten ----------
-- Eén product voor alle schrijfwijzen van hetzelfde ("halfvolle melk", "ah halfvolle melk 1l").
-- De koppeling loopt via de genormaliseerde naam: items en aankopen houden hun eigen naam en
-- verwijzen nergens naar een product. Samenvoegen verandert dus alleen product_aliases.

-- Beheerders: alleen zij mogen producten samenvoegen, losmaken en hernoemen.
-- Vul deze tabel zelf in de SQL Editor:
--   insert into public.admins (user_id) select id from auth.users where email = 'JOUW-EMAILADRES';
create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

-- Hulpfunctie: is de ingelogde gebruiker beheerder?
create or replace function public.is_admin()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

-- Elke genormaliseerde naam hoort bij precies één product
create table public.product_aliases (
  normalized_name text primary key,
  product_id uuid not null references public.products(id),
  created_at timestamptz not null default now()
);

create index product_aliases_product_idx on public.product_aliases(product_id);
create index purchases_normalized_idx on public.purchases(normalized_name);

-- Logboek van samenvoegingen: het bronproduct verdwijnt, hier staat wat er nodig is om het
-- precies terug te zetten. Bewust zonder verwijzing naar products: de regel blijft bestaan
-- als het doel later zelf wordt samengevoegd.
create table public.product_merges (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null,
  source_id uuid not null,
  source_name text not null,
  -- de namen die van het bronproduct naar het doel zijn verhuisd
  aliases text[] not null,
  merged_by uuid,
  merged_at timestamptz not null default now(),
  undone_by uuid,
  undone_at timestamptz
);

create index product_merges_target_idx on public.product_merges(target_id);

alter table public.products enable row level security;
alter table public.product_aliases enable row level security;
alter table public.product_merges enable row level security;

-- Alleen lezen; schrijven kan alleen via de functies hieronder
revoke all on public.products, public.product_aliases, public.product_merges from anon, authenticated;
grant select on public.products, public.product_aliases, public.product_merges to authenticated;

-- Een naam zie je alleen als die voorkomt op een lijst waar je lid van bent (de RLS op items en
-- purchases regelt dat in de subquery's); de beheerder ziet alles.
create policy "beheerder en lijstleden zien namen" on public.product_aliases for select to authenticated using (
  public.is_admin()
  or exists (select 1 from public.purchases a where a.normalized_name = product_aliases.normalized_name)
  or exists (select 1 from public.items i where i.normalized_name = product_aliases.normalized_name)
);
-- Een product zie je als je een van zijn namen mag zien
create policy "beheerder en lijstleden zien producten" on public.products for select to authenticated using (
  public.is_admin()
  or exists (select 1 from public.product_aliases a where a.product_id = products.id)
);
create policy "beheerder ziet samenvoegingen" on public.product_merges for select to authenticated
  using (public.is_admin());

-- Een naam die nog niet bekend is wordt vanzelf een eigen product. Draait bij elk nieuw of
-- hernoemd item en elke nieuwe aankoop, dus ook voor bonregels.
create or replace function public.ensure_product()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if new.normalized_name = ''
     or exists (select 1 from public.product_aliases where normalized_name = new.normalized_name) then
    return new;
  end if;
  insert into public.products (name) values (new.normalized_name) returning id into v_id;
  insert into public.product_aliases (normalized_name, product_id) values (new.normalized_name, v_id)
    on conflict (normalized_name) do nothing;
  -- een ander was net eerder met dezelfde naam: het losse product weer weg
  if not found then delete from public.products where id = v_id; end if;
  return new;
end $$;

create trigger items_product after insert or update of name on public.items
  for each row execute function public.ensure_product();
create trigger purchases_product after insert or update of name on public.purchases
  for each row execute function public.ensure_product();

-- Samenvoegen zonder rolcontrole: alle namen van p_source verhuizen naar p_target en p_source
-- verdwijnt. Niet aan te roepen vanuit de app; alleen via merge_products en vanuit de SQL Editor.
-- Geeft de id van de regel in het logboek terug.
create or replace function public.merge_products_internal(p_source uuid, p_target uuid, p_by uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_naam text;
  v_namen text[];
  v_id uuid;
begin
  if p_source = p_target then raise exception 'Kies twee verschillende producten'; end if;
  select name into v_naam from public.products where id = p_source for update;
  if not found then raise exception 'Product niet gevonden'; end if;
  if not exists (select 1 from public.products where id = p_target) then
    raise exception 'Product niet gevonden';
  end if;
  select coalesce(array_agg(normalized_name order by normalized_name), '{}') into v_namen
    from public.product_aliases where product_id = p_source;
  insert into public.product_merges (target_id, source_id, source_name, aliases, merged_by)
    values (p_target, p_source, v_naam, v_namen, p_by) returning id into v_id;
  update public.product_aliases set product_id = p_target where product_id = p_source;
  delete from public.products where id = p_source;
  return v_id;
end $$;

revoke execute on function public.merge_products_internal(uuid, uuid, uuid) from public, anon, authenticated;

-- Twee producten samenvoegen (alleen de beheerder); de naam van p_target blijft
create or replace function public.merge_products(p_source uuid, p_target uuid)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan producten samenvoegen'; end if;
  return public.merge_products_internal(p_source, p_target, auth.uid());
end $$;

-- Samenvoeging losmaken (alleen de beheerder): het bronproduct komt terug met dezelfde id en naam
-- en krijgt zijn namen terug. Is het doel daarna zelf samengevoegd, dan moet die eerst los.
create or replace function public.undo_merge(p_merge uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  m public.product_merges;
  v_aantal integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan producten losmaken'; end if;
  select * into m from public.product_merges where id = p_merge and undone_at is null for update;
  if not found then raise exception 'Samenvoeging niet gevonden'; end if;
  if not exists (select 1 from public.products where id = m.target_id) then
    raise exception 'Maak eerst de latere samenvoeging los';
  end if;
  insert into public.products (id, name) values (m.source_id, m.source_name);
  update public.product_aliases set product_id = m.source_id
    where normalized_name = any(m.aliases) and product_id = m.target_id;
  get diagnostics v_aantal = row_count;
  if v_aantal <> cardinality(m.aliases) then raise exception 'Maak eerst de latere samenvoeging los'; end if;
  update public.product_merges set undone_at = now(), undone_by = auth.uid() where id = p_merge;
end $$;

-- Product hernoemen (alleen de beheerder)
create or replace function public.rename_product(p_product uuid, p_name text)
returns public.products language plpgsql security definer set search_path = public as $$
declare p public.products;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan producten hernoemen'; end if;
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 80 then
    raise exception 'Een productnaam heeft 1 tot 80 tekens';
  end if;
  update public.products set name = trim(p_name) where id = p_product returning * into p;
  if not found then raise exception 'Product niet gevonden'; end if;
  return p;
end $$;

-- Alle producten met hun namen en het aantal aankopen over alle lijsten, voor het scherm
-- "Producten" (alleen de beheerder; anderen krijgen een lege lijst). Als één json-lijst,
-- zodat de grens van 1000 rijen per antwoord niet meespeelt.
create or replace function public.product_overview()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'namen', t.namen, 'aankopen', t.aankopen)
                            order by lower(t.name), t.id), '[]'::jsonb)
  from (
    select p.id, p.name,
           coalesce(array_agg(a.normalized_name order by a.normalized_name) filter (where a.normalized_name is not null), '{}') as namen,
           coalesce(sum(c.aantal), 0)::integer as aankopen
    from public.products p
    left join public.product_aliases a on a.product_id = p.id
    left join (
      select normalized_name, count(*) as aantal from public.purchases group by normalized_name
    ) c on c.normalized_name = a.normalized_name
    where public.is_admin()
    group by p.id
  ) t;
$$;
