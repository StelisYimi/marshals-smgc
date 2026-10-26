-- ============ Checklist de puestos: Frente, Carritos y Driving Range ============
-- Cada colaborador llena en su teléfono el checklist de la posición que tiene asignada (según el horario).
-- Tareas comunes obligatorias para todos + tareas de la posición + tareas periódicas del día de la semana.
-- El colaborador firma; el Capitán en turno (o Gerencia) valida. Los daños a carritos se reportan por escrito.

-- Colaborador del horario vinculado a la cuenta que llama
create or replace function privado.mi_personal() returns uuid
language sql stable security definer set search_path = public as $$
  select id from hor_personal where perfil_id = auth.uid() and activo limit 1
$$;
revoke execute on function privado.mi_personal() from public, anon;
grant execute on function privado.mi_personal() to authenticated;

create table public.op_areas (
  codigo   text primary key,
  posicion char(1) not null check (posicion in ('C','F','L','R')),   -- C = común a las tres posiciones
  nombre   text not null,
  nota     text,
  orden    smallint not null
);
create table public.op_items (
  id         text primary key,
  area       text not null references public.op_areas(codigo),
  texto      text not null,
  orden      smallint not null,
  activo     boolean not null default true,
  dia_semana smallint check (dia_semana between 1 and 7)            -- tarea periódica: 1 = lunes … 7 = domingo
);
create index on public.op_items (area);

create table public.op_reportes (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null default (now() at time zone 'America/Panama')::date,
  personal_id    uuid not null references public.hor_personal(id),
  posicion       char(1) not null check (posicion in ('F','L','R')),
  autor_id       uuid references public.perfiles(id) default auth.uid(),
  datos          jsonb not null default '{}',                         -- carritos listos / fuera de servicio, nivel de bolas
  observaciones  text,
  entrega        text,                                                -- pendientes que entrega al compañero o al Capitán
  estado         estado_reporte not null default 'borrador',
  firmado_en     timestamptz,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  unique (fecha, personal_id, posicion)
);
create index on public.op_reportes (fecha desc);
create trigger trg_op_reporte_tocar before update on public.op_reportes for each row execute function public.tocar_actualizado();

create table public.op_respuestas (
  reporte_id    uuid not null references public.op_reportes(id) on delete cascade,
  item_id       text not null references public.op_items(id),
  valor         respuesta_valor not null,
  nota          text,
  respondido_en timestamptz not null default now(),
  primary key (reporte_id, item_id)
);

create table public.op_validaciones (
  reporte_id    uuid primary key references public.op_reportes(id) on delete cascade,
  validado_por  uuid not null references public.perfiles(id),
  validado_en   timestamptz not null default now(),
  observaciones text
);

create table public.op_danos (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null default (now() at time zone 'America/Panama')::date,
  creado_en      timestamptz not null default now(),
  carrito        text not null,
  descripcion    text not null,
  fuera_servicio boolean not null default true,
  reportado_por  uuid not null references public.perfiles(id) default auth.uid(),
  personal_id    uuid references public.hor_personal(id),
  estado         text not null default 'abierto' check (estado in ('abierto','cerrado')),
  accion         text,
  cerrado_por    uuid references public.perfiles(id),
  cerrado_en     timestamptz
);
create index on public.op_danos (estado, creado_en desc);

