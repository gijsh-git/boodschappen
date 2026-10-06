-- Uitnodigen met een link in plaats van een vaste code, en beheerders per lijst.
--
-- Was: elke lijst had één vaste code (lists.invite_code) die alle leden konden zien en doorgeven.
-- Wordt: alleen de maker en de beheerders van een lijst kunnen iemand uitnodigen. Elke uitnodiging is
-- een eigen link, geldig voor één persoon en 7 dagen. De maker wijst beheerders aan.

-- ---------- Beheerders ----------
-- Een beheerder mag uitnodigen. Verwijderen, archiveren en beheerders aanwijzen blijft bij de maker.
alter table public.list_members add column is_manager boolean not null default false;

-- ---------- Uitnodigingen ----------
-- Geen policies en geen rechten voor de app: lezen en schrijven gaat alleen via de functies hieronder,
-- zodat een gewoon lid geen uitnodiging kan zien of maken.
create table public.list_invites (
  token text primary key default replace(gen_random_uuid()::text, '-', ''),
  list_id uuid not null references public.lists(id) on delete cascade,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create index list_invites_list_id_idx on public.list_invites (list_id);
alter table public.list_invites enable row level security;
revoke all on table public.list_invites from public, anon, authenticated;

-- Mag de ingelogde gebruiker voor deze lijst uitnodigen? De maker altijd, verder de beheerders.
create or replace function public.can_invite(p_list uuid) returns boolean
    language sql stable security definer
    set search_path to 'public'
    as $$
  select exists (select 1 from public.lists l where l.id = p_list and l.created_by = auth.uid())
      or exists (select 1 from public.list_members m
                 where m.list_id = p_list and m.user_id = auth.uid() and m.is_manager);
$$;
revoke all on function public.can_invite(uuid) from public, anon;
grant execute on function public.can_invite(uuid) to authenticated, service_role;

-- Maakt een uitnodiging en geeft de code terug die in de link komt
create or replace function public.create_invite(p_list uuid) returns text
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare t text;
begin
  if not public.can_invite(p_list) then
    raise exception 'Alleen de maker en de beheerders van de lijst kunnen iemand uitnodigen';
  end if;
  if exists (select 1 from public.lists where id = p_list and archived_at is not null) then
    raise exception 'Deze lijst is gearchiveerd';
  end if;
  -- Verlopen uitnodigingen van deze lijst opruimen
  delete from public.list_invites where list_id = p_list and expires_at < now();
  insert into public.list_invites (list_id) values (p_list) returning token into t;
  return t;
end $$;
revoke all on function public.create_invite(uuid) from public, anon;
grant execute on function public.create_invite(uuid) to authenticated, service_role;

-- Aansluiten met de code uit een uitnodigingslink. De uitnodiging vervalt zodra iemand ermee is aangesloten.
create or replace function public.join_list(p_code text) returns public.lists
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  u public.list_invites;
  l public.lists;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  select * into u from public.list_invites where token = lower(trim(p_code)) for update;
  if not found or u.expires_at < now() then
    raise exception 'Deze uitnodiging is niet (meer) geldig. Vraag een nieuwe link.';
  end if;
  select * into l from public.lists where id = u.list_id;
  if l.archived_at is not null then raise exception 'Deze lijst is gearchiveerd'; end if;
  -- Wie al lid is verbruikt de uitnodiging niet
  if exists (select 1 from public.list_members where list_id = l.id and user_id = auth.uid()) then
    return l;
  end if;
  insert into public.list_members (list_id, user_id) values (l.id, auth.uid());
  delete from public.list_invites where token = u.token;
  return l;
end $$;

-- De maker wijst een beheerder aan of trekt dat weer in
create or replace function public.set_member_manager(p_list uuid, p_user uuid, p_manager boolean) returns void
    language plpgsql security definer
    set search_path to 'public'
    as $$
begin
  if not exists (select 1 from public.lists where id = p_list and created_by = auth.uid()) then
    raise exception 'Alleen de maker kan beheerders aanwijzen';
  end if;
  if p_user = auth.uid() then raise exception 'De maker is altijd beheerder'; end if;
  update public.list_members set is_manager = p_manager where list_id = p_list and user_id = p_user;
  if not found then raise exception 'Deze persoon is geen deelnemer van de lijst'; end if;
  -- Geen beheerder meer: de uitnodigingen die diegene nog had openstaan vervallen
  if not p_manager then
    delete from public.list_invites where list_id = p_list and created_by = p_user;
  end if;
end $$;
revoke all on function public.set_member_manager(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_member_manager(uuid, uuid, boolean) to authenticated, service_role;

-- Verwijderen: de code vernieuwen hoeft niet meer; wel vervallen de uitnodigingen van de verwijderde persoon
create or replace function public.remove_member(p_list uuid, p_user uuid) returns public.lists
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare l public.lists;
begin
  if not exists (select 1 from public.lists where id = p_list and created_by = auth.uid()) then
    raise exception 'Alleen de maker kan deelnemers verwijderen';
  end if;
  if p_user = auth.uid() then raise exception 'Je kunt jezelf niet uit je eigen lijst verwijderen'; end if;
  delete from public.list_members where list_id = p_list and user_id = p_user;
  delete from public.list_invites where list_id = p_list and created_by = p_user;
  select * into l from public.lists where id = p_list;
  return l;
end $$;

-- ---------- De vaste code vervalt ----------
alter table public.lists drop column invite_code;
