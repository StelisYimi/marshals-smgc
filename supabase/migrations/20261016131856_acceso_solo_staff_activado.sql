-- Usuario de acceso (sin correo obligatorio) y alta controlada por Gerencia
alter table perfiles add column usuario text unique;
alter table perfiles alter column activo set default false;

-- Un perfil solo nace activo si la cuenta la creó Gerencia (app_metadata solo lo escribe el servidor)
create or replace function privado.crear_perfil_nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (id, nombre, usuario, activo)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
          new.raw_app_meta_data->>'usuario',
          coalesce((new.raw_app_meta_data->>'alta_gerencia')::boolean, false));
  return new;
end $$;

create or replace function privado.es_activo() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select activo from perfiles where id = auth.uid()), false)
$$;
revoke execute on function privado.es_activo() from public, anon;
grant execute on function privado.es_activo() to authenticated;

-- Configuración del sistema (solo la lee el servidor: RLS sin políticas)
create table config_sistema (clave text primary key, valor text not null);
alter table config_sistema enable row level security;

-- Candado general: toda lectura o escritura exige un perfil activo
create policy solo_staff on perfiles             as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on areas_checklist      as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on items_checklist      as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on reportes_turno       as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on respuestas_checklist as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on validaciones         as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on incidencias          as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on incidencia_fotos     as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff_fotos on storage.objects as restrictive for all to authenticated
  using (bucket_id <> 'incidencias' or (select privado.es_activo()))
  with check (bucket_id <> 'incidencias' or (select privado.es_activo()));

-- Cada persona puede ver su propio perfil aunque esté inactivo (para mostrar "cuenta desactivada")
create or replace function public.mi_perfil() returns table (id uuid, nombre text, usuario text, rol rol_usuario, activo boolean)
language sql stable security definer set search_path = public as $$
  select id, nombre, usuario, rol, activo from perfiles where id = auth.uid()
$$;
revoke execute on function public.mi_perfil() from public, anon;
grant execute on function public.mi_perfil() to authenticated;

-- Índices de llaves foráneas
create index on incidencia_fotos (incidencia_id);
create index on incidencias (autor_id);
create index on items_checklist (area);
create index on respuestas_checklist (item_id);
create index on validaciones (validado_por);
