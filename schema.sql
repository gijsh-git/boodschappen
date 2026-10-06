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
create policy "leden voegen items toe" on public.items for insert with check (public.is_member(list_id));
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

-- Lijst verwijderen (alleen de maker); items en leden gaan mee via on delete cascade
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

-- Realtime aanzetten voor items en voor leden (wie sluit aan, wie is verwijderd)
alter publication supabase_realtime add table public.items;
alter publication supabase_realtime add table public.list_members;

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

-- Leden mogen lezen. Er zijn bewust geen policies om te schrijven:
-- dat gaat alleen via buy_item en undo_purchase.
revoke all on public.purchases from anon, authenticated;
grant select on public.purchases to authenticated;
create policy "leden zien aankopen" on public.purchases for select using (public.is_member(list_id));

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
