create type rol_usuario      as enum ('marshal','gerente_operaciones','gerente_golf','admin');
create type turno_tipo       as enum ('apertura','cierre');
create type estado_reporte   as enum ('borrador','firmado');
create type respuesta_valor  as enum ('si','no','na');
create type prioridad_inc    as enum ('critica','alta','ordinaria');
create type categoria_inc    as enum ('ritmo_juego','campo_carritos','agronomia_riego','seguridad','instalaciones','atencion_miembros');
create type etapa_ritmo      as enum ('deteccion','comunicacion','seguimiento','escalamiento');
create type ubicacion_tipo   as enum ('hoyo','instalaciones','general');
create type estado_inc       as enum ('abierta','cerrada');
create type notificado_a     as enum ('gerente_operaciones','gerente_golf','starter','mantenimiento','ninguno');

create table perfiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nombre      text not null,
  rol         rol_usuario not null default 'marshal',
  activo      boolean not null default true,
  creado_en   timestamptz not null default now()
);

create or replace function crear_perfil_nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)));
  return new;
end $$;
create trigger trg_nuevo_usuario after insert on auth.users
  for each row execute function crear_perfil_nuevo_usuario();

create or replace function mi_rol() returns rol_usuario
language sql stable security definer set search_path = public as $$
  select rol from perfiles where id = auth.uid() and activo
$$;
create or replace function es_gerencia() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(mi_rol() in ('gerente_operaciones','gerente_golf','admin'), false)
$$;

create table areas_checklist (
  codigo  char(1) primary key,
  nombre  text not null,
  nota    text,
  orden   smallint not null
);
create table items_checklist (
  id      text primary key,
  area    char(1) not null references areas_checklist(codigo),
  texto   text not null,
  orden   smallint not null,
  activo  boolean not null default true
);

create table reportes_turno (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null default (now() at time zone 'America/Panama')::date,
  turno          turno_tipo not null,
  marshal_id     uuid not null references perfiles(id),
  hoyos          smallint[] not null default '{}'
                 check (hoyos <@ array[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]::smallint[]),
  vehiculo       text,
  radio          text,
  observaciones  text,
  pendientes     text,
  estado         estado_reporte not null default 'borrador',
  firmado_en     timestamptz,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  unique (fecha, turno, marshal_id)
);

create table respuestas_checklist (
  reporte_id     uuid not null references reportes_turno(id) on delete cascade,
  item_id        text not null references items_checklist(id),
  valor          respuesta_valor not null,
  nota           text,
  respondido_en  timestamptz not null default now(),
  primary key (reporte_id, item_id)
);

create table validaciones (
  reporte_id     uuid primary key references reportes_turno(id) on delete cascade,
  validado_por   uuid not null references perfiles(id),
  validado_en    timestamptz not null default now(),
  observaciones  text
);

create table incidencias (
  id            uuid primary key default gen_random_uuid(),
  reporte_id    uuid references reportes_turno(id) on delete set null,
  fecha         date not null default (now() at time zone 'America/Panama')::date,
  turno         turno_tipo,
  creado_en     timestamptz not null default now(),
  ubicacion     ubicacion_tipo not null default 'hoyo',
  hoyo          smallint check (hoyo between 1 and 18),
  categoria     categoria_inc not null,
  etapa         etapa_ritmo,
  prioridad     prioridad_inc not null default 'ordinaria',
  descripcion   text not null,
  accion        text,
  notificado    notificado_a not null default 'ninguno',
  estado        estado_inc not null default 'abierta',
  cerrado_en    timestamptz,
  cerrado_por   uuid references perfiles(id),
  autor_id      uuid not null references perfiles(id) default auth.uid(),
  check ((ubicacion = 'hoyo') = (hoyo is not null)),
  check (etapa is null or categoria = 'ritmo_juego'),
  check ((estado = 'cerrada') = (cerrado_en is not null))
);

create table incidencia_fotos (
  id             uuid primary key default gen_random_uuid(),
  incidencia_id  uuid not null references incidencias(id) on delete cascade,
  storage_path   text not null,
  subido_por     uuid not null references perfiles(id) default auth.uid(),
  subido_en      timestamptz not null default now()
);

create index on reportes_turno (fecha desc, turno);
create index on reportes_turno (marshal_id, fecha desc);
create index on incidencias (estado, prioridad);
create index on incidencias (fecha desc);
create index on incidencias (reporte_id);

create or replace function tocar_actualizado() returns trigger language plpgsql as $$
begin new.actualizado_en := now(); return new; end $$;
create trigger trg_reporte_tocar before update on reportes_turno
  for each row execute function tocar_actualizado();

