-- De oordelen van de beheerder over niveau 2 in één keer teruglezen, om ze buiten de app te laten nalezen
-- (scripts/artikel-koppelingen-exporteren.py).
--
-- article_link_overview() geeft alleen de voorstellen en de goedgekeurde koppelingen. De afwijzingen waren
-- via geen enkele functie te lezen: article_link_rejections heeft geen policies en geen rechten. Deze functie
-- leest alleen en verandert niets aan bestaande tabellen of functies.

-- Geeft { goedgekeurd: [...], afgewezen: [...], producten: [namen] }.
-- goedgekeurd: zoals 'gekoppeld' in article_link_overview(), dus zonder artikelen die op een bon staan (daar
--   wint de bon). afgewezen: de combinaties van artikel en product; de zekerheid en de reden van het voorstel
--   zijn bij het afwijzen niet bewaard. producten: alle productnamen, zodat een lezer kan zien of een artikel
--   beter bij een ander product past.
create function public.article_link_review() returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'Alleen de beheerder kan de koppelingen nalezen'; end if;
  return jsonb_build_object(
    'goedgekeurd', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supermarkt', l.supermarket, 'artikel_id', l.article_id, 'titel', x.title, 'merk', x.brand,
               'inhoud', x.size, 'categorie', x.category, 'product', p.name,
               'zekerheid', l.confidence, 'reden', l.reason, 'bron', l.source, 'op', l.reviewed_at)
             order by lower(p.name), x.title)
      from public.article_links l
      join public.articles x on x.supermarket = l.supermarket and x.article_id = l.article_id
      join public.products p on p.id = l.product_id
      where l.status = 'approved'
        and not public.article_on_receipt(l.supermarket, l.article_id)), '[]'::jsonb),
    'afgewezen', coalesce((
      select jsonb_agg(jsonb_build_object(
               'supermarkt', r.supermarket, 'artikel_id', r.article_id, 'titel', x.title, 'merk', x.brand,
               'inhoud', x.size, 'categorie', x.category, 'product', p.name, 'op', r.rejected_at)
             order by lower(p.name), x.title)
      from public.article_link_rejections r
      join public.articles x on x.supermarket = r.supermarket and x.article_id = r.article_id
      join public.products p on p.id = r.product_id), '[]'::jsonb),
    'producten', coalesce((select jsonb_agg(p.name order by lower(p.name)) from public.products p), '[]'::jsonb));
end $$;

revoke all on function public.article_link_review() from public, anon;
grant execute on function public.article_link_review() to authenticated, service_role;
