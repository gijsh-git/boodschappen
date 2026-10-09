-- Bij het kiezen van een aanbieding per artikel een aantal (roadmap stap 7, deel 2).
--
-- Was: elk aangevinkt artikel kwam één keer op de lijst en de hoeveelheid van het item bleef staan wat hij
-- was. "2 voor 5.99" met twee keer hetzelfde artikel kon je dus niet vastleggen.
-- Wordt: choose_offer krijgt per artikel een aantal mee. Dat komt in items.quantity van die rij ("2×"; bij
-- één stuk leeg). Wat er als hoeveelheid stond gaat naar original_quantity en komt terug bij "Keuze wissen"
-- en na afloop van de aanbieding, net als de naam. Niets aangevinkt (de aanbieding als geheel) laat de
-- hoeveelheid staan.

alter table public.items add column original_quantity text;
comment on column public.items.original_quantity is
  'Bij een gekozen aanbieding: de hoeveelheid die er oorspronkelijk stond. Hoort bij original_name en komt terug als de keuze wordt gewist of verloopt.';

-- Keuzes die er al staan: hun hoeveelheid is nog de oorspronkelijke
update public.items set original_quantity = quantity where original_name is not null;

-- ---------- Kiezen ----------
-- p_counts: per artikel-id het aantal, { "<artikel_id>": 2 }; wat ontbreekt of geen getal van 1 t/m 99 is telt als 1.
drop function public.choose_offer(uuid, uuid, text[]);
drop function public.choose_offer_internal(uuid, uuid, text[]);

create function public.choose_offer_internal(p_item uuid, p_offer uuid, p_articles text[] default null,
                                             p_counts jsonb default null) returns public.items
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
  v_hoeveelheid text;
  v_aantal integer;
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
  -- Opnieuw kiezen: de oorspronkelijke hoeveelheid blijft die van de eerste keer
  v_hoeveelheid := case when i.original_name is not null then i.original_quantity else i.quantity end;

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
    v_aantal := case when jsonb_typeof(p_counts) = 'object' and p_counts->>a.article_id ~ '^[0-9]{1,2}$'
                     then greatest((p_counts->>a.article_id)::integer, 1) else 1 end;
    if a.nr = 1 then
      update public.items
         set original_name = v_origineel, name = left(a.title, 120), offer_id = p_offer, offer_choice = v_keuze,
             article_supermarket = a.supermarket, article_id = a.article_id, choice_group = v_groep,
             original_quantity = v_hoeveelheid, quantity = case when v_aantal > 1 then v_aantal || '×' end
       where id = p_item
      returning * into v_uit;
    else
      -- Zelfde maker en (vrijwel) hetzelfde moment als het item zelf, zodat ze op de lijst bij elkaar staan
      insert into public.items (list_id, name, added_by, created_at, original_name, offer_choice, offer_id,
                                article_supermarket, article_id, type_id, choice_group, original_quantity, quantity)
      values (i.list_id, left(a.title, 120), i.added_by, i.created_at + (a.nr - 1) * interval '1 millisecond',
              v_origineel, v_keuze, p_offer, a.supermarket, a.article_id, i.type_id, v_groep, v_hoeveelheid,
              case when v_aantal > 1 then v_aantal || '×' end);
    end if;
  end loop;

  -- Niets aangevinkt (of niets dat bij de aanbieding hoort): de aanbieding als geheel, met de hoeveelheid
  -- die er stond
  if v_uit.id is null then
    update public.items
       set original_name = v_origineel, name = left(v_titel, 120), offer_id = p_offer,
           offer_choice = v_basis || jsonb_build_object('artikelen', '[]'::jsonb),
           article_supermarket = null, article_id = null, choice_group = v_groep,
           original_quantity = v_hoeveelheid, quantity = v_hoeveelheid
     where id = p_item
    returning * into v_uit;
  end if;
  return v_uit;
end $$;
revoke all on function public.choose_offer_internal(uuid, uuid, text[], jsonb) from public, anon, authenticated;
grant execute on function public.choose_offer_internal(uuid, uuid, text[], jsonb) to service_role;

-- Het kiezen plus het vastleggen; bij de artikelen staat nu ook het aantal.
create function public.choose_offer(p_item uuid, p_offer uuid, p_articles text[] default null,
                                    p_counts jsonb default null) returns public.items
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_voor public.items;
  v_na public.items;
begin
  select * into v_voor from public.items where id = p_item;
  v_na := public.choose_offer_internal(p_item, p_offer, p_articles, p_counts);
  perform public.log_offer_action(
    'gekozen', v_na.list_id, coalesce(v_voor.original_name, v_voor.name), v_voor.type_id, p_offer,
    (select jsonb_agg(jsonb_build_object(
              'artikel_id', x.article_id, 'titel', x.title,
              'aantal', case when jsonb_typeof(p_counts) = 'object' and p_counts->>x.article_id ~ '^[0-9]{1,2}$'
                             then greatest((p_counts->>x.article_id)::integer, 1) else 1 end)
            order by x.title, x.article_id)
     from public.offer_articles oa
     join public.articles x on x.supermarket = oa.supermarket and x.article_id = oa.article_id
     where oa.offer_id = p_offer and oa.article_id = any (coalesce(p_articles, '{}'))));
  return v_na;
end $$;
revoke all on function public.choose_offer(uuid, uuid, text[], jsonb) from public, anon;
grant execute on function public.choose_offer(uuid, uuid, text[], jsonb) to authenticated, service_role;
comment on column public.offer_actions.articles is
  'Bij gekozen en gewist: de gekozen artikelen, [{ artikel_id, titel }], bij gekozen met aantal; leeg is de aanbieding als geheel.';

-- ---------- Keuze wissen, en terugvallen na afloop ----------
-- Als voorheen; de hoeveelheid die er stond komt mee terug.
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
     set name = original_name, quantity = original_quantity, original_name = null, original_quantity = null,
         offer_choice = null, offer_id = null, article_supermarket = null, article_id = null, choice_group = null
   where id = p_item
  returning * into i;
  return i;
end $$;

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
     set name = original_name, quantity = original_quantity, original_name = null, original_quantity = null,
         offer_choice = null, offer_id = null, article_supermarket = null, article_id = null, choice_group = null
   where i.id in (select id from houd);
  get diagnostics v_aantal = row_count;
  return v_aantal;
end $$;

-- ---------- Gekocht en ongedaan ----------
-- item_choice onthoudt ook de oorspronkelijke hoeveelheid, zodat een teruggezet item daar weer op kan terugvallen.
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
            'choice_group', i.choice_group, 'original_quantity', i.original_quantity) end)
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
  -- bij het laden terug op de oorspronkelijke invoer. Een aankoop van voor de aantallen kent geen
  -- oorspronkelijke hoeveelheid: daar is het de hoeveelheid zelf.
  insert into public.items (id, list_id, name, quantity, added_by, created_at, original_name, offer_choice,
                            offer_id, article_supermarket, article_id, type_id, choice_group, original_quantity)
  values (coalesce(a.item_id, gen_random_uuid()), a.list_id, z->>'name', a.quantity, a.added_by,
          coalesce(a.item_created_at, now()), z->>'original_name', z->'offer_choice',
          (select o.id from public.offers o where o.id = nullif(z->>'offer_id', '')::uuid),
          z->>'article_supermarket', z->>'article_id',
          (select p.id from public.product_types p where p.id = nullif(z->>'type_id', '')::uuid),
          nullif(z->>'choice_group', '')::uuid,
          case when z ? 'original_quantity' then z->>'original_quantity' else a.quantity end)
  on conflict (id) do nothing;
end $$;
