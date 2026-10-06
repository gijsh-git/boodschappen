


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";





SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."lists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "invite_code" "text" DEFAULT "substr"("replace"(("gen_random_uuid"())::"text", '-'::"text", ''::"text"), 1, 8) NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "counts_for_profile" boolean DEFAULT true NOT NULL,
    "archived_at" timestamp with time zone
);


ALTER TABLE "public"."lists" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."archive_list"("p_list" "uuid", "p_archived" boolean) RETURNS "public"."lists"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare l public.lists;
begin
  update public.lists
    set archived_at = case when p_archived then coalesce(archived_at, now()) end
    where id = p_list and created_by = auth.uid() returning * into l;
  if not found then raise exception 'Alleen de maker kan deze lijst archiveren of terugzetten'; end if;
  return l;
end $$;


ALTER FUNCTION "public"."archive_list"("p_list" "uuid", "p_archived" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."buy_item"("p_item" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."buy_item"("p_item" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_list"("p_name" "text") RETURNS "public"."lists"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare l public.lists;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  insert into public.lists (name, created_by) values (p_name, auth.uid()) returning * into l;
  insert into public.list_members (list_id, user_id) values (l.id, auth.uid());
  return l;
end $$;


ALTER FUNCTION "public"."create_list"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deals_for_list"("p_list" "uuid") RETURNS TABLE("item_id" "uuid", "supermarkt" "text", "aantal" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
  select i.id, d.supermarkt, count(*)::integer
  from public.items i
  join public.deals d
    -- GEVOELIGHEID: lager = meer (lossere) matches, hoger = strenger
    on strict_word_similarity(i.normalized_name, lower(d.productnaam)) >= 0.35
  where i.list_id = p_list
    and (now() at time zone 'Europe/Amsterdam')::date between d.geldig_van and d.geldig_tot
  group by i.id, d.supermarkt;
$$;


ALTER FUNCTION "public"."deals_for_list"("p_list" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_list"("p_list" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from public.lists where id = p_list and created_by = auth.uid();
  if not found then raise exception 'Alleen de maker kan deze lijst verwijderen'; end if;
end $$;


ALTER FUNCTION "public"."delete_list"("p_list" "uuid") OWNER TO "postgres";


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
    set receipt_id = null, receipt_name = null, price = null, discount = null
    where receipt_id = p_receipt;
  delete from public.receipts where id = p_receipt;
end $$;


ALTER FUNCTION "public"."delete_receipt"("p_receipt" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_product"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."ensure_product"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_member"("p_list" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from public.list_members where list_id = p_list and user_id = auth.uid());
$$;


ALTER FUNCTION "public"."is_member"("p_list" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."join_list"("p_code" "text") RETURNS "public"."lists"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare l public.lists;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  select * into l from public.lists where invite_code = lower(trim(p_code));
  if not found then raise exception 'Code niet gevonden'; end if;
  if l.archived_at is not null then raise exception 'Deze lijst is gearchiveerd'; end if;
  insert into public.list_members (list_id, user_id) values (l.id, auth.uid()) on conflict do nothing;
  return l;
end $$;


ALTER FUNCTION "public"."join_list"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_receipt_lines"("p_list" "uuid", "p_date" "date", "p_names" "text"[]) RETURNS TABLE("regel" integer, "purchase_id" "uuid", "name" "text", "has_receipt" boolean)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
  with kandidaten as (
    select n.regel::integer as regel, a.id, a.name, a.receipt_id is not null as has_receipt,
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


ALTER FUNCTION "public"."match_receipt_lines"("p_list" "uuid", "p_date" "date", "p_names" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_products"("p_source" "uuid", "p_target" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan producten samenvoegen'; end if;
  return public.merge_products_internal(p_source, p_target, auth.uid());
end $$;


ALTER FUNCTION "public"."merge_products"("p_source" "uuid", "p_target" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_products_internal"("p_source" "uuid", "p_target" "uuid", "p_by" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."merge_products_internal"("p_source" "uuid", "p_target" "uuid", "p_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."product_overview"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."product_overview"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."receipt_exists"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric) RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.receipts r
    where r.list_id = p_list
      and lower(r.store) = lower(trim(p_store))
      and r.receipt_date = p_date
      and r.total is not distinct from p_total
      and exists (select 1 from public.purchases a where a.receipt_id = r.id)
  );
$$;


ALTER FUNCTION "public"."receipt_exists"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_member"("p_list" "uuid", "p_user" "uuid") RETURNS "public"."lists"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."remove_member"("p_list" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."products" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rename_product"("p_product" "uuid", "p_name" "text") RETURNS "public"."products"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."rename_product"("p_product" "uuid", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_receipt"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric, "p_lines" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."save_receipt"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric, "p_lines" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_list_profile"("p_list" "uuid", "p_counts" boolean) RETURNS "public"."lists"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare l public.lists;
begin
  if not public.is_member(p_list) then raise exception 'Geen lid van deze lijst'; end if;
  update public.lists set counts_for_profile = p_counts where id = p_list returning * into l;
  return l;
end $$;


ALTER FUNCTION "public"."set_list_profile"("p_list" "uuid", "p_counts" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."undo_merge"("p_merge" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."undo_merge"("p_merge" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."undo_purchase"("p_purchase" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare a public.purchases;
begin
  delete from public.purchases where id = p_purchase and public.is_member(list_id) returning * into a;
  if not found then return; end if;
  insert into public.items (id, list_id, name, quantity, added_by, created_at)
  values (coalesce(a.item_id, gen_random_uuid()), a.list_id, a.name, a.quantity, a.added_by,
          coalesce(a.item_created_at, now()))
  on conflict (id) do nothing;
end $$;


ALTER FUNCTION "public"."undo_purchase"("p_purchase" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admins" (
    "user_id" "uuid" NOT NULL
);


ALTER TABLE "public"."admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."deals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "supermarkt" "text" NOT NULL,
    "productnaam" "text" NOT NULL,
    "omschrijving" "text" NOT NULL,
    "prijs" numeric(6,2),
    "geldig_van" "date" NOT NULL,
    "geldig_tot" "date" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "deals_check" CHECK (("geldig_tot" >= "geldig_van")),
    CONSTRAINT "deals_supermarkt_check" CHECK (("supermarkt" = ANY (ARRAY['AH'::"text", 'PLUS'::"text"])))
);


ALTER TABLE "public"."deals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "list_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "normalized_name" "text" GENERATED ALWAYS AS ("lower"(TRIM(BOTH FROM "name"))) STORED,
    "quantity" "text",
    "checked" boolean DEFAULT false NOT NULL,
    "checked_at" timestamp with time zone,
    "added_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."list_members" (
    "list_id" "uuid" NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."list_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_aliases" (
    "normalized_name" "text" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."product_aliases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_merges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "target_id" "uuid" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "source_name" "text" NOT NULL,
    "aliases" "text"[] NOT NULL,
    "merged_by" "uuid",
    "merged_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "undone_by" "uuid",
    "undone_at" timestamp with time zone
);


ALTER TABLE "public"."product_merges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "display_name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "profiles_display_name_check" CHECK ((("char_length"(TRIM(BOTH FROM "display_name")) >= 1) AND ("char_length"(TRIM(BOTH FROM "display_name")) <= 40)))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "list_id" "uuid" NOT NULL,
    "item_id" "uuid",
    "name" "text" NOT NULL,
    "normalized_name" "text" GENERATED ALWAYS AS ("lower"(TRIM(BOTH FROM "name"))) STORED,
    "quantity" "text",
    "added_by" "uuid",
    "item_created_at" timestamp with time zone,
    "bought_by" "uuid" DEFAULT "auth"."uid"(),
    "bought_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "receipt_id" "uuid",
    "receipt_name" "text",
    "price" numeric(8,2),
    "discount" numeric(8,2)
);


ALTER TABLE "public"."purchases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "list_id" "uuid" NOT NULL,
    "store" "text" NOT NULL,
    "receipt_date" "date" NOT NULL,
    "total" numeric(8,2),
    "added_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."receipts" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."deals"
    ADD CONSTRAINT "deals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."list_members"
    ADD CONSTRAINT "list_members_pkey" PRIMARY KEY ("list_id", "user_id");



ALTER TABLE ONLY "public"."lists"
    ADD CONSTRAINT "lists_invite_code_key" UNIQUE ("invite_code");



ALTER TABLE ONLY "public"."lists"
    ADD CONSTRAINT "lists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_aliases"
    ADD CONSTRAINT "product_aliases_pkey" PRIMARY KEY ("normalized_name");



ALTER TABLE ONLY "public"."product_merges"
    ADD CONSTRAINT "product_merges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_pkey" PRIMARY KEY ("id");



CREATE INDEX "items_list_idx" ON "public"."items" USING "btree" ("list_id");



CREATE INDEX "items_normalized_idx" ON "public"."items" USING "btree" ("normalized_name");



CREATE INDEX "product_aliases_product_idx" ON "public"."product_aliases" USING "btree" ("product_id");



CREATE INDEX "product_merges_target_idx" ON "public"."product_merges" USING "btree" ("target_id");



CREATE INDEX "purchases_list_idx" ON "public"."purchases" USING "btree" ("list_id", "bought_at" DESC);



CREATE INDEX "purchases_normalized_idx" ON "public"."purchases" USING "btree" ("normalized_name");



CREATE INDEX "purchases_receipt_idx" ON "public"."purchases" USING "btree" ("receipt_id");



CREATE INDEX "receipts_list_idx" ON "public"."receipts" USING "btree" ("list_id", "receipt_date");



CREATE OR REPLACE TRIGGER "items_product" AFTER INSERT OR UPDATE OF "name" ON "public"."items" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_product"();



CREATE OR REPLACE TRIGGER "purchases_product" AFTER INSERT OR UPDATE OF "name" ON "public"."purchases" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_product"();



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_members"
    ADD CONSTRAINT "list_members_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_aliases"
    ADD CONSTRAINT "product_aliases_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_receipt_id_fkey" FOREIGN KEY ("receipt_id") REFERENCES "public"."receipts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."lists"("id") ON DELETE CASCADE;



ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "beheerder en lijstleden zien namen" ON "public"."product_aliases" FOR SELECT TO "authenticated" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."purchases" "a"
  WHERE ("a"."normalized_name" = "product_aliases"."normalized_name"))) OR (EXISTS ( SELECT 1
   FROM "public"."items" "i"
  WHERE ("i"."normalized_name" = "product_aliases"."normalized_name")))));



CREATE POLICY "beheerder en lijstleden zien producten" ON "public"."products" FOR SELECT TO "authenticated" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."product_aliases" "a"
  WHERE ("a"."product_id" = "products"."id")))));



CREATE POLICY "beheerder ziet samenvoegingen" ON "public"."product_merges" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



ALTER TABLE "public"."deals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "eigen profiel aanmaken" ON "public"."profiles" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "eigen profiel en lijstgenoten zien" ON "public"."profiles" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."list_members" "m"
  WHERE (("m"."user_id" = "profiles"."user_id") AND "public"."is_member"("m"."list_id"))))));



