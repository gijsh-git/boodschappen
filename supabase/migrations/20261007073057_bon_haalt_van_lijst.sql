-- Een bon haalt producten die nog op de lijst staan van de lijst.
-- Regel: een item gaat van de lijst en wordt een aankoop als het hetzelfde product is als een bonregel
-- en de bondatum op of na de dag van toevoegen ligt. Bij alleen een gelijkende naam kiest de gebruiker
-- dat zelf in het scherm "Bon controleren".

-- Zoekt bij elke bonregel het best passende item op de lijst dat op of voor de bondatum is toegevoegd.
-- zeker = dezelfde naam of hetzelfde product (via product_aliases); anders lijkt alleen de naam erop.
-- Security definer, omdat een gewoon lid de alias van een nieuwe bonnaam nog niet mag lezen.
create or replace function public.match_receipt_items(p_list uuid, p_date date, p_names text[])
returns table(regel integer, item_id uuid, name text, zeker boolean)
language sql stable security definer
set search_path to 'public', 'extensions'
as $$
  with kandidaten as (
    select n.regel::integer as regel, i.id, i.name, i.created_at,
           (i.normalized_name = lower(trim(n.naam))
            or exists (
              select 1 from public.product_aliases bon
              join public.product_aliases lijst on lijst.product_id = bon.product_id
              where bon.normalized_name = lower(trim(n.naam)) and lijst.normalized_name = i.normalized_name
            )) as zeker,
           greatest(strict_word_similarity(i.normalized_name, lower(trim(n.naam))),
                    strict_word_similarity(lower(trim(n.naam)), i.normalized_name)) as score
    from unnest(p_names) with ordinality as n(naam, regel)
    join public.items i
      on i.list_id = p_list
     and (i.created_at at time zone 'Europe/Amsterdam')::date <= p_date
    where public.is_member(p_list) and trim(n.naam) <> ''
  ),
  -- GEVOELIGHEID: dezelfde drempel als bij de aankopen van dezelfde dag (match_receipt_lines)
  per_regel as (
    select distinct on (k.regel) k.* from kandidaten k where k.zeker or k.score >= 0.5
    order by k.regel, k.zeker desc, k.score desc, k.created_at
  )
  -- een item hoort bij hoogstens één bonregel: de best passende
  select distinct on (p.id) p.regel, p.id, p.name, p.zeker from per_regel p order by p.id, p.zeker desc, p.score desc, p.regel;
$$;

revoke all on function public.match_receipt_items(uuid, date, text[]) from public, anon;
grant execute on function public.match_receipt_items(uuid, date, text[]) to authenticated, service_role;

-- save_receipt: een regel kan nu een item_id meekrijgen. Dat item gaat van de lijst en wordt de aankoop
-- van die regel, net als bij buy_item (met item_id, added_by en item_created_at), plus de bongegevens.
-- De rest van de functie is ongewijzigd.
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
  i public.items;
  v_toegevoegd integer := 0;
  v_gekoppeld integer := 0;
  v_overgeslagen integer := 0;
  v_van_lijst integer := 0;
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
    v_item := nullif(r->>'item_id', '')::uuid;

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
                                      receipt_id, receipt_name, price, discount)
        values (p_list, i.id, i.name, coalesce(i.quantity, nullif(trim(r->>'quantity'), '')), i.added_by, i.created_at,
                auth.uid(), (p_date + time '12:00') at time zone 'Europe/Amsterdam',
                v_bon, nullif(trim(r->>'receipt_name'), ''), (r->>'price')::numeric, (r->>'discount')::numeric);
        v_van_lijst := v_van_lijst + 1;
        continue;
      end if;
      -- Item al weg (bijv. de ander was net eerder): de regel gaat verder als een gewone bonregel
    end if;

    if exists (
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
  if v_toegevoegd + v_gekoppeld + v_van_lijst = 0 then delete from public.receipts where id = v_bon; end if;

  return jsonb_build_object('toegevoegd', v_toegevoegd, 'gekoppeld', v_gekoppeld, 'overgeslagen', v_overgeslagen,
                            'van_lijst', v_van_lijst);
end $$;
