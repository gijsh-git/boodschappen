-- Een winkel uitvinken lukte niet: keep_last_store leest auth.users, maar draaide met de rechten van de
-- gebruiker, en die mag auth.users niet lezen ("permission denied for table users"). Nu security definer,
-- net als give_default_store.
create or replace function public.keep_last_store() returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if exists (select 1 from auth.users u where u.id = old.user_id)
     and not exists (select 1 from public.user_stores s
                     where s.user_id = old.user_id and s.supermarket <> old.supermarket) then
    raise exception 'Je moet minstens één winkel overhouden';
  end if;
  return old;
end $$;
