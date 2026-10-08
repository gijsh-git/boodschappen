-- Een aanbieding uit "Voor jou" komt met haar eigen naam op de lijst, niet met de naam van het vaste product.
--
-- Was: bij een aanbieding die via het aankoopprofiel telt zette de app de productnaam op de lijst ("Brood"),
-- terwijl op het scherm "AH Bakkersbrood tijgerbrood volkoren heel" stond.
-- Wordt: de titel van de aanbieding komt op de lijst, en het item onthoudt welk artikel het is en bij welk
-- product uit de catalogus het hoort.
--
-- De koppeling item → product blijft overal via de naam lopen (normalized_name → product_aliases); daar
-- verandert niets aan. Daarom wordt de titel een naam van het catalogusproduct: add_offer_item voegt het
-- product dat ensure_product voor de titel aanmaakt samen met het product van de artikelen in de aanbieding.
-- Aankoopprofiel, Bonus-label en het afstrepen via een bon werken daardoor vanzelf op het catalogusproduct.
-- De kolommen op items leggen vast wat er is toegevoegd.
--
-- Wijzigt een bestaande tabel (items krijgt drie kolommen, leeg bij alle bestaande rijen) en een bestaande
-- functie (merge_products_internal, zelfde signatuur).

-- ---------- Kolommen ----------
alter table public.items add column article_supermarket text;
alter table public.items add column article_id text;
alter table public.items add column product_id uuid references public.products(id) on delete set null;
-- articles wordt nooit opgeruimd, dus deze verwijzing blijft geldig
alter table public.items add constraint items_article_fkey
  foreign key (article_supermarket, article_id) references public.articles(supermarket, article_id);
create index items_product_idx on public.items (product_id) where product_id is not null;

comment on column public.items.article_id is
  'Het exacte artikel waarmee dit item vanuit "Voor jou" op de lijst is gezet (met article_supermarket); leeg bij een gewoon item en bij een aanbieding met meerdere artikelen.';
comment on column public.items.product_id is
  'Het product uit de catalogus op het moment van toevoegen vanuit "Voor jou"; leeg bij een gewoon item. Alleen een vastlegging: de matching loopt via normalized_name en product_aliases.';

-- ---------- Samenvoegen ----------
-- Als voorheen, met erbij: items die naar de bron wijzen gaan mee naar het doel. Losmaken zet dat niet terug;
-- de matching volgt de alias, en die wordt wel hersteld.
create or replace function public.merge_products_internal(p_source uuid, p_target uuid, p_by uuid) returns uuid
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  v_naam text;
  v_telt boolean;
  v_namen text[];
  v_koppelingen jsonb;
  v_afwijzingen jsonb;
  v_id uuid;
begin
  if p_source = p_target then raise exception 'Kies twee verschillende producten'; end if;
  select name, counts_in_profile into v_naam, v_telt from public.products where id = p_source for update;
  if not found then raise exception 'Product niet gevonden'; end if;
  if not exists (select 1 from public.products where id = p_target) then
    raise exception 'Product niet gevonden';
  end if;
  select coalesce(array_agg(normalized_name order by normalized_name), '{}') into v_namen
    from public.product_aliases where product_id = p_source;

  with verhuisd as (
    update public.article_links set product_id = p_target where product_id = p_source
    returning supermarket, article_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('supermarket', supermarket, 'article_id', article_id)), '[]'::jsonb)
    into v_koppelingen from verhuisd;

  select coalesce(jsonb_agg(jsonb_build_object(
           'supermarket', r.supermarket, 'article_id', r.article_id,
           'rejected_at', r.rejected_at, 'rejected_by', r.rejected_by,
           'moved', not exists (
             select 1 from public.article_link_rejections t
             where t.supermarket = r.supermarket and t.article_id = r.article_id and t.product_id = p_target))), '[]'::jsonb)
    into v_afwijzingen
    from public.article_link_rejections r where r.product_id = p_source;
  delete from public.article_link_rejections r
   where r.product_id = p_source
     and exists (
       select 1 from public.article_link_rejections t
       where t.supermarket = r.supermarket and t.article_id = r.article_id and t.product_id = p_target);
  update public.article_link_rejections set product_id = p_target where product_id = p_source;

  insert into public.product_merges (target_id, source_id, source_name, aliases, merged_by, source_counts_in_profile,
                                     article_links, article_rejections)
    values (p_target, p_source, v_naam, v_namen, p_by, v_telt, v_koppelingen, v_afwijzingen) returning id into v_id;
  update public.product_aliases set product_id = p_target where product_id = p_source;
  update public.items set product_id = p_target where product_id = p_source;
  delete from public.products where id = p_source;
  return v_id;
