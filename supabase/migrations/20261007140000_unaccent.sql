-- De extensie unaccent, om bij het matchen van favorieten (roadmap stap 4 en 5) accenten te negeren:
-- "calve" en "Calvé" zijn hetzelfde merk. Alleen de extensie; de tabel favorites komt in een eigen migratie.
create extension if not exists "unaccent" with schema "extensions";
