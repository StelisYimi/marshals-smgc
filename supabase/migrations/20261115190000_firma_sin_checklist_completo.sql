-- Firma siempre permitida: el colaborador puede firmar aunque el checklist esté incompleto.
-- La app avisa qué falta y pide confirmación; Gerencia ve lo que quedó sin responder.
-- Se conservan los controles de quién puede firmar y de reporte ya firmado.

create or replace function public.firmar_reporte(p_reporte uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare r reportes_turno;
begin
  select * into r from reportes_turno where id = p_reporte for update;
  if r.id is null or r.marshal_id <> auth.uid() then raise exception 'Reporte no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El reporte ya está firmado'; end if;
  update reportes_turno set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $function$;

create or replace function public.firmar_reporte_capitan(p_reporte uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare r cap_reportes;
begin
  select * into r from cap_reportes where id = p_reporte for update;
  if r.id is null or r.capitan_id <> auth.uid() then raise exception 'Reporte no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El reporte ya está firmado'; end if;
  update cap_reportes set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $function$;

create or replace function public.firmar_reporte_starter(p_reporte uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare r st_reportes;
begin
  select * into r from st_reportes where id = p_reporte for update;
  if r.id is null or r.starter_id <> auth.uid() then raise exception 'Reporte no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El reporte ya está firmado'; end if;
  update st_reportes set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $function$;

create or replace function public.firmar_reporte_op(p_reporte uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare r op_reportes;
begin
  select * into r from op_reportes where id = p_reporte for update;
  if r.id is null or not (r.personal_id = privado.mi_personal() or privado.es_capitania()) then raise exception 'Checklist no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El checklist ya está firmado'; end if;
  update op_reportes set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $function$;