end $$;

-- ---------- Aanbieding op de lijst ----------
-- Zet een aanbieding uit "Voor jou" op de lijst en geeft het nieuwe item terug.
--   naam:     de titel van de aanbieding, zonder het sterretje dat naar de kleine lettertjes verwijst. Staat
--             daarna vast in items.name: een latere wijziging van de titel of van een productnaam raakt de lijst niet.
--   artikel:  alleen als de aanbieding precies één artikel heeft.
--   product:  het product van de artikelen in de aanbieding (article_products()), alleen als dat er precies één
--             is. Bij geen of meerdere (een groep met brood en stokbrood) krijgt de titel een eigen product,
--             zoals elk nieuw item.
-- Het item komt er altijd als nieuwe rij bij, ook als er al een item van hetzelfde product op de lijst staat.
--
-- Security definer omdat article_products() aankopen van alle lijsten leest en omdat het samenvoegen een
-- beheerdersactie is. Het doel van die samenvoeging komt uit de database (een bon of een goedgekeurde
-- koppeling), nooit van de client, en ze staat in product_merges, dus de beheerder kan haar losmaken.
create function public.add_offer_item(p_list uuid, p_offer uuid) returns public.items
    language plpgsql security definer
    set search_path to 'public'
    as $$
declare
  v_naam text;
  v_zoek text;
  v_artikelen integer;
  v_supermarkt text;
  v_artikel text;
  v_producten uuid[];
  v_doel uuid;
  v_had_naam boolean;
  v_product uuid;
  i public.items;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  if not public.is_member(p_list) then raise exception 'Lijst niet gevonden'; end if;
  if exists (select 1 from public.lists where id = p_list and archived_at is not null) then
    raise exception 'Deze lijst is gearchiveerd';
  end if;

  select btrim(regexp_replace(title, '\s*\*+$', '')) into v_naam from public.offers where id = p_offer;
  if not found or coalesce(v_naam, '') = '' then raise exception 'Aanbieding niet gevonden'; end if;
  v_naam := upper(left(v_naam, 1)) || substr(v_naam, 2);
  v_zoek := lower(btrim(v_naam));

  select count(*), min(supermarket), min(article_id) into v_artikelen, v_supermarkt, v_artikel
    from public.offer_articles where offer_id = p_offer;
  if v_artikelen <> 1 then
    v_supermarkt := null;
    v_artikel := null;
  end if;

  select array_agg(distinct ap.product_id) into v_producten
    from public.offer_articles oa
    join public.article_products() ap on ap.supermarket = upper(oa.supermarket) and ap.article_id = oa.article_id
   where oa.offer_id = p_offer;
  if cardinality(v_producten) = 1 then v_doel := v_producten[1]; end if;

  v_had_naam := exists (select 1 from public.product_aliases where normalized_name = v_zoek);

  insert into public.items (list_id, name, offer_id, article_supermarket, article_id, added_by)
  values (p_list, v_naam, p_offer, v_supermarkt, v_artikel, auth.uid())
  returning * into i;

  -- ensure_product heeft de naam nu een product gegeven als ze er nog geen had
  select product_id into v_product from public.product_aliases where normalized_name = i.normalized_name;
  -- Alleen een naam die net nieuw is gaat naar het catalogusproduct: een naam die al bestond staat waar de
  -- beheerder haar wil hebben. De extra controle op "alleen deze ene naam" voorkomt dat een product dat
  -- intussen meer is geworden mee verhuist.
  if not v_had_naam and v_doel is not null and v_product is not null and v_product <> v_doel
     and not exists (select 1 from public.product_aliases
                     where product_id = v_product and normalized_name <> i.normalized_name) then
    perform public.merge_products_internal(v_product, v_doel, auth.uid());
    v_product := v_doel;
  end if;

  update public.items set product_id = v_product where id = i.id returning * into i;
  return i;
end $$;

-- ---------- Rechten ----------
revoke all on function public.add_offer_item(uuid, uuid) from public, anon;
grant execute on function public.add_offer_item(uuid, uuid) to authenticated, service_role;
