-- De AI beoordeelt een term die nergens voor staat, direct bij het toevoegen (overstap naar producttypes, fase 5).
--
-- handle_unmatched_term() blijft het ene afhandelpunt. Het noteert de term in unmatched_terms en geeft daarna
-- een seintje aan de Edge Function term-classificeren (via pg_net; het verzoek gaat pas weg na de commit).
-- Die haalt alle open termen op met term_work(), laat de AI per term een type kiezen (en eventueel een merk)
-- en slaat dat op met save_term_judgments(): als naam in term_synonyms met bron ai en de datum, zonder
-- goedkeuring vooraf. Het item op de lijst krijgt zijn type_id, en die wijziging komt via realtime bij alle
-- deelnemers binnen, waarop de app de labels opnieuw ophaalt.
--
-- Het adres van de functie en de sleutel staan in Supabase Vault (gegevens, geen structuur), onder de namen
-- term_classificeren_url en aanbiedingen_sleutel. Zonder die twee doet het seintje niets en blijft de term
-- alleen genoteerd; de wekelijkse ronde (scripts/ah-bonus-opslaan.py) pakt open termen ook mee.
-- Naar de AI gaan alleen de termen en de typelijst, geen gebruikers of lijsten.

create extension if not exists pg_net with schema extensions;

-- Wanneer een aanroep van de Edge Function de term heeft opgepakt, zodat een foto met vijftien onbekende
-- items niet vijftien keer dezelfde termen laat beoordelen.
alter table public.unmatched_terms add column claimed_at timestamptz;

-- ---------- Het seintje ----------
create function public.kick_term_classifier() returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_url text;
  v_sleutel text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'term_classificeren_url';
  select decrypted_secret into v_sleutel from vault.decrypted_secrets where name = 'aanbiedingen_sleutel';
  if coalesce(v_url, '') = '' or coalesce(v_sleutel, '') = '' then return; end if;
  -- WACHTTIJD: zo lang wacht pg_net op het antwoord; de functie beoordeelt in die tijd de open termen
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-aanbiedingen-sleutel', v_sleutel),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000);
end $$;

-- Het ene punt waar een term terechtkomt die nergens voor staat: noteren, en de AI een seintje geven.
-- Een fout bij het seintje mag het noteren niet ongedaan maken.
create or replace function public.handle_unmatched_term(p_name text) returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if public.match_key(p_name) = '' then return; end if;
  insert into public.unmatched_terms (key, term)
  values (public.match_key(p_name), btrim(p_name))
  on conflict (key) do update
    set term = excluded.term, times = public.unmatched_terms.times + 1, last_seen = now();
  begin
    perform public.kick_term_classifier();
  exception when others then
    raise warning 'kick_term_classifier: %', sqlerrm;
  end;
end $$;

-- ---------- Ook aankopen ----------
-- Een nieuwe naam op een bon, of een item dat alleen via een gelijkende naam een label had, heeft als aankoop
-- nog geen type. Zo'n naam gaat langs hetzelfde punt. Een losse merknaam staat al ergens voor en blijft zonder
-- type. Een fout hier mag het opslaan van een aankoop nooit tegenhouden.
create function public.check_purchase_term() returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  begin
    if public.name_type(new.name) is null
       and not exists (select 1 from public.term_synonyms s where s.key = public.match_key(new.name))
       and not exists (select 1 from public.articles x
                       where x.brand_key = public.match_key(new.name) and x.brand_key <> '') then
      perform public.handle_unmatched_term(new.name);
    end if;
  exception when others then
    raise warning 'check_purchase_term: %', sqlerrm;
  end;
  return new;
end $$;

create trigger purchases_term after insert or update of name on public.purchases
  for each row execute function public.check_purchase_term();

