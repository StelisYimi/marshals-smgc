-- Starter: novedades medibles del Impact Filter (criterios 5, 9 y 10)
--   salida_no_coordinada · salida anticipada o adicional sin coordinar con el Marshal (meta 0)
--   ausencia_sin_relevo  · tee sin atender sin relevo coordinado con el Capitán (meta 0)
--   reclamo / incidente  · deben quedar escalados al Capitán en el mismo turno (meta 100%)
create table st_novedades (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null default (now() at time zone 'America/Panama')::date,
  turno          turno_tipo not null,
  tee            smallint not null default 1 check (tee in (1, 10)),
  tipo           text not null check (tipo in ('salida_no_coordinada','ausencia_sin_relevo','reclamo','incidente')),
  nota           text,
  escalado       boolean not null default false,
  escalado_a     uuid references perfiles(id),
  hora           timestamptz not null default now(),
  registrado_por uuid not null default auth.uid() references perfiles(id));
create index on st_novedades (fecha desc);
create index on st_novedades (registrado_por);
create index on st_novedades (escalado_a);

alter table st_novedades enable row level security;
create policy leer on st_novedades for select to authenticated using ((select privado.es_starter()));
create policy crear on st_novedades for insert to authenticated
  with check ((select privado.es_starter()) and registrado_por = (select auth.uid()));
create policy editar on st_novedades for update to authenticated
  using (registrado_por = (select auth.uid()) or (select privado.es_capitania()))
  with check ((select privado.es_starter()));
create policy borrar on st_novedades for delete to authenticated
  using (registrado_por = (select auth.uid()) or (select privado.es_capitania()));
create policy solo_staff on st_novedades as restrictive for all to authenticated
  using ((select privado.es_activo())) with check ((select privado.es_activo()));

alter publication supabase_realtime add table st_novedades;
