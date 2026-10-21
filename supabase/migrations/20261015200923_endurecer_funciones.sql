alter function public.tocar_actualizado() set search_path = public;

create schema if not exists privado;
grant usage on schema privado to authenticated;
alter function public.mi_rol() set schema privado;
alter function public.es_gerencia() set schema privado;
create or replace function privado.es_gerencia() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(privado.mi_rol() in ('gerente_operaciones','gerente_golf','admin'), false)
$$;
revoke execute on function privado.mi_rol(), privado.es_gerencia() from public, anon;
grant execute on function privado.mi_rol(), privado.es_gerencia() to authenticated;

alter function public.crear_perfil_nuevo_usuario() set schema privado;
revoke execute on function privado.crear_perfil_nuevo_usuario() from public, anon, authenticated;

revoke execute on function public.firmar_reporte(uuid) from public, anon;
grant execute on function public.firmar_reporte(uuid) to authenticated;
