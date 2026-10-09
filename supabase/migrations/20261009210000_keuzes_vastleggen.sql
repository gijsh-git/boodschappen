-- Keuzes bij aanbiedingen vastleggen (roadmap stap 7, deel 4).
--
-- Elke keer dat iemand een aanbieding kiest, wegklikt, terughaalt of een keuze wist, komt er een rij in
-- offer_actions. Niets leest deze tabel nog: hij is bedoeld om later de matching en de volgorde te
-- verbeteren (welke overstappen maken mensen echt). De app verandert niet; de bestaande functies leggen het
-- zelf vast. Vastleggen mag een actie nooit tegenhouden: een fout daar geeft alleen een waarschuwing.

-- ---------- Opslag ----------
-- De aanbieding staat er als momentopname in (offers ruimt na 28 dagen op), dus zonder verwijzing.
create table public.offer_actions (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('gekozen', 'gewist', 'weggeklikt', 'teruggehaald')),
  list_id uuid references public.lists(id) on delete cascade,
  user_id uuid,
  term text,
  type_id uuid references public.product_types(id) on delete set null,
  variant text,
  offer_id uuid,
  supermarket text,
  offer_source_id text,
  offer_title text,
  discount_text text,
  articles jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index offer_actions_list_idx on public.offer_actions (list_id, created_at);
comment on table public.offer_actions is
  'Logboek van keuzes bij aanbiedingen: gekozen, gewist, weggeklikt, teruggehaald. Niets leest dit nog. BEWAARTERMIJN: voor de publieke fase nog vast te leggen (AVG); de rijen gaan nu alleen weg met de lijst.';
comment on column public.offer_actions.list_id is 'De lijst; leeg bij wegklikken in Voor jou (alleen voor die gebruiker).';
comment on column public.offer_actions.term is 'Wat er oorspronkelijk op de lijst stond ("tomatensoep"); leeg in Voor jou.';
comment on column public.offer_actions.variant is 'De variant van de term als stam (term_variant), zoals die bij de volgorde is gebruikt.';
comment on column public.offer_actions.offer_source_id is 'Het nummer van de aanbieding bij de supermarkt (offers.offer_id): blijft gelijk als de actie later terugkomt.';
comment on column public.offer_actions.articles is 'Bij gekozen en gewist: de gekozen artikelen, [{ artikel_id, titel }]; leeg is de aanbieding als geheel.';

-- Geen policies en geen rechten: alleen de functies schrijven hier
alter table public.offer_actions enable row level security;
revoke all on table public.offer_actions from public, anon, authenticated;

-- ---------- Vastleggen ----------
create function public.log_offer_action(
  p_action text, p_list uuid, p_term text, p_type uuid, p_offer uuid, p_articles jsonb default null) returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  o public.offers;
begin
  select * into o from public.offers where id = p_offer;
  insert into public.offer_actions (action, list_id, user_id, term, type_id, variant, offer_id, supermarket,
                                    offer_source_id, offer_title, discount_text, articles)
  values (p_action, p_list, auth.uid(), nullif(btrim(p_term), ''),
          coalesce(p_type, public.name_type(p_term)), public.term_variant(p_term),
          p_offer, o.supermarket, o.offer_id, o.title, o.discount_text,
          case when jsonb_typeof(p_articles) = 'array' then p_articles else '[]'::jsonb end);
exception when others then
  raise warning 'log_offer_action: %', sqlerrm;