create or replace function firmar_reporte(p_reporte uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r reportes_turno; faltan int; na_sin_j int;
begin
  select * into r from reportes_turno where id = p_reporte for update;
  if r.id is null or r.marshal_id <> auth.uid() then raise exception 'Reporte no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El reporte ya está firmado'; end if;
  if cardinality(r.hoyos) = 0 then raise exception 'Marque los hoyos asignados'; end if;
  if coalesce(trim(r.vehiculo),'') = '' or coalesce(trim(r.radio),'') = '' then
    raise exception 'Anote vehículo y radio'; end if;
  select count(*) into faltan from items_checklist i
   where i.activo and not exists (select 1 from respuestas_checklist x where x.reporte_id = p_reporte and x.item_id = i.id);
  if faltan > 0 then raise exception 'Faltan % actividades por responder', faltan; end if;
  select count(*) into na_sin_j from respuestas_checklist
   where reporte_id = p_reporte and valor = 'na' and coalesce(trim(nota),'') = '';
  if na_sin_j > 0 then raise exception 'Justifique % respuestas N/A', na_sin_j; end if;
  update reportes_turno set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $$;

alter table perfiles             enable row level security;
alter table areas_checklist      enable row level security;
alter table items_checklist      enable row level security;
alter table reportes_turno       enable row level security;
alter table respuestas_checklist enable row level security;
alter table validaciones         enable row level security;
alter table incidencias          enable row level security;
alter table incidencia_fotos     enable row level security;

create policy perfiles_leer   on perfiles for select to authenticated using (true);
create policy perfiles_gestion on perfiles for update to authenticated using (es_gerencia()) with check (es_gerencia());

create policy areas_leer  on areas_checklist for select to authenticated using (true);
create policy areas_admin on areas_checklist for all    to authenticated using (es_gerencia()) with check (es_gerencia());
create policy items_leer  on items_checklist for select to authenticated using (true);
create policy items_admin on items_checklist for all    to authenticated using (es_gerencia()) with check (es_gerencia());

create policy rep_leer     on reportes_turno for select to authenticated using (true);
create policy rep_crear    on reportes_turno for insert to authenticated with check (marshal_id = auth.uid() and estado = 'borrador');
create policy rep_editar   on reportes_turno for update to authenticated
  using (marshal_id = auth.uid() and estado = 'borrador')
  with check (marshal_id = auth.uid() and estado = 'borrador');

create policy resp_leer on respuestas_checklist for select to authenticated using (true);
create policy resp_escribir on respuestas_checklist for all to authenticated
  using (exists (select 1 from reportes_turno r where r.id = reporte_id and r.marshal_id = auth.uid() and r.estado = 'borrador'))
  with check (exists (select 1 from reportes_turno r where r.id = reporte_id and r.marshal_id = auth.uid() and r.estado = 'borrador'));

create policy val_leer on validaciones for select to authenticated using (true);
create policy val_gerencia on validaciones for all to authenticated
  using (es_gerencia())
  with check (es_gerencia() and validado_por = auth.uid()
              and exists (select 1 from reportes_turno r where r.id = reporte_id and r.estado = 'firmado'));

create policy inc_leer   on incidencias for select to authenticated using (true);
create policy inc_crear  on incidencias for insert to authenticated with check (autor_id = auth.uid());
create policy inc_editar on incidencias for update to authenticated
  using (autor_id = auth.uid() or es_gerencia()) with check (autor_id = auth.uid() or es_gerencia());

create policy fotos_leer  on incidencia_fotos for select to authenticated using (true);
create policy fotos_crear on incidencia_fotos for insert to authenticated with check (subido_por = auth.uid());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('incidencias','incidencias', false, 10485760, array['image/jpeg','image/png','image/webp','image/heic']);

create policy fotos_bucket_leer on storage.objects for select to authenticated
  using (bucket_id = 'incidencias');
create policy fotos_bucket_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'incidencias' and owner = auth.uid());

create or replace view v_reportes_resumen with (security_invoker = true) as
select r.id, r.fecha, r.turno, r.marshal_id, p.nombre as marshal, r.estado, r.firmado_en,
       cardinality(r.hoyos) as hoyos_cubiertos,
       count(x.*) filter (where x.valor = 'si') as si,
       count(x.*) filter (where x.valor = 'no') as no,
       count(x.*) filter (where x.valor = 'na') as na,
       count(x.*) as respondidas,
       round(100.0 * count(x.*) filter (where x.valor = 'si' or (x.valor = 'na' and coalesce(trim(x.nota),'') <> ''))
             / nullif(count(x.*),0)) as cumplimiento_pct,
       v.validado_en, v.validado_por
from reportes_turno r
join perfiles p on p.id = r.marshal_id
left join respuestas_checklist x on x.reporte_id = r.id
left join validaciones v on v.reporte_id = r.id
group by r.id, p.nombre, v.validado_en, v.validado_por;

create or replace view v_cobertura_diaria with (security_invoker = true) as
select fecha, count(distinct h) as hoyos_cubiertos, round(100.0 * count(distinct h) / 18) as cobertura_pct
from reportes_turno, unnest(hoyos) as h
where estado = 'firmado'
group by fecha;

insert into areas_checklist (codigo, nombre, nota, orden) values
 ('A','Inspección inicial del campo',null,1),
 ('B','Supervisión del ritmo de juego',null,2),
 ('C','Protección y conservación del campo','Prioridad en Santa María: bordes y entradas de los fairways, donde la humedad acumulada se daña con el tránsito de carritos.',3),
 ('D','Seguridad y prevención de riesgos',null,4),
 ('E','Atención a miembros e invitados',null,5),
 ('F','Inspección de instalaciones',null,6),
 ('G','Cierre y entrega de turno',null,7);