-- ---------- Het werk voor de Edge Function ----------
-- { gelezen_op, termen: [{ sleutel, term }], types: [{ id, naam, hoofdgroep, valt_eronder, valt_er_niet_onder }] }
-- Pakt de open termen op (nog niet beoordeeld en niet net door een andere aanroep opgepakt), hooguit
-- p_limit, de nieuwste eerst. Een term die intussen een naam van een type is geworden geldt als beoordeeld.
create function public.term_work(p_limit integer default 40) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_termen jsonb;
begin
  update public.unmatched_terms u set judged_at = now()
   where u.judged_at is null
     and (exists (select 1 from public.term_synonyms s where s.key = u.key)
          or exists (select 1 from public.product_types p where p.key = u.key));

  with kies as (
    select u.key from public.unmatched_terms u
    where u.judged_at is null
      -- OPNIEUW OPPAKKEN: na zoveel tijd geldt een eerdere aanroep als mislukt
      and (u.claimed_at is null or u.claimed_at < now() - interval '3 minutes')
    order by u.last_seen desc
    limit greatest(1, least(coalesce(p_limit, 40), 200))
    for update skip locked
  ),
  pak as (
    update public.unmatched_terms u set claimed_at = now()
    from kies where u.key = kies.key
    returning u.key, u.term
  )
  select coalesce(jsonb_agg(jsonb_build_object('sleutel', pak.key, 'term', pak.term) order by pak.term), '[]'::jsonb)
    into v_termen from pak;

  return jsonb_build_object(
    'gelezen_op', now(),
    'termen', v_termen,
    'types', case when jsonb_array_length(v_termen) = 0 then '[]'::jsonb else (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'naam', p.name, 'hoofdgroep', p.main_group,
               'valt_eronder', p.scope, 'valt_er_niet_onder', p.excludes)
             order by p.main_group, p.name, p.id), '[]'::jsonb)
      from public.product_types p) end);
end $$;

-- ---------- Oordelen opslaan ----------
-- p_rows: [{ term, type_id, brand, confidence, reason }]; type_id null is "geen type". Een merk dat bij geen
-- enkel artikel hoort vervalt. Slaat de namen op met bron ai (save_term_types_internal bewaakt wat voorgaat),
-- markeert de termen als beoordeeld en zet het type bij de items op de lijsten met die naam: die wijziging
-- is het signaal waarop de app de labels opnieuw ophaalt.
create function public.save_term_judgments(p_rows jsonb) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_rijen jsonb;
  v_uit jsonb;
  v_items integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Geen oordelen om op te slaan'; end if;
  select coalesce(jsonb_agg(
           case when exists (select 1 from public.articles x
                             where x.brand_key = public.match_key(r->>'brand') and x.brand_key <> '')
                then r else r - 'brand' end), '[]'::jsonb)
    into v_rijen
  from jsonb_array_elements(p_rows) r;

  v_uit := public.save_term_types_internal(v_rijen, 'ai');

  update public.unmatched_terms u set judged_at = now()
   where u.key in (select public.match_key(r->>'term') from jsonb_array_elements(v_rijen) r);

  -- Het type zoals het nu geldt: een rij van de beheerder of uit de catalogus gaat voor het oordeel van de AI
  update public.items i set type_id = s.type_id
    from public.term_synonyms s
   where s.key in (select public.match_key(r->>'term') from jsonb_array_elements(v_rijen) r)
     and s.type_id is not null
     and public.match_key(i.name) = s.key
     and i.offer_id is null
     and i.type_id is distinct from s.type_id;
  get diagnostics v_items = row_count;

  return v_uit || jsonb_build_object('items', v_items);
end $$;

-- ---------- Rechten ----------
revoke all on function public.kick_term_classifier() from public, anon, authenticated;
revoke all on function public.check_purchase_term() from public, anon, authenticated;
revoke all on function public.term_work(integer) from public, anon, authenticated;
revoke all on function public.save_term_judgments(jsonb) from public, anon, authenticated;
grant execute on function public.term_work(integer) to service_role;
grant execute on function public.save_term_judgments(jsonb) to service_role;
