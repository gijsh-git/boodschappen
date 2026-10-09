-- Kiezen bij een item dat vanuit "Voor jou" op de lijst staat (roadmap stap 7, deel 2).
--
-- Was: zo'n item (de aanbieding zelf, items.offer_id zonder original_name) had in het bonuspaneel geen knop
-- "Kiezen". choose_offer kon het wel, maar "Keuze wissen" en het terugvallen na afloop maakten offer_id leeg:
-- het item heette dan weer naar de aanbieding, zonder de aanbieding.
-- Wordt: de keuze onthoudt in offer_choice.oorspronkelijke_aanbieding van welke aanbieding het item kwam. Bij
-- wissen en na afloop krijgt het item die aanbieding terug (als ze nog bestaat) en is het weer wat het was.
-- Een getypt item heeft die sleutel niet en valt als voorheen terug zonder aanbieding.

comment on column public.items.offer_choice is
  'De gekozen aanbieding zoals ze was bij het kiezen: { titel, korting, geldig_tot, supermarkt, artikelen: [{ artikel_id, titel }], oorspronkelijke_aanbieding }. artikelen is leeg als de aanbieding als geheel is gekozen; oorspronkelijke_aanbieding staat er alleen bij een item dat vanuit Voor jou op de lijst kwam en is de aanbieding waar het na wissen of afloop op terugvalt.';

-- ---------- Kiezen ----------
-- Als voorheen, met de oorspronkelijke aanbieding in de momentopname.
create or replace function public.choose_offer_internal(p_item uuid, p_offer uuid, p_articles text[] default null,
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
  v_bron text;
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
  -- Een item uit Voor jou is de aanbieding zelf: die onthouden. Opnieuw kiezen houdt die van de eerste keer.
  v_bron := case when i.original_name is not null then i.offer_choice->>'oorspronkelijke_aanbieding'
                 else i.offer_id::text end;
  v_basis := jsonb_build_object('titel', v_titel, 'korting', o.discount_text, 'geldig_tot', o.valid_to,
                                'supermarkt', o.supermarket)
             || jsonb_strip_nulls(jsonb_build_object('oorspronkelijke_aanbieding', v_bron));
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

-- ---------- Keuze wissen, en terugvallen na afloop ----------
-- Als voorheen; een item uit Voor jou krijgt zijn aanbieding terug. Is die intussen opgeruimd, dan blijft
-- alleen de naam over.
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
         offer_choice = null, article_supermarket = null, article_id = null, choice_group = null,
         offer_id = (select o.id from public.offers o
                      where o.id = nullif(i.offer_choice->>'oorspronkelijke_aanbieding', '')::uuid)
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
         offer_choice = null, article_supermarket = null, article_id = null, choice_group = null,
         offer_id = (select o.id from public.offers o
                      where o.id = nullif(i.offer_choice->>'oorspronkelijke_aanbieding', '')::uuid)
   where i.id in (select id from houd);
  get diagnostics v_aantal = row_count;
  return v_aantal;
end $$;

-- ---------- Bonus-label op de lijst ----------
-- Als voorheen, met twee kolommen erbij: staat de aanbieding zelf op de lijst (items.offer_id), dan haar
-- korting en laatste dag, zodat het label "2 voor 3.99" kan zeggen in plaats van "Bonus". Bij een item dat
-- alleen via zijn naam aanbiedingen heeft zijn ze leeg.
drop function public.offers_for_list(uuid);
create function public.offers_for_list(p_list uuid)
returns table (item_id uuid, supermarkt text, aantal integer, weggeklikt integer, korting text, geldig_tot date)
language sql stable security definer
set search_path to 'public'
as $$
  with geldig as (
    select o.id, o.supermarket, o.discount_text, o.valid_to
    from public.offers o
    where (now() at time zone 'Europe/Amsterdam')::date between o.valid_from and o.valid_to
  ),
  treffer as (
    select i.id as item, g.id as offer, g.supermarket,
           exists (select 1 from public.offer_dismissals w
                   where w.item_id = i.id and w.offer_id = g.id and w.dismissed) as weg,
           null::text as korting, null::date as geldig_tot
    from public.items i
    cross join lateral public.term_articles(i.name) ta
    join public.offer_articles oa on upper(oa.supermarket) = ta.supermarket and oa.article_id = ta.article_id
    join geldig g on g.id = oa.offer_id
    where i.list_id = p_list and public.is_member(p_list) and i.original_name is null
      and i.offer_id is distinct from g.id
    union
    select i.id, g.id, g.supermarket, false, g.discount_text, g.valid_to
    from public.items i
    join geldig g on g.id = i.offer_id
    where i.list_id = p_list
  )
  select t.item, t.supermarket,
         (count(distinct t.offer) filter (where not t.weg))::integer,
         (count(distinct t.offer) filter (where t.weg))::integer,
         max(t.korting), max(t.geldig_tot)
  from treffer t
  where public.is_member(p_list)
  group by t.item, t.supermarket;
$$;
revoke all on function public.offers_for_list(uuid) from public, anon;
grant execute on function public.offers_for_list(uuid) to authenticated, service_role;
