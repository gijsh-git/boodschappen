-- Een gekozen aanbieding met meerdere artikelen wordt per artikel een eigen item (roadmap stap 7, deel 2).
--
-- Was: twee aangevinkte artikelen bleven één item met de titel van de aanbieding en de varianten eronder.
-- Dat gaf een volle rij op de telefoon, en in de winkel pak je de artikelen ook één voor één.
-- Wordt: het item zelf wordt het eerste artikel, voor elk volgend artikel komt er een item bij. Ze horen bij
-- elkaar via choice_group: wis je de keuze of verloopt de aanbieding, dan blijft er één item over met wat
-- er oorspronkelijk stond. Niets aangevinkt blijft één item met de titel van de aanbieding.

alter table public.items add column choice_group uuid;
comment on column public.items.choice_group is
  'Bij een gekozen aanbieding: het id van het item waar de keuze mee begon. Items met dezelfde waarde kwamen uit één keuze en vallen samen terug op één item.';
create index items_choice_group_idx on public.items (choice_group) where choice_group is not null;

-- ---------- Kiezen ----------
create or replace function public.choose_offer(p_item uuid, p_offer uuid, p_articles text[] default null) returns public.items
language plpgsql security definer
set search_path to 'public'
as $$
declare
  i public.items;
  o public.offers;
  a record;
  v_titel text;
  v_basis jsonb;
  v_keuze jsonb;
  v_groep uuid;
  v_origineel text;
  v_uit public.items;
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
  -- MEESTE ARTIKELEN: elk artikel wordt een eigen rij op de lijst
  if coalesce(cardinality(p_articles), 0) > 20 then raise exception 'Kies hooguit 20 artikelen'; end if;

  v_titel := btrim(regexp_replace(o.title, '\s*\*+$', ''));
  v_titel := upper(left(v_titel, 1)) || substr(v_titel, 2);
  v_basis := jsonb_build_object('titel', v_titel, 'korting', o.discount_text, 'geldig_tot', o.valid_to,
                                'supermarkt', o.supermarket);
  v_groep := coalesce(i.choice_group, i.id);
  v_origineel := coalesce(i.original_name, i.name);

  for a in
    select x.supermarket, x.article_id, x.title,
           row_number() over (order by x.title, x.article_id) as nr
    from public.offer_articles oa
    join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
    where oa.offer_id = p_offer and oa.article_id = any (coalesce(p_articles, '{}'))
    order by 4
  loop
    v_keuze := v_basis || jsonb_build_object('artikelen',
                 jsonb_build_array(jsonb_build_object('artikel_id', a.article_id, 'titel', a.title)));
    if a.nr = 1 then
      update public.items
         set original_name = v_origineel, name = left(a.title, 120), offer_id = p_offer, offer_choice = v_keuze,
             article_supermarket = a.supermarket, article_id = a.article_id, choice_group = v_groep
       where id = p_item
      returning * into v_uit;
    else
      -- Zelfde maker en (vrijwel) hetzelfde moment als het item zelf, zodat ze op de lijst bij elkaar staan
      insert into public.items (list_id, name, added_by, created_at, original_name, offer_choice, offer_id,
                                article_supermarket, article_id, type_id, choice_group)
      values (i.list_id, left(a.title, 120), i.added_by, i.created_at + (a.nr - 1) * interval '1 millisecond',
              v_origineel, v_keuze, p_offer, a.supermarket, a.article_id, i.type_id, v_groep);
    end if;
  end loop;

  -- Niets aangevinkt (of niets dat bij de aanbieding hoort): de aanbieding als geheel
  if v_uit.id is null then
    update public.items
       set original_name = v_origineel, name = left(v_titel, 120), offer_id = p_offer,
           offer_choice = v_basis || jsonb_build_object('artikelen', '[]'::jsonb),
           article_supermarket = null, article_id = null, choice_group = v_groep
     where id = p_item
    returning * into v_uit;
  end if;
  return v_uit;
end $$;