-- Firma: reglas del checklist en el servidor
create or replace function public.firmar_reporte_op(p_reporte uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r op_reportes; dia smallint; faltan int; sin_j int;
begin
  select * into r from op_reportes where id = p_reporte for update;
  if r.id is null or not (r.personal_id = privado.mi_personal() or privado.es_capitania()) then raise exception 'Checklist no encontrado'; end if;
  if r.estado = 'firmado' then raise exception 'El checklist ya está firmado'; end if;
  dia := extract(isodow from r.fecha);
  select count(*) into faltan from op_items i join op_areas a on a.codigo = i.area
    where i.activo and a.posicion in ('C', r.posicion) and (i.dia_semana is null or i.dia_semana = dia)
      and not exists (select 1 from op_respuestas x where x.reporte_id = p_reporte and x.item_id = i.id);
  if faltan > 0 then raise exception 'Faltan % actividades por responder', faltan; end if;
  select count(*) into sin_j from op_respuestas where reporte_id = p_reporte and valor in ('no','na') and coalesce(btrim(nota),'') = '';
  if sin_j > 0 then raise exception 'Justifique % actividades marcadas No o N/A', sin_j; end if;
  if r.posicion = 'L' and (r.datos->>'carritos_listos') is null then raise exception 'Indique cuántos carritos quedaron listos'; end if;
  if r.posicion = 'R' and (r.datos->>'nivel_bolas') is null then raise exception 'Indique el nivel de bolas de práctica'; end if;
  update op_reportes set estado = 'firmado', firmado_en = now() where id = p_reporte;
end $$;
revoke execute on function public.firmar_reporte_op(uuid) from public, anon;
grant execute on function public.firmar_reporte_op(uuid) to authenticated;

-- Permisos
alter table public.op_areas        enable row level security;
alter table public.op_items        enable row level security;
alter table public.op_reportes     enable row level security;
alter table public.op_respuestas   enable row level security;
alter table public.op_validaciones enable row level security;
alter table public.op_danos        enable row level security;

create policy leer on public.op_areas for select to authenticated using ((select privado.es_activo()));
create policy leer on public.op_items for select to authenticated using ((select privado.es_activo()));
create policy ger  on public.op_areas for all to authenticated using ((select privado.es_gerencia())) with check ((select privado.es_gerencia()));
create policy ger  on public.op_items for all to authenticated using ((select privado.es_gerencia())) with check ((select privado.es_gerencia()));

create policy capitania on public.op_reportes for all to authenticated using ((select privado.es_capitania())) with check ((select privado.es_capitania()));
create policy propio_leer on public.op_reportes for select to authenticated using (personal_id = (select privado.mi_personal()));
create policy propio_crear on public.op_reportes for insert to authenticated
  with check (personal_id = (select privado.mi_personal()) and estado = 'borrador' and fecha = (now() at time zone 'America/Panama')::date);
create policy propio_editar on public.op_reportes for update to authenticated
  using (personal_id = (select privado.mi_personal()) and estado = 'borrador')
  with check (personal_id = (select privado.mi_personal()) and estado = 'borrador');

create policy capitania on public.op_respuestas for all to authenticated using ((select privado.es_capitania())) with check ((select privado.es_capitania()));
create policy propio_leer on public.op_respuestas for select to authenticated
  using (exists (select 1 from op_reportes r where r.id = reporte_id and r.personal_id = (select privado.mi_personal())));
create policy propio_escribir on public.op_respuestas for insert to authenticated
  with check (exists (select 1 from op_reportes r where r.id = reporte_id and r.personal_id = (select privado.mi_personal()) and r.estado = 'borrador'));
create policy propio_editar on public.op_respuestas for update to authenticated
  using (exists (select 1 from op_reportes r where r.id = reporte_id and r.personal_id = (select privado.mi_personal()) and r.estado = 'borrador'))
  with check (exists (select 1 from op_reportes r where r.id = reporte_id and r.personal_id = (select privado.mi_personal()) and r.estado = 'borrador'));

create policy leer on public.op_validaciones for select to authenticated
  using ((select privado.es_capitania()) or exists (select 1 from op_reportes r where r.id = reporte_id and r.personal_id = (select privado.mi_personal())));
create policy cap_ins on public.op_validaciones for insert to authenticated
  with check ((select privado.es_capitania()) and validado_por = (select auth.uid())
              and exists (select 1 from op_reportes r where r.id = reporte_id and r.estado = 'firmado'));
create policy cap_upd on public.op_validaciones for update to authenticated
  using ((select privado.es_capitania())) with check ((select privado.es_capitania()) and validado_por = (select auth.uid()));
create policy cap_del on public.op_validaciones for delete to authenticated using ((select privado.es_capitania()));

create policy capitania on public.op_danos for all to authenticated using ((select privado.es_capitania())) with check ((select privado.es_capitania()));
create policy propio_leer on public.op_danos for select to authenticated using (reportado_por = (select auth.uid()));
create policy reportar on public.op_danos for insert to authenticated
  with check ((select privado.es_activo()) and reportado_por = (select auth.uid()) and estado = 'abierto');

alter publication supabase_realtime add table public.op_reportes;
alter publication supabase_realtime add table public.op_danos;

-- Contenido inicial (borrador para revisión de Gerencia; se edita en la app: Capitanes → Puestos → Editar tareas)
insert into public.op_areas (codigo, posicion, nombre, nota, orden) values
 ('C', 'C', 'Comunes · Presentación, servicio y seguridad', 'Obligatorias para todos, en cualquier posición.', 1),
 ('F', 'F', 'Frente · Recepción y bolsas', null, 2),
 ('L', 'L', 'Carritos · Preparación, limpieza y control', 'Meta: 20 carritos preparados durante las horas de servicio.', 3),
 ('R', 'R', 'Driving Range · Preparación, bolas y seguridad', null, 4);

insert into public.op_items (id, area, texto, orden, dia_semana) values
 ('C01','C','Me presenté a tiempo, con uniforme completo y limpio, y buena presentación personal.',1,null),
 ('C02','C','Recibí del Capitán mi posición asignada y las novedades del día.',2,null),
 ('C03','C','Saludé a cada miembro, invitado y visitante con cortesía, calidez y una sonrisa.',3,null),
 ('C04','C','Mantuve mi área limpia y organizada durante todo el turno.',4,null),
 ('C05','C','Estuve atento al radio y respondí los llamados del Capitán.',5,null),
 ('C06','C','Reporté al Capitán en el momento cualquier incidente, desperfecto o necesidad.',6,null),
 ('C07','C','Cumplí las normas de seguridad: conducción de carritos, zonas de tiro y objetos peligrosos.',7,null),
 ('C08','C','Al cambiar de posición o terminar el turno, entregué ordenadamente los pendientes al compañero o al Capitán.',8,null),

 ('F01','F','Abrí y preparé la recepción: limpieza, mobiliario y rack de bolsas en orden.',1,null),
 ('F02','F','Revisé con el Starter o el Capitán las salidas del día para anticipar llegadas.',2,null),
 ('F03','F','Recibí a cada miembro al llegar, sin hacerlo esperar, y tomé su bolsa.',3,null),
 ('F04','F','Verifiqué el nombre de cada bolsa y la llevé al carrito o al rack correcto.',4,null),
 ('F05','F','Coordiné con Valet la llegada y salida de vehículos.',5,null),
 ('F06','F','Orienté a cada miembro hacia el Starter, el Range o el área que necesitaba.',6,null),
 ('F07','F','Al terminar cada ronda limpié palos y bolsa y retiré la basura del carrito.',7,null),
 ('F08','F','Entregué cada bolsa en el vehículo del miembro o la guardé en su casilla con registro en la app.',8,null),
 ('F09','F','Revisé que no quedaran objetos olvidados en los carritos y los entregué al Capitán.',9,null),
 ('F10','F','Apoyé al compañero del Range cuando el Frente estuvo tranquilo.',10,null),
 ('F11','F','Al cierre no quedó ninguna bolsa sin guardar o entregar; recepción limpia y equipos apagados.',11,null),
 ('F12','F','Limpieza profunda de la recepción, el rack de bolsas y el área de casillas.',12,4),

 ('L01','L','Revisé la carga de baterías o el combustible de cada carrito al iniciar.',1,null),
 ('L02','L','Mantuve 20 carritos preparados: limpios, cargados y equipados (arena, botella, toalla, tarjeta y lápiz).',2,null),
 ('L03','L','Lavé y sequé cada carrito al regresar: asientos, piso, volante, canasta y parabrisas.',3,null),
 ('L04','L','Retiré la basura y repuse los accesorios faltantes.',4,null),
 ('L05','L','Revisé llantas, frenos, luces, bocina y daños visibles.',5,null),
 ('L06','L','Reporté por escrito en la app cada daño, con el número del carrito, y avisé al Capitán.',6,null),
 ('L07','L','Retiré de servicio y marqué los carritos con desperfecto.',7,null),
 ('L08','L','Llevé el control de entrega y devolución de carritos.',8,null),
 ('L09','L','Mantuve ordenada la fila de carritos y el área de lavado.',9,null),
 ('L10','L','Al cierre conecté a carga todos los carritos; bodega limpia, ordenada y cerrada, con llaves controladas.',10,null),
 ('L11','L','Limpieza profunda de la bodega de carritos y del área de carga.',11,1),
 ('L12','L','Inventario de accesorios de carritos (arena, botellas, toallas, tarjetas y lápices).',12,5),

 ('R01','R','Abrí el Range: alfombras y tees alineados, señalización y banderas colocadas.',1,null),
 ('R02','R','Revisé el aceite de la máquina Range Ball y avisé a Roderick al momento si había falla.',2,null),
 ('R03','R','La máquina y las canastas tuvieron bolas limpias y suficientes durante la operación.',3,null),
 ('R04','R','Recogí las bolas del campo de práctica en los horarios definidos y las lavé.',4,null),
 ('R05','R','Durante la recolección nadie estuvo en la zona de tiro.',5,null),
 ('R06','R','Roté la zona de práctica en grama para proteger el césped y reparé divots.',6,null),
 ('R07','R','Mantuve limpias las estaciones y atendí a miembros e invitados.',7,null),
 ('R08','R','Al cierre recogí y lavé las bolas, dejé la máquina abastecida, guardé el equipo y cerré la bodega.',8,null),
 ('R09','R','Lavado profundo de bolas y limpieza de la máquina Range Ball.',9,2),
 ('R10','R','Inventario de bolas de práctica y canastas.',10,3);