end $$;
revoke all on function public.log_offer_action(text, uuid, text, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.log_offer_action(text, uuid, text, uuid, uuid, jsonb) to service_role;

-- ---------- Kiezen ----------
-- Het kiezen zelf blijft wat het was, onder een andere naam; choose_offer() legt er de keuze bij vast.
alter function public.choose_offer(uuid, uuid, text[]) rename to choose_offer_internal;
revoke all on function public.choose_offer_internal(uuid, uuid, text[]) from public, anon, authenticated;
grant execute on function public.choose_offer_internal(uuid, uuid, text[]) to service_role;

create function public.choose_offer(p_item uuid, p_offer uuid, p_articles text[] default null) returns public.items
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_voor public.items;
  v_na public.items;
begin
  select * into v_voor from public.items where id = p_item;
  v_na := public.choose_offer_internal(p_item, p_offer, p_articles);
  perform public.log_offer_action(
    'gekozen', v_na.list_id, coalesce(v_voor.original_name, v_voor.name), v_voor.type_id, p_offer,
    (select jsonb_agg(jsonb_build_object('artikel_id', x.article_id, 'titel', x.title) order by x.title, x.article_id)
     from public.offer_articles oa
     join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
     where oa.offer_id = p_offer and oa.article_id = any (coalesce(p_articles, '{}'))));
  return v_na;
end $$;
revoke all on function public.choose_offer(uuid, uuid, text[]) from public, anon;
grant execute on function public.choose_offer(uuid, uuid, text[]) to authenticated, service_role;

-- ---------- Keuze wissen ----------
-- Als voorheen, met het vastleggen erbij: de artikelen zijn die van alle items uit dezelfde keuze.
create or replace function public.clear_offer_choice(p_item uuid) returns public.items
language plpgsql security definer
set search_path to 'public'
as $$
declare
  i public.items;
  v_artikelen jsonb;
begin
  select * into i from public.items where id = p_item and original_name is not null for update;
  if not found or not public.is_member(i.list_id) then raise exception 'Item niet gevonden'; end if;
  select jsonb_agg(a order by a->>'titel') into v_artikelen
    from public.items g
    cross join lateral jsonb_array_elements(coalesce(g.offer_choice->'artikelen', '[]'::jsonb)) a
   where g.list_id = i.list_id and g.original_name is not null
     and (g.id = p_item or g.choice_group = i.choice_group);
  perform public.log_offer_action('gewist', i.list_id, i.original_name, i.type_id, i.offer_id, v_artikelen);

  delete from public.items
   where list_id = i.list_id and choice_group = i.choice_group and id <> p_item and original_name is not null;
  update public.items
     set name = original_name, original_name = null, offer_choice = null, offer_id = null,
         article_supermarket = null, article_id = null, choice_group = null
   where id = p_item
  returning * into i;
  return i;
end $$;

-- ---------- Wegklikken en terughalen ----------
create or replace function public.dismiss_offer(p_item uuid, p_offer uuid) returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  i public.items;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  select * into i from public.items where id = p_item;
  if not found or not public.is_member(i.list_id) then raise exception 'Item niet gevonden'; end if;
  if not exists (select 1 from public.offers where id = p_offer) then raise exception 'Aanbieding niet gevonden'; end if;
  insert into public.offer_dismissals (offer_id, item_id, list_id, user_id)
  values (p_offer, p_item, i.list_id, auth.uid())
  on conflict (item_id, offer_id) where item_id is not null
  do update set dismissed = true, user_id = excluded.user_id, created_at = now();
  perform public.log_offer_action('weggeklikt', i.list_id, coalesce(i.original_name, i.name), i.type_id, p_offer);
end $$;

create or replace function public.restore_offer(p_item uuid, p_offer uuid) returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  i public.items;
begin
  update public.offer_dismissals
     set dismissed = false
   where item_id = p_item and offer_id = p_offer and dismissed and public.is_member(list_id);
  if not found then return; end if;
  select * into i from public.items where id = p_item;
  perform public.log_offer_action('teruggehaald', i.list_id, coalesce(i.original_name, i.name), i.type_id, p_offer);
end $$;

create or replace function public.dismiss_offer_for_me(p_offer uuid) returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  if not exists (select 1 from public.offers where id = p_offer) then raise exception 'Aanbieding niet gevonden'; end if;
  insert into public.offer_dismissals (offer_id, user_id)
  values (p_offer, auth.uid())
  on conflict (user_id, offer_id) where item_id is null
  do update set dismissed = true, created_at = now();
  perform public.log_offer_action('weggeklikt', null, null, null, p_offer);
end $$;