CREATE POLICY "eigen profiel wijzigen" ON "public"."profiles" FOR UPDATE USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "ingelogden lezen deals" ON "public"."deals" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "leden verwijderen aankopen" ON "public"."purchases" FOR DELETE USING ("public"."is_member"("list_id"));



CREATE POLICY "leden verwijderen items" ON "public"."items" FOR DELETE USING ("public"."is_member"("list_id"));



CREATE POLICY "leden voegen items toe" ON "public"."items" FOR INSERT WITH CHECK (("public"."is_member"("list_id") AND (EXISTS ( SELECT 1
   FROM "public"."lists" "l"
  WHERE (("l"."id" = "items"."list_id") AND ("l"."archived_at" IS NULL))))));



CREATE POLICY "leden wijzigen items" ON "public"."items" FOR UPDATE USING ("public"."is_member"("list_id"));



CREATE POLICY "leden zien aankopen" ON "public"."purchases" FOR SELECT USING ("public"."is_member"("list_id"));



CREATE POLICY "leden zien bonnen" ON "public"."receipts" FOR SELECT USING ("public"."is_member"("list_id"));



CREATE POLICY "leden zien items" ON "public"."items" FOR SELECT USING ("public"."is_member"("list_id"));



CREATE POLICY "leden zien leden" ON "public"."list_members" FOR SELECT USING ("public"."is_member"("list_id"));



