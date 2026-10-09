-- Twee producttypes samenvoegen, en artikelen zonder type opnieuw laten beoordelen.
--
-- De typelijst is vast, maar bij het nalezen blijkt soms dat een type onder het wisselniveau zit
-- ("tomatensoep" naast "soep"). save_product_types verwijdert nooit een type; daarvoor is deze functie.
-- scripts/producttypes-laden.py roept beide aan (--samenvoegen bron=doel).
-- Verandert niets aan bestaande tabellen of functies.

-- ---------- Samenvoegen ----------
-- Het type p_source gaat op in p_target (beide bij naam, vergeleken in sleutelvorm): de artikelen en de namen
-- van de bron verhuizen naar het doel, de bron verdwijnt, en de naam van de bron wordt zelf een naam van het
-- doel ("tomatensoep" op de lijst blijft werken). Dit is niet terug te draaien met een knop: het doel weet
-- daarna niet meer welke artikelen van de bron kwamen. Zet het type dan terug in docs/producttypes.csv.
create function public.merge_product_types(p_source text, p_target text) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_bron public.product_types;
  v_doel public.product_types;
  v_artikelen integer;
  v_namen integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan types samenvoegen'; end if;
  select * into v_bron from public.product_types where key = public.match_key(p_source);
  if not found then raise exception 'Het type "%" bestaat niet', p_source; end if;
  select * into v_doel from public.product_types where key = public.match_key(p_target);
  if not found then raise exception 'Het type "%" bestaat niet', p_target; end if;
  if v_bron.id = v_doel.id then raise exception 'Bron en doel zijn hetzelfde type'; end if;

  update public.article_types set type_id = v_doel.id where type_id = v_bron.id;
  get diagnostics v_artikelen = row_count;
  update public.term_synonyms set type_id = v_doel.id where type_id = v_bron.id;
  get diagnostics v_namen = row_count;
  delete from public.product_types where id = v_bron.id;

  -- De naam van de bron is nu vrij en wordt een naam van het doel. Een rij die er toevallig al stond
  -- (de naam was eerder een synoniem) wijst vanaf nu ook naar het doel.
  insert into public.term_synonyms as s (key, term, type_id, source, reason, reviewed_at, reviewed_by)
  values (v_bron.key, v_bron.name, v_doel.id, 'manual', 'Was een eigen type, samengevoegd met "' || v_doel.name || '"',
          now(), auth.uid())
  on conflict (key) do update set
    term = excluded.term, target = null, type_id = excluded.type_id, brand_key = null, source = excluded.source,
    reason = excluded.reason, reviewed_at = excluded.reviewed_at, reviewed_by = excluded.reviewed_by;

  return jsonb_build_object('bron', v_bron.name, 'doel', v_doel.name, 'artikelen', v_artikelen, 'namen', v_namen);
end $$;

-- ---------- Opnieuw beoordelen ----------
-- Haalt de oordelen "geen type" van de AI weg die de beheerder nog niet heeft nagekeken, zodat de volgende
-- ronde van artikelen-classificeren ze opnieuw beoordeelt. Nodig nadat de afbakening van een type is
-- aangepast: een nieuw type geeft vanzelf een herbeoordeling, een gewijzigde tekst niet.
create function public.reset_untyped_articles() returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare v_aantal integer;
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan artikelen opnieuw laten beoordelen'; end if;
  delete from public.article_types where type_id is null and source = 'ai' and reviewed_at is null;
  get diagnostics v_aantal = row_count;
  return v_aantal;
end $$;

revoke all on function public.merge_product_types(text, text) from public, anon;
revoke all on function public.reset_untyped_articles() from public, anon;
grant execute on function public.merge_product_types(text, text) to authenticated, service_role;
grant execute on function public.reset_untyped_articles() to authenticated, service_role;
