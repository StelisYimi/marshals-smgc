-- ============ Checklist diario del Capitán de equipos ============
create table cap_areas (codigo char(1) primary key, nombre text not null, nota text, orden smallint not null);
create table cap_items (
  id text primary key, area char(1) not null references cap_areas(codigo), texto text not null,
  orden smallint not null, activo boolean not null default true);
create index on cap_items (area);

create table cap_reportes (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null default (now() at time zone 'America/Panama')::date,
  turno          turno_tipo not null,
  capitan_id     uuid not null references perfiles(id),
  condiciones    jsonb not null default '{}',   -- velocidad_greens, bandera, obras, regla_carritos, apertura, hora_superintendente
  equipo         jsonb not null default '{}',   -- {starter:{nombre,estado}, range:…, carritos:…, frente:…, divots:…, comodin:…}
  inventario     jsonb not null default '{}',   -- {tarjetas:{nivel,nota}, tees:…, lapices:…, toallas:…, bolas:…, agua:…}
  observaciones  text,
  pendientes     text,
  estado         estado_reporte not null default 'borrador',
  firmado_en     timestamptz,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  unique (fecha, turno, capitan_id));
create index on cap_reportes (fecha desc);
create index on cap_reportes (capitan_id, fecha desc);
create trigger trg_cap_reporte_tocar before update on cap_reportes for each row execute function tocar_actualizado();

create table cap_respuestas (
  reporte_id uuid not null references cap_reportes(id) on delete cascade,
  item_id text not null references cap_items(id),
  valor respuesta_valor not null, nota text, respondido_en timestamptz not null default now(),
  primary key (reporte_id, item_id));
create index on cap_respuestas (item_id);

create table cap_validaciones (
  reporte_id uuid primary key references cap_reportes(id) on delete cascade,
  validado_por uuid not null references perfiles(id),
  validado_en timestamptz not null default now(),
  observaciones text);
create index on cap_validaciones (validado_por);

-- Firma: reglas del turno en el servidor
create or replace function public.firmar_reporte_capitan(p_reporte uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r cap_reportes; faltan int; na_sin_j int; k text;
begin
  select * into r from cap_reportes where id = p_reporte for update;
  if r.id is null or r.capitan_id <> auth.uid() then raise exception 'Reporte no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El reporte ya está firmado'; end if;
  foreach k in array array['velocidad_greens','bandera','regla_carritos','apertura'] loop
    if coalesce(trim(r.condiciones->>k), '') = '' then raise exception 'Complete las condiciones de la cancha'; end if;
  end loop;
  foreach k in array array['starter','range','carritos','frente','divots','comodin'] loop
    if coalesce(r.equipo->k->>'estado', '') = '' then raise exception 'Indique el estado de cada puesto del equipo'; end if;
  end loop;
  foreach k in array array['tarjetas','tees','lapices','toallas','bolas','agua'] loop
    if coalesce(r.inventario->k->>'nivel', '') = '' then raise exception 'Indique el nivel de cada insumo'; end if;
  end loop;
  select count(*) into faltan from cap_items i where i.activo
    and not exists (select 1 from cap_respuestas x where x.reporte_id = p_reporte and x.item_id = i.id);
  if faltan > 0 then raise exception 'Faltan % actividades por responder', faltan; end if;
  select count(*) into na_sin_j from cap_respuestas where reporte_id = p_reporte and valor = 'na' and coalesce(trim(nota),'') = '';
  if na_sin_j > 0 then raise exception 'Justifique % respuestas N/A', na_sin_j; end if;
  update cap_reportes set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $$;
revoke execute on function public.firmar_reporte_capitan(uuid) from public, anon;
grant execute on function public.firmar_reporte_capitan(uuid) to authenticated;

-- Permisos
alter table cap_areas enable row level security;
alter table cap_items enable row level security;
alter table cap_reportes enable row level security;
alter table cap_respuestas enable row level security;
alter table cap_validaciones enable row level security;

create policy leer on cap_areas        for select to authenticated using ((select privado.es_capitania()));
create policy leer on cap_items        for select to authenticated using ((select privado.es_capitania()));
create policy leer on cap_reportes     for select to authenticated using ((select privado.es_capitania()));
create policy leer on cap_respuestas   for select to authenticated using ((select privado.es_capitania()));
create policy leer on cap_validaciones for select to authenticated using ((select privado.es_capitania()));

create policy ger_ins on cap_areas for insert to authenticated with check ((select privado.es_gerencia()));
create policy ger_upd on cap_areas for update to authenticated using ((select privado.es_gerencia())) with check ((select privado.es_gerencia()));
create policy ger_ins on cap_items for insert to authenticated with check ((select privado.es_gerencia()));
create policy ger_upd on cap_items for update to authenticated using ((select privado.es_gerencia())) with check ((select privado.es_gerencia()));

create policy crear  on cap_reportes for insert to authenticated
  with check (capitan_id = (select auth.uid()) and estado = 'borrador' and (select privado.es_capitania()));
create policy editar on cap_reportes for update to authenticated
  using (capitan_id = (select auth.uid()) and estado = 'borrador')
  with check (capitan_id = (select auth.uid()) and estado = 'borrador');

create policy ins on cap_respuestas for insert to authenticated
  with check (exists (select 1 from cap_reportes r where r.id = reporte_id and r.capitan_id = (select auth.uid()) and r.estado = 'borrador'));
create policy upd on cap_respuestas for update to authenticated
  using (exists (select 1 from cap_reportes r where r.id = reporte_id and r.capitan_id = (select auth.uid()) and r.estado = 'borrador'))
  with check (exists (select 1 from cap_reportes r where r.id = reporte_id and r.capitan_id = (select auth.uid()) and r.estado = 'borrador'));

create policy ger_ins on cap_validaciones for insert to authenticated
  with check ((select privado.es_gerencia()) and validado_por = (select auth.uid())
              and exists (select 1 from cap_reportes r where r.id = reporte_id and r.estado = 'firmado'));
create policy ger_upd on cap_validaciones for update to authenticated
  using ((select privado.es_gerencia())) with check ((select privado.es_gerencia()) and validado_por = (select auth.uid()));
create policy ger_del on cap_validaciones for delete to authenticated using ((select privado.es_gerencia()));

create policy solo_staff on cap_areas        as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on cap_items        as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on cap_reportes     as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on cap_respuestas   as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on cap_validaciones as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));

