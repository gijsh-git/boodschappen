-- Artikel-ID bij aankopen (roadmap stap 2).
-- Een bonregel van de AH-import heeft een artikelnummer. Dat blijft bij de aankoop staan, zodat een
-- aankoop later (stap 3 en 5) aan precies dat artikel en zijn aanbiedingen te koppelen is.

alter table public.purchases add column article_id text;

comment on column public.purchases.article_id is
  'Artikelnummer van de bon, in het systeem van de supermarkt op die bon (receipts.store via receipt_id). '
  'Voor AH is dat het hq_id, niet het webshop-ID. Leeg bij aankopen zonder bon en bij gescande bonnen.';

-- save_receipt: een regel kan nu een article_id meekrijgen. Het wordt opgeslagen bij een nieuwe aankoop,
-- bij een regel die aan een bestaande aankoop wordt gekoppeld en bij een item dat van de lijst gaat.
-- "Een product telt één keer per dag" wordt: één keer per naam én artikel-ID. Twee regels met dezelfde
-- naam maar een ander artikel-ID (bijv. twee formaten met dezelfde bontekst) zijn twee aankopen.
-- Ontbreekt het ID aan één van beide kanten, dan telt alleen de naam, zoals voorheen.
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
  v_artikel text;
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
                                      receipt_id, receipt_name, price, discount, article_id)
        values (p_list, i.id, i.name, coalesce(i.quantity, nullif(trim(r->>'quantity'), '')), i.added_by, i.created_at,
                auth.uid(), (p_date + time '12:00') at time zone 'Europe/Amsterdam',
                v_bon, nullif(trim(r->>'receipt_name'), ''), (r->>'price')::numeric, (r->>'discount')::numeric, v_artikel);
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

-- delete_receipt: het artikel-ID hoort bij de bon en gaat dus ook weg bij aankopen die gekoppeld waren.
CREATE OR REPLACE FUNCTION "public"."delete_receipt"("p_receipt" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from public.receipts where id = p_receipt and public.is_member(list_id)) then
    raise exception 'Bon niet gevonden';
  end if;
  delete from public.purchases where receipt_id = p_receipt and item_id is null;
  update public.purchases
    set receipt_id = null, receipt_name = null, price = null, discount = null, article_id = null
    where receipt_id = p_receipt;
  delete from public.receipts where id = p_receipt;
end $$;

-- Vult het artikel-ID aan bij aankopen die al van een bon kwamen (scripts/ah-artikel-aanvullen.py).
-- p_rows: [{ "purchase_id": ..., "article_id": ... }]. Alleen aankopen met een bon, in een lijst waarvan
-- je lid bent, en alleen waar nog geen ID staat: een bestaand ID wordt nooit overschreven.
-- Geeft terug hoeveel aankopen een ID hebben gekregen.
create or replace function public.fill_article_ids(p_rows jsonb)
returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare v_aantal integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 1000 then
    raise exception 'Hoogstens 1000 aankopen per keer';
  end if;
  update public.purchases a
    set article_id = trim(x.article_id)
    from jsonb_to_recordset(p_rows) as x(purchase_id uuid, article_id text)
    where a.id = x.purchase_id and a.receipt_id is not null and a.article_id is null
      and nullif(trim(x.article_id), '') is not null
      and public.is_member(a.list_id);
  get diagnostics v_aantal = row_count;
  return v_aantal;
end $$;

revoke all on function public.fill_article_ids(jsonb) from public, anon;
grant execute on function public.fill_article_ids(jsonb) to authenticated, service_role;