CREATE POLICY "leden zien lijst" ON "public"."lists" FOR SELECT USING ("public"."is_member"("id"));



ALTER TABLE "public"."list_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_aliases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_merges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."purchases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."receipts" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."items";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."list_members";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."lists";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."purchases";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



















































































































































































































































GRANT ALL ON TABLE "public"."lists" TO "anon";
GRANT ALL ON TABLE "public"."lists" TO "authenticated";
GRANT ALL ON TABLE "public"."lists" TO "service_role";



GRANT ALL ON FUNCTION "public"."archive_list"("p_list" "uuid", "p_archived" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."archive_list"("p_list" "uuid", "p_archived" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."archive_list"("p_list" "uuid", "p_archived" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."buy_item"("p_item" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."buy_item"("p_item" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."buy_item"("p_item" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_list"("p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_list"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_list"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."deals_for_list"("p_list" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."deals_for_list"("p_list" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."deals_for_list"("p_list" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_list"("p_list" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_list"("p_list" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_list"("p_list" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_receipt"("p_receipt" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_receipt"("p_receipt" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_receipt"("p_receipt" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."ensure_product"() TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_product"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_product"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_member"("p_list" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_member"("p_list" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_member"("p_list" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."join_list"("p_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."join_list"("p_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."join_list"("p_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_receipt_lines"("p_list" "uuid", "p_date" "date", "p_names" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."match_receipt_lines"("p_list" "uuid", "p_date" "date", "p_names" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_receipt_lines"("p_list" "uuid", "p_date" "date", "p_names" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."merge_products"("p_source" "uuid", "p_target" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_products"("p_source" "uuid", "p_target" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_products"("p_source" "uuid", "p_target" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."merge_products_internal"("p_source" "uuid", "p_target" "uuid", "p_by" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merge_products_internal"("p_source" "uuid", "p_target" "uuid", "p_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."product_overview"() TO "anon";
GRANT ALL ON FUNCTION "public"."product_overview"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."product_overview"() TO "service_role";



GRANT ALL ON FUNCTION "public"."receipt_exists"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."receipt_exists"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."receipt_exists"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_member"("p_list" "uuid", "p_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_member"("p_list" "uuid", "p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_member"("p_list" "uuid", "p_user" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "service_role";
GRANT SELECT ON TABLE "public"."products" TO "authenticated";



GRANT ALL ON FUNCTION "public"."rename_product"("p_product" "uuid", "p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rename_product"("p_product" "uuid", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rename_product"("p_product" "uuid", "p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."save_receipt"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric, "p_lines" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."save_receipt"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric, "p_lines" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_receipt"("p_list" "uuid", "p_store" "text", "p_date" "date", "p_total" numeric, "p_lines" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_list_profile"("p_list" "uuid", "p_counts" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_list_profile"("p_list" "uuid", "p_counts" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_list_profile"("p_list" "uuid", "p_counts" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."undo_merge"("p_merge" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."undo_merge"("p_merge" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."undo_merge"("p_merge" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."undo_purchase"("p_purchase" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."undo_purchase"("p_purchase" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."undo_purchase"("p_purchase" "uuid") TO "service_role";


















GRANT ALL ON TABLE "public"."admins" TO "service_role";



GRANT ALL ON TABLE "public"."deals" TO "service_role";
GRANT SELECT ON TABLE "public"."deals" TO "authenticated";



GRANT ALL ON TABLE "public"."items" TO "anon";
GRANT ALL ON TABLE "public"."items" TO "authenticated";
GRANT ALL ON TABLE "public"."items" TO "service_role";



GRANT ALL ON TABLE "public"."list_members" TO "anon";
GRANT ALL ON TABLE "public"."list_members" TO "authenticated";
GRANT ALL ON TABLE "public"."list_members" TO "service_role";



GRANT ALL ON TABLE "public"."product_aliases" TO "service_role";
GRANT SELECT ON TABLE "public"."product_aliases" TO "authenticated";



GRANT ALL ON TABLE "public"."product_merges" TO "service_role";
GRANT SELECT ON TABLE "public"."product_merges" TO "authenticated";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."purchases" TO "service_role";
GRANT SELECT,DELETE ON TABLE "public"."purchases" TO "authenticated";



GRANT ALL ON TABLE "public"."receipts" TO "service_role";
GRANT SELECT ON TABLE "public"."receipts" TO "authenticated";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































