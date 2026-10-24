-- ============ Módulo Starter: checklist diario y cruces por el hoyo 9 ============
create or replace function privado.es_starter() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select activo and rol::text in ('starter','capitan','gerente_operaciones','gerente_golf','admin') from perfiles where id = auth.uid()), false)
$$;
revoke execute on function privado.es_starter() from public, anon;
grant execute on function privado.es_starter() to authenticated;

create table st_areas (codigo char(1) primary key, nombre text not null, nota text, orden smallint not null);
create table st_items (
  id text primary key, area char(1) not null references st_areas(codigo), texto text not null,
  orden smallint not null, activo boolean not null default true,
  solo_fin_semana boolean not null default false);         -- solo aplica sábados y domingos
create index on st_items (area);

create table st_reportes (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null default (now() at time zone 'America/Panama')::date,
  turno          turno_tipo not null,
  starter_id     uuid not null references perfiles(id),
  tee            smallint not null default 1 check (tee in (1, 10)),
  capitan_id     uuid references perfiles(id),              -- Capitán de turno que valida
  observaciones  text,
  pendientes     text,
  estado         estado_reporte not null default 'borrador',
  firmado_en     timestamptz,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  unique (fecha, turno, starter_id));
create index on st_reportes (fecha desc);
create index on st_reportes (starter_id, fecha desc);
create index on st_reportes (capitan_id);
create trigger trg_st_reporte_tocar before update on st_reportes for each row execute function tocar_actualizado();

create table st_respuestas (
  reporte_id uuid not null references st_reportes(id) on delete cascade,
  item_id text not null references st_items(id),
  valor respuesta_valor not null, nota text, respondido_en timestamptz not null default now(),
  primary key (reporte_id, item_id));
create index on st_respuestas (item_id);

create table st_validaciones (
  reporte_id uuid primary key references st_reportes(id) on delete cascade,
  validado_por uuid not null references perfiles(id),
  validado_en timestamptz not null default now(),
  observaciones text);
create index on st_validaciones (validado_por);

-- Firma: reglas del turno en el servidor
create or replace function public.firmar_reporte_starter(p_reporte uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r st_reportes; finde boolean; faltan int; na_sin_j int;
begin
  select * into r from st_reportes where id = p_reporte for update;
  if r.id is null or r.starter_id <> auth.uid() then raise exception 'Reporte no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El reporte ya está firmado'; end if;
  if r.capitan_id is null then raise exception 'Indique el Capitán de turno'; end if;
  finde := extract(isodow from r.fecha) in (6, 7);
  select count(*) into faltan from st_items i where i.activo and (finde or not i.solo_fin_semana)
    and not exists (select 1 from st_respuestas x where x.reporte_id = p_reporte and x.item_id = i.id);
  if faltan > 0 then raise exception 'Faltan % actividades por responder', faltan; end if;
  select count(*) into na_sin_j from st_respuestas where reporte_id = p_reporte and valor = 'na' and coalesce(trim(nota),'') = '';
  if na_sin_j > 0 then raise exception 'Justifique % respuestas N/A', na_sin_j; end if;
  update st_reportes set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $$;
revoke execute on function public.firmar_reporte_starter(uuid) from public, anon;
grant execute on function public.firmar_reporte_starter(uuid) to authenticated;

-- Permisos
alter table st_areas enable row level security;
alter table st_items enable row level security;
alter table st_reportes enable row level security;
alter table st_respuestas enable row level security;
alter table st_validaciones enable row level security;

create policy leer on st_areas        for select to authenticated using ((select privado.es_starter()));
create policy leer on st_items        for select to authenticated using ((select privado.es_starter()));
create policy leer on st_reportes     for select to authenticated using ((select privado.es_starter()));
create policy leer on st_respuestas   for select to authenticated using ((select privado.es_starter()));
create policy leer on st_validaciones for select to authenticated using ((select privado.es_starter()));

create policy ger_ins on st_areas for insert to authenticated with check ((select privado.es_gerencia()));
create policy ger_upd on st_areas for update to authenticated using ((select privado.es_gerencia())) with check ((select privado.es_gerencia()));
create policy ger_ins on st_items for insert to authenticated with check ((select privado.es_gerencia()));
create policy ger_upd on st_items for update to authenticated using ((select privado.es_gerencia())) with check ((select privado.es_gerencia()));

create policy crear  on st_reportes for insert to authenticated
  with check (starter_id = (select auth.uid()) and estado = 'borrador' and (select privado.es_starter()));
create policy editar on st_reportes for update to authenticated
  using (starter_id = (select auth.uid()) and estado = 'borrador')
  with check (starter_id = (select auth.uid()) and estado = 'borrador');

create policy ins on st_respuestas for insert to authenticated
  with check (exists (select 1 from st_reportes r where r.id = reporte_id and r.starter_id = (select auth.uid()) and r.estado = 'borrador'));
create policy upd on st_respuestas for update to authenticated
  using (exists (select 1 from st_reportes r where r.id = reporte_id and r.starter_id = (select auth.uid()) and r.estado = 'borrador'))
  with check (exists (select 1 from st_reportes r where r.id = reporte_id and r.starter_id = (select auth.uid()) and r.estado = 'borrador'));

-- Valida el Capitán (o Gerencia), solo turnos firmados
create policy cap_ins on st_validaciones for insert to authenticated
  with check ((select privado.es_capitania()) and validado_por = (select auth.uid())
              and exists (select 1 from st_reportes r where r.id = reporte_id and r.estado = 'firmado'));
create policy cap_upd on st_validaciones for update to authenticated
  using ((select privado.es_capitania())) with check ((select privado.es_capitania()) and validado_por = (select auth.uid()));
create policy cap_del on st_validaciones for delete to authenticated using ((select privado.es_capitania()));

create policy solo_staff on st_areas        as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on st_items        as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on st_reportes     as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on st_respuestas   as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on st_validaciones as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));