-- Resumen para Gerencia
create or replace view v_cap_resumen with (security_invoker = true) as
select r.id, r.fecha, r.turno, r.capitan_id, p.nombre as capitan, r.estado, r.firmado_en, r.inventario, r.equipo, r.condiciones,
       count(x.*) filter (where x.valor = 'si') as si,
       count(x.*) filter (where x.valor = 'no') as no,
       count(x.*) filter (where x.valor = 'na') as na,
       count(x.*) as respondidas,
       round(100.0 * count(x.*) filter (where x.valor = 'si' or (x.valor = 'na' and coalesce(trim(x.nota),'') <> '')) / nullif(count(x.*),0)) as cumplimiento_pct,
       v.validado_en, v.validado_por
from cap_reportes r
join perfiles p on p.id = r.capitan_id
left join cap_respuestas x on x.reporte_id = r.id
left join cap_validaciones v on v.reporte_id = r.id
group by r.id, p.nombre, v.validado_en, v.validado_por;

-- Contenido: funciones del Capitán de equipos (Santa María Golf & Country Club)
insert into cap_areas (codigo, nombre, nota, orden) values
 ('A','Inicio de turno y condiciones de la cancha','A las 5:30 a. m. el Capitán confirma con los superintendentes las condiciones del campo.',1),
 ('B','Supervisión del equipo',null,2),
 ('C','Tee sheet y cobros',null,3),
 ('D','Reglamento y salida al campo',null,4),
 ('E','Inventario de insumos',null,5),
 ('F','Atención al miembro',null,6),
 ('G','Área de trabajo y cierre',null,7);

insert into cap_items (id, area, texto, orden) values
 ('A1','A','Presentarse con el uniforme y los estándares de colaborador de Santa María',1),
 ('A2','A','Comunicarse con los superintendentes al inicio del turno (5:30 a. m.)',2),
 ('A3','A','Confirmar la velocidad de los greens',3),
 ('A4','A','Confirmar las posiciones de bandera',4),
 ('A5','A','Confirmar obras o accidentes en la cancha',5),
 ('A6','A','Confirmar la regla de carritos del día',6),
 ('A7','A','Confirmar la hora de apertura del campo',7),
 ('A8','A','Informar las condiciones de la cancha al equipo y al pro-shop',8),
 ('B1','B','Verificar la asistencia y asignar los puestos del equipo',1),
 ('B2','B','Starter (S) cumple sus funciones diarias',2),
 ('B3','B','Driving Range (R) cumple sus funciones diarias',3),
 ('B4','B','Carritos (L) cumple sus funciones diarias',4),
 ('B5','B','Frente (F) cumple sus funciones diarias',5),
 ('B6','B','Divots (D) cumple sus funciones diarias',6),
 ('B7','B','Comodín (C) cumple sus funciones diarias',7),
 ('B8','B','Repasar con el equipo las preferencias de los miembros',8),
 ('B9','B','Coordinar los 30 minutos de almuerzo de cada colaborador',9),
 ('C1','C','Mantener actualizado el tee sheet',1),
 ('C2','C','Informar al pro-shop para cargar lo correspondiente a la cuenta de cada miembro',2),
 ('C3','C','Verificar que cada jugador pagó su green fee',3),
 ('C4','C','Permitir salidas sin pago solo cuando lo autoriza el reglamento',4),
 ('D1','D','Velar por el cumplimiento del reglamento de uso de la cancha',1),
 ('D2','D','Verificar el código de vestimenta antes de la salida',2),
 ('D3','D','Tener disponibles tarjetas de score, lápices, agua y lo establecido para la salida',3),
 ('E1','E','Revisar el inventario de tarjetas de score',1),
 ('E2','E','Revisar el inventario de tees',2),
 ('E3','E','Revisar el inventario de lápices',3),
 ('E4','E','Revisar el inventario de toallas',4),
 ('E5','E','Revisar el inventario de bolas de práctica',5),
 ('E6','E','Revisar el inventario de agua',6),
 ('E7','E','Avisar a tiempo cuando un insumo está bajo para el pedido al proveedor',7),
 ('F1','F','Limpiar los sets de palos de cada jugador al terminar su ronda',1),
 ('F2','F','Mantener comunicación con el valet parking de la casa club',2),
 ('F3','F','Preguntar a los miembros si necesitan su carro o estarán en el hoyo 19',3),
 ('G1','G','Mantener el área de trabajo limpia y presentable',1),
 ('G2','G','Informar novedades al Gerente de Operaciones',2),
 ('G3','G','Dejar anotados los pendientes para el siguiente turno',3);