insert into items_checklist (id, area, texto, orden) values
 ('A1','A','Recibir instrucciones del Gerente de Operaciones',1),
 ('A2','A','Verificar uniforme, radio y vehículo asignado',2),
 ('A3','A','Confirmar las restricciones vigentes del campo',3),
 ('A4','A','Inspeccionar los hoyos o sectores asignados',4),
 ('A5','A','Revisar tees, fairways, roughs, greens y bunkers',5),
 ('A6','A','Detectar zonas húmedas, encharcamientos o problemas de drenaje',6),
 ('A7','A','Verificar caminos, puentes y accesos',7),
 ('A8','A','Inspeccionar señalización, estacas de límites y áreas en reparación',8),
 ('A9','A','Identificar daños, objetos peligrosos y condiciones inseguras',9),
 ('A10','A','Reportar las anomalías detectadas',10),
 ('B1','B','Monitorear la posición de los grupos',1),
 ('B2','B','Comparar el avance con el grupo precedente',2),
 ('B3','B','Verificar el cumplimiento del tiempo objetivo del club',3),
 ('B4','B','Detectar retrasos y congestiones',4),
 ('B5','B','Acercarse a los jugadores con cortesía y profesionalismo',5),
 ('B6','B','Recomendar acciones para recuperar la posición',6),
 ('B7','B','Dar seguimiento a los grupos advertidos',7),
 ('B8','B','Coordinar el tránsito de jugadores entre los hoyos 9 y 10',8),
 ('B9','B','Comunicar retrasos persistentes al Gerente de Operaciones y al Starter',9),
 ('B10','B','Registrar hora, hoyo, situación y resultado de cada intervención',10),
 ('C1','C','Cumplimiento de Cart Path Only',1),
 ('C2','C','Cumplimiento de la regla de 90° cuando esté autorizada',2),
 ('C3','C','Protección de los bordes húmedos de los fairways',3),
 ('C4','C','Restricción de carritos en zonas de greens y tees',4),
 ('C5','C','Protección de áreas en reparación',5),
 ('C6','C','Reparación de piques de bola',6),
 ('C7','C','Reposición de divots',7),
 ('C8','C','Uso correcto de arena reparadora',8),
 ('C9','C','Rastrillado de bunkers',9),
 ('C10','C','Identificación de daños en el césped',10),
 ('C11','C','Reporte de fugas, aspersores defectuosos y problemas de riego',11),
 ('D1','D','Vigilar condiciones meteorológicas',1),
 ('D2','D','Reportar señales de tormenta eléctrica al Gerente y luego a los jugadores',2),
 ('D3','D','Ejecutar los protocolos autorizados de suspensión y evacuación',3),
 ('D4','D','Identificar peatones o personas ajenas al juego',4),
 ('D5','D','Prevenir accidentes relacionados con golpes de golf',5),
 ('D6','D','Supervisar la conducción responsable de carritos',6),
 ('D7','D','Identificar comportamientos peligrosos',7),
 ('D8','D','Reportar accidentes y emergencias',8),
 ('D9','D','Comunicar la ubicación exacta de cualquier incidente',9),
 ('D10','D','Evitar confrontaciones y solicitar apoyo cuando sea necesario',10),
 ('E1','E','Saludar cordialmente a miembros e invitados',1),
 ('E2','E','Mantener una actitud respetuosa y profesional',2),
 ('E3','E','Brindar orientación sobre el recorrido',3),
 ('E4','E','Explicar las restricciones del campo',4),
 ('E5','E','Atender solicitudes de asistencia',5),
 ('E6','E','Escuchar y documentar quejas',6),
 ('E7','E','Canalizar solicitudes a las áreas responsables',7),
 ('E8','E','Evitar prometer excepciones no autorizadas',8),
 ('E9','E','Promover una experiencia de juego agradable',9),
 ('F1','F','Estado de los caminos de carritos',1),
 ('F2','F','Condiciones de puentes y barandas',2),
 ('F3','F','Limpieza y funcionamiento de baños',3),
 ('F4','F','Disponibilidad y estado de estaciones de hidratación',4),
 ('F5','F','Condiciones de señalización',5),
 ('F6','F','Presencia de basura u objetos fuera de lugar',6),
 ('F7','F','Estado de los accesorios del campo',7),
 ('F8','F','Vehículos averiados o abandonados',8),
 ('F9','F','Situaciones que requieran intervención de Mantenimiento',9),
 ('G1','G','Verificar la ubicación de los grupos pendientes',1),
 ('G2','G','Confirmar las incidencias registradas',2),
 ('G3','G','Identificar asuntos pendientes de solución',3),
 ('G4','G','Comunicar restricciones vigentes',4),
 ('G5','G','Informar novedades al siguiente turno',5),
 ('G6','G','Entregar radio, llaves y vehículo',6),
 ('G7','G','Registrar observaciones del turno',7);

alter publication supabase_realtime add table incidencias;