create or replace view v_st_resumen with (security_invoker = true) as
select r.id, r.fecha, r.turno, r.tee, r.starter_id, p.nombre as starter, r.capitan_id, r.estado, r.firmado_en, r.pendientes,
       count(x.*) filter (where x.valor = 'si') as si,
       count(x.*) filter (where x.valor = 'no') as no,
       count(x.*) filter (where x.valor = 'na') as na,
       count(x.*) as respondidas,
       round(100.0 * count(x.*) filter (where x.valor = 'si' or (x.valor = 'na' and coalesce(trim(x.nota),'') <> '')) / nullif(count(x.*),0)) as cumplimiento_pct,
       v.validado_en, v.validado_por
from st_reportes r
join perfiles p on p.id = r.starter_id
left join st_respuestas x on x.reporte_id = r.id
left join st_validaciones v on v.reporte_id = r.id
group by r.id, p.nombre, v.validado_en, v.validado_por;

alter publication supabase_realtime add table st_reportes, st_validaciones;

-- Salidas: el Starter marca la salida y el cruce por el hoyo 9
alter table public.tee_salidas add column cruce_real timestamptz;
alter table public.tee_salidas add column cruce_por uuid references public.perfiles(id);
create policy tee_editar_starter on public.tee_salidas for update to authenticated
  using ((select privado.es_starter())) with check ((select privado.es_starter()));

-- Contenido: Checklist diario del Starter (Santa María Golf Club)
insert into st_areas (codigo, nombre, nota, orden) values
 ('A','Presentación y preparación del puesto',null,1),
 ('B','Información y condiciones del campo','Antes de las primeras salidas, confirme con el Capitán las condiciones oficiales del día.',2),
 ('C','Recepción y servicio al golfista',null,3),
 ('D','Control de salidas y flujo del campo','Registre en la pestaña Salidas la hora real de cada salida y el cruce por el hoyo 9.',4),
 ('E','Supervisión de reglamentos y seguridad',null,5),
 ('F','Continuidad operativa y comunicación',null,6),
 ('G','Cierre y responsabilidades adicionales',null,7);

