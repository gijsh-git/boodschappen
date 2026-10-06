-- Controlequeries voor het aankoopprofiel (stap 3b).
-- Leg de uitkomst naast Mijn profiel.
--
-- De SQL Editor toont alleen de uitkomst van de laatste opdracht, en de instellingen en views
-- hieronder gelden alleen binnen dezelfde run. Plak daarom steeds het blok "Voorbereiding"
-- (tot en met de view controle_periode) met daaronder precies één genummerde query, en draai dat samen.
--
-- In de SQL Editor ben je niet ingelogd als gebruiker van de app. Vul daarom je e-mailadres in,
-- en kies dezelfde periode en lijst als in de app.
--   periode: '4w', '3m', '12m' of 'alles'
--   lijst:   de naam van één lijst, of leeg voor alle lijsten

-- ---------- Voorbereiding ----------
select set_config('controle.email', 'JOUW-EMAIL', false),
       set_config('controle.periode', '3m', false),
       set_config('controle.lijst', '', false);

-- De aankopen die meedoen: lijsten waarvan je deelnemer bent en die meetellen, met per aankoop
-- de dag in Nederlandse tijd, het product en de vlag. Elke query hieronder begint hiermee.
create or replace temporary view controle_aankopen as
select a.id, a.name, a.price, a.discount,
       (a.bought_at at time zone 'Europe/Amsterdam')::date as dag,
       coalesce(pr.name, a.name) as product,
       coalesce(pr.counts_in_profile, true) as telt_mee,
       r.store as supermarkt
from public.purchases a
join public.lists l on l.id = a.list_id and l.counts_for_profile
join public.list_members m on m.list_id = l.id
join auth.users u on u.id = m.user_id and u.email = current_setting('controle.email')
left join public.product_aliases pa on pa.normalized_name = a.normalized_name
left join public.products pr on pr.id = pa.product_id
left join public.receipts r on r.id = a.receipt_id
where current_setting('controle.lijst') = '' or l.name = current_setting('controle.lijst');

-- Dezelfde aankopen, maar alleen binnen de gekozen periode
create or replace temporary view controle_periode as
select * from controle_aankopen
where dag >= case current_setting('controle.periode')
               when '4w' then (now() at time zone 'Europe/Amsterdam')::date - 28
               when '3m' then ((now() at time zone 'Europe/Amsterdam')::date - interval '3 months')::date
               when '12m' then ((now() at time zone 'Europe/Amsterdam')::date - interval '12 months')::date
               else date '0001-01-01'
             end;

-- ---------- Queries: steeds één onder de voorbereiding ----------

-- 1. Aantal aankopen (zonder producten met de vlag "telt niet mee")
select count(*) as aankopen from controle_periode where telt_mee;

-- 2. Aantal verschillende producten (zonder producten met de vlag)
select count(distinct product) as producten from controle_periode where telt_mee;

-- 3. Uitgegeven: prijs min korting, over alle aankopen met een prijs (ook met de vlag)
select sum(price - coalesce(discount, 0)) as uitgegeven from controle_periode where price is not null;

-- 4. Bespaard: de korting, over alle aankopen met een prijs
select sum(coalesce(discount, 0)) as bespaard from controle_periode where price is not null;

-- 5. Prijs bekend: aantal met prijs, alle aankopen (ook met de vlag) en het percentage
select count(price) as met_prijs, count(*) as alle_aankopen,
       round(100.0 * count(price) / nullif(count(*), 0)) as procent
from controle_periode;

-- 6. Top 10: aantal aankoopdagen per product in de periode
select product, count(distinct dag) as aankoopdagen, max(dag) as laatste
from controle_periode where telt_mee
group by product
order by aankoopdagen desc, laatste desc, product
limit 10;

-- 7. Interval van één product: alle aankoopdagen (alle data) met de tussenpoos ernaast.
--    De app toont de mediaan van de tussenpozen, vanaf 3 aankoopdagen. Vul de productnaam in.
select dag, dag - lag(dag) over (order by dag) as dagen_sinds_vorige
from (select distinct dag from controle_aankopen where product = 'brood') d
order by dag;

-- 8. Per supermarkt in de periode: aantal aankopen (zonder vlag) en bedrag (met vlag)
select coalesce(supermarkt, 'onbekend') as supermarkt,
       count(*) filter (where telt_mee) as aankopen,
       sum(price - coalesce(discount, 0)) as bedrag
from controle_periode
group by supermarkt
order by aankopen desc;

-- 9. Uitgaven per maand, laatste 12 maanden (alle data, los van de periode). Leeg bedrag = geen prijsdata.
select to_char(dag, 'YYYY-MM') as maand, sum(price - coalesce(discount, 0)) as bedrag
from controle_aankopen
where dag >= (date_trunc('month', (now() at time zone 'Europe/Amsterdam')) - interval '11 months')::date
group by 1
order by 1;

-- 10. Welke producten hebben de vlag "telt niet mee"?
select name from public.products where not counts_in_profile order by name;
