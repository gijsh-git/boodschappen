-- Een lijst verlaten: elke deelnemer kan zichzelf uit een lijst halen.
--
-- De maker kan dat niet: een lijst zonder maker kan niemand meer archiveren, verwijderen of van beheerders voorzien.
-- De maker archiveert of verwijdert de lijst in plaats daarvan.
-- Aankopen en bonnen van de lijst blijven staan; ze tellen alleen niet meer mee in jouw aankoopprofiel,
-- want dat telt de lijsten waarvan je lid bent.
create or replace function public.leave_list(p_list uuid) returns void
    language plpgsql security definer
    set search_path to 'public'
    as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd'; end if;
  if exists (select 1 from public.lists where id = p_list and created_by = auth.uid()) then
    raise exception 'Als maker kun je je eigen lijst niet verlaten. Archiveer of verwijder de lijst.';
  end if;
  delete from public.list_members where list_id = p_list and user_id = auth.uid();
  if not found then raise exception 'Je bent geen deelnemer van deze lijst'; end if;
  -- De uitnodigingen die je nog openstond hebt vervallen, zoals bij het verwijderen van een deelnemer
  delete from public.list_invites where list_id = p_list and created_by = auth.uid();
end $$;
revoke all on function public.leave_list(uuid) from public, anon;
grant execute on function public.leave_list(uuid) to authenticated, service_role;