-- ---------- Keuze wissen, en terugvallen na afloop ----------
-- Dit item heet weer wat er oorspronkelijk stond; de andere items uit dezelfde keuze gaan weg.
create or replace function public.clear_offer_choice(p_item uuid) returns public.items
language plpgsql security definer
set search_path to 'public'
as $$
declare
  i public.items;
begin
  select * into i from public.items where id = p_item and original_name is not null for update;
  if not found or not public.is_member(i.list_id) then raise exception 'Item niet gevonden'; end if;
  delete from public.items
   where list_id = i.list_id and choice_group = i.choice_group and id <> p_item and original_name is not null;
  update public.items
     set name = original_name, original_name = null, offer_choice = null, offer_id = null,
         article_supermarket = null, article_id = null, choice_group = null
   where id = p_item
  returning * into i;
  return i;
end $$;

-- Per keuze blijft het oudste item over; geeft terug hoeveel items weer heten wat er stond.
create or replace function public.reset_expired_choices(p_list uuid) returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_aantal integer;
begin
  if not public.is_member(p_list) then return 0; end if;
  with verlopen as (
    select i.id, coalesce(i.choice_group, i.id) as groep, i.created_at
    from public.items i
    where i.list_id = p_list and i.original_name is not null
      and (i.offer_id is null
           or (i.offer_choice->>'geldig_tot')::date < (now() at time zone 'Europe/Amsterdam')::date)
  ),
  houd as (
    select distinct on (v.groep) v.id from verlopen v order by v.groep, v.created_at, v.id
  ),
  weg as (
    delete from public.items i
     where i.id in (select id from verlopen) and i.id not in (select id from houd)
  )
  update public.items i
     set name = original_name, original_name = null, offer_choice = null, offer_id = null,
         article_supermarket = null, article_id = null, choice_group = null
   where i.id in (select id from houd);
  get diagnostics v_aantal = row_count;
  return v_aantal;
end $$;

-- ---------- Gekocht en ongedaan ----------
-- Een item is nu altijd één aankoop. Bij een gekozen aanbieding gaan het artikel en de oorspronkelijke invoer
-- mee, en item_choice bewaart het item zoals het was voor undo_purchase.
create or replace function public.buy_item(p_item uuid) returns uuid
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  i public.items;
  v_id uuid;
begin
  delete from public.items where id = p_item and public.is_member(list_id) returning * into i;
  -- Al weg (bijv. de ander was net eerder) of geen lid: niets te doen
  if not found then return null; end if;
  insert into public.purchases (list_id, item_id, name, quantity, added_by, item_created_at, bought_by,
                                original_name, article_supermarket, article_id, item_choice)
  values (i.list_id, i.id, i.name, i.quantity, i.added_by, i.created_at, auth.uid(),
          i.original_name,
          case when i.original_name is not null then i.article_supermarket end,
          case when i.original_name is not null then i.article_id end,
          case when i.original_name is not null then jsonb_build_object(
            'name', i.name, 'original_name', i.original_name, 'offer_id', i.offer_id, 'offer_choice', i.offer_choice,
            'article_supermarket', i.article_supermarket, 'article_id', i.article_id, 'type_id', i.type_id,
            'choice_group', i.choice_group) end)
  returning id into v_id;
  return v_id;
end $$;

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
  -- Met de keuze terug. Is de aanbieding intussen opgeruimd, dan zonder de koppeling ernaar: het item valt
  -- bij het laden terug op de oorspronkelijke invoer.
  insert into public.items (id, list_id, name, quantity, added_by, created_at, original_name, offer_choice,
                            offer_id, article_supermarket, article_id, type_id, choice_group)
  values (coalesce(a.item_id, gen_random_uuid()), a.list_id, z->>'name', a.quantity, a.added_by,
          coalesce(a.item_created_at, now()), z->>'original_name', z->'offer_choice',
          (select o.id from public.offers o where o.id = nullif(z->>'offer_id', '')::uuid),
          z->>'article_supermarket', z->>'article_id',
          (select p.id from public.product_types p where p.id = nullif(z->>'type_id', '')::uuid),
          nullif(z->>'choice_group', '')::uuid)
  on conflict (id) do nothing;
end $$;
