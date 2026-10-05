-- Boodschappenlijst: database-schema voor Supabase
-- Uitvoeren in Supabase: SQL Editor > New query > plakken > Run

create extension if not exists pgcrypto;

create table public.lists (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
  created_by uuid not null default auth.uid(),
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
  checked boolean not null default false,
  checked_at timestamptz,
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

-- Realtime aanzetten voor items
alter publication supabase_realtime add table public.items;

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
