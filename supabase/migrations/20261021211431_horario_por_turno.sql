update public.hor_puestos set activo = false where codigo in ('capitan','starter','frente','carritos','range','divots','marshal','comodin','almuerzo');
alter table public.hor_personal add column if not exists grupo text not null default 'Operación de golf';
alter table public.hor_personal add column if not exists orden smallint not null default 0;
comment on table public.hor_bloques is 'Sin uso: reemplazada por hor_turnos.';

create table public.hor_turnos (
  id              uuid primary key default gen_random_uuid(),
  fecha           date not null,
  personal_id     uuid not null references public.hor_personal(id) on delete cascade,
  tipo            text not null default 'trabajo' check (tipo in ('trabajo','descanso','vacaciones','compensatorio')),
  inicio          time,
  fin             time,
  puesto          text references public.hor_puestos(codigo) on update cascade,
  almuerzo_inicio time,
  almuerzo_fin    time,
  nota            text,
  creado_por      uuid references public.perfiles(id) default auth.uid(),
  actualizado_en  timestamptz not null default now(),
  unique (fecha, personal_id),
  check ((tipo = 'trabajo') = (inicio is not null and fin is not null and puesto is not null)),
  check (fin is null or fin > inicio),
  check ((almuerzo_inicio is null) = (almuerzo_fin is null)),
  check (almuerzo_fin is null or almuerzo_fin > almuerzo_inicio)
);
create index on public.hor_turnos (fecha);
create trigger trg_hor_tocar before update on public.hor_turnos for each row execute function public.tocar_actualizado();
alter table public.hor_turnos enable row level security;
create policy leer   on public.hor_turnos for select to authenticated using (privado.es_activo());
create policy editar on public.hor_turnos for all to authenticated
  using (privado.es_gerencia() or (privado.es_capitania() and fecha = (now() at time zone 'America/Panama')::date))
  with check (privado.es_gerencia() or (privado.es_capitania() and fecha = (now() at time zone 'America/Panama')::date));
alter publication supabase_realtime add table public.hor_turnos;

create or replace function public.tablero_dia(p_token text, p_fecha date default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare f date := coalesce(p_fecha, (now() at time zone 'America/Panama')::date);
begin
  if not exists (select 1 from tablero_claves where token = p_token and activo) then
    raise exception 'Enlace del tablero no válido';
  end if;
  return json_build_object(
    'fecha', f,
    'ahora', to_char(now() at time zone 'America/Panama', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'puestos', (select coalesce(json_agg(json_build_object('codigo',codigo,'nombre',nombre,'color',color,'instrucciones',instrucciones) order by orden), '[]') from hor_puestos where activo),
    'turnos', (select coalesce(json_agg(json_build_object('persona',p.nombre,'grupo',p.grupo,'tipo',t.tipo,'puesto',t.puesto,
                 'inicio',to_char(t.inicio,'HH24:MI'),'fin',to_char(t.fin,'HH24:MI'),
                 'almuerzo_inicio',to_char(t.almuerzo_inicio,'HH24:MI'),'almuerzo_fin',to_char(t.almuerzo_fin,'HH24:MI'),'nota',t.nota)
                 order by t.inicio nulls last, p.orden, p.nombre), '[]')
               from hor_turnos t join hor_personal p on p.id = t.personal_id where t.fecha = f and p.activo)
  );
end $$;
revoke execute on function public.tablero_dia(text, date) from public;
grant execute on function public.tablero_dia(text, date) to anon, authenticated;

insert into public.hor_puestos (codigo, nombre, color, instrucciones, orden) values
 ('C',   'Capitán',          '#123d2a', 'Supervisar al equipo, el tee sheet y las salidas. Completar el checklist del turno en la app.', 1),
 ('S',   'Starter',          '#1f6f8b', 'Orden de salidas, puntualidad, control del tee 1 y paso por el hoyo 9. Apoyar al compañero del Range.', 2),
 ('F',   'Frente',           '#9a6410', 'Recepción, control de bolsas, atención y coordinación con Valet. Apoyar al compañero del Range.', 3),
 ('R',   'Range',            '#2e7d4f', 'Preparar el Driving Range y mantener bolas disponibles. Revisar el aceite del Range Ball y avisar a Roderick al momento.', 4),
 ('L',   'Lavar carritos',   '#5b4b8a', 'Limpieza, carga, ubicación, entrega y devolución de carritos. Reportar daños.', 5),
 ('7',   'Hoyo 7',           '#a0522d', 'Atender el puesto del hoyo 7.', 6),
 ('S/7', 'Starter / Hoyo 7', '#1f6f8b', 'Cubrir Starter y el puesto del hoyo 7.', 7),
 ('S/R', 'Starter / Range',  '#1f6f8b', 'Cubrir Starter y apoyar el Driving Range.', 8),
 ('F/R', 'Frente / Range',   '#9a6410', 'Cubrir Frente y apoyar el Driving Range.', 9),
 ('ER',  'Range nocturno',   '#24515e', 'Encargado del Driving Range de noche: preparar, atender y cerrar. Revisar el aceite del Range Ball y avisar a Roderick.', 10),
 ('E',   'Entrenamientos',   '#7a4f7a', 'Apoyo a entrenamientos y clases.', 11),
 ('P',   'Player Assistant', '#3b6e8f', 'Asistencia a jugadores en la salida y en el campo.', 12),
 ('M',   'Mecánico',         '#6b5a3a', 'Mantenimiento y reparación de carritos y equipos.', 13);
