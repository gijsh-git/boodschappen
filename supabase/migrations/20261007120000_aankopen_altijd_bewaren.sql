-- Aankopen worden altijd bewaard, ook op een lijst die niet meetelt voor het aankoopprofiel.
--
-- Was: buy_item bewaarde een aankoop alleen als lists.counts_for_profile aan stond, dus op een lijst die niet
-- meetelt was het scherm "Aankopen" leeg.
-- Wordt: de aankoop staat er altijd. Of hij meetelt voor het profiel bepaalt purchase_profile bij het uitlezen
-- (die telt alleen lijsten met counts_for_profile), zodat de schakelaar ook achteraf nog iets doet.
-- Een bon scannen blijft alleen bij lijsten die meetellen: save_receipt weigert de andere.
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
  insert into public.purchases (list_id, item_id, name, quantity, added_by, item_created_at, bought_by)
  values (i.list_id, i.id, i.name, i.quantity, i.added_by, i.created_at, auth.uid())
  returning id into v_id;
  return v_id;
end $$;