insert into st_items (id, area, texto, orden, solo_fin_semana) values
 ('A1','A','Presentación personal, uniforme e identificación conforme a los estándares del club',1,false),
 ('A2','A','Puntualidad y cumplimiento del horario asignado',2,false),
 ('A3','A','Área de salida (tee 1 o tee 10) limpia, ordenada y lista para recibir jugadores',3,false),
 ('A4','A','Disponibilidad de tarjetas de score, lápices, agua y demás materiales establecidos',4,false),
 ('A5','A','Recepción del listado actualizado de tee times y comunicación inicial con el Capitán',5,false),
 ('B1','B','Confirmar con el Capitán las condiciones y restricciones vigentes del campo',1,false),
 ('B2','B','Conocer hoyos bajo Cart Path Only, regla de 90° y áreas en reparación',2,false),
 ('B3','B','Disponer de información actualizada sobre posiciones de bandera y velocidad de greens',3,false),
 ('B4','B','Conocer trabajos de mantenimiento, cierres parciales y situaciones especiales',4,false),
 ('B5','B','Comunicar claramente a los jugadores las reglas y condiciones del día',5,false),
 ('C1','C','Recibir cordialmente a los jugadores y confirmar su tee time',1,false),
 ('C2','C','Verificar que los jugadores estén registrados y cuenten con green fee pagado o autorización válida',2,false),
 ('C3','C','Supervisar el cumplimiento del código de vestimenta',3,false),
 ('C4','C','Ofrecer orientación sobre el recorrido, reglas y servicios disponibles',4,false),
 ('C5','C','Despedir cordialmente a los jugadores que finalizan su ronda, cuando corresponda a su puesto',5,false),
 ('D1','D','Respetar los horarios de salida y el orden de las reservas',1,false),
 ('D2','D','Coordinar con el Marshal antes de autorizar ajustes que afecten el flujo del campo',2,false),
 ('D3','D','Evitar salidas anticipadas o adicionales que puedan provocar congestión',3,false),
 ('D4','D','Registrar los horarios reales de salida de las partidas',4,false),
 ('D5','D','Controlar los tiempos de cruce por el hoyo 9 y comunicar demoras',5,false),
 ('D6','D','Mantener comunicación constante con el Marshal sobre ritmo de juego y tráfico del campo',6,false),
 ('E1','E','Velar por el cumplimiento de las normas de uso del campo',1,false),
 ('E2','E','Informar restricciones de circulación de carritos y condiciones especiales',2,false),
 ('E3','E','Reportar comportamientos que comprometan la seguridad o el ritmo de juego',3,false),
 ('E4','E','Escalar oportunamente incidentes, incumplimientos o reclamos al Capitán',4,false),
 ('E5','E','Solicitar aprobación del Gerente de Operaciones cuando corresponda una decisión extraordinaria',5,false),
 ('F1','F','Mantener el puesto de salida atendido durante toda la jornada asignada',1,false),
 ('F2','F','Coordinar con el Capitán cualquier relevo antes de ausentarse',2,false),
 ('F3','F','Informar al Capitán sobre cambios, retrasos, cancelaciones y ausencias de jugadores',3,false),
 ('F4','F','Mantener comunicación efectiva con Pro Shop, Marshal y demás personal involucrado',4,false),
 ('F5','F','Dejar registro de novedades e incidencias relevantes para el siguiente turno',5,false),
 ('G1','G','Confirmar que no queden salidas pendientes sin coordinación',1,false),
 ('G2','G','Entregar al Capitán el informe de salidas, cruces, demoras e incidentes',2,false),
 ('G3','G','Dejar el área de trabajo limpia, organizada y abastecida',3,false),
 ('G4','G','Realizar el traspaso de información al siguiente turno cuando corresponda',4,false),
 ('G5','G','Cumplir las funciones de Marshal de 3:00 p. m. a 7:00 p. m. (sábados y domingos), según la programación operativa',5,true);
