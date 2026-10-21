create extension if not exists btree_gist with schema extensions;

create table public.hor_puestos (
  codigo        text primary key,
  nombre        text not null,
  color         text not null default '#123d2a',
  instrucciones text,
  es_pausa      boolean not null default false,
  orden         smallint not null default 0,
  activo        boolean not null default true
);

create table public.hor_personal (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  area       text not null default 'campo' check (area in ('campo','marshal','capitan')),
  perfil_id  uuid references public.perfiles(id) on delete set null,
  activo     boolean not null default true,
  creado_en  timestamptz not null default now()
);

create table public.hor_bloques (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null,
  personal_id    uuid not null references public.hor_personal(id) on delete cascade,
  puesto         text not null references public.hor_puestos(codigo),
  inicio         time not null,
  fin            time not null,
  nota           text,
  creado_por     uuid references public.perfiles(id) default auth.uid(),
  actualizado_en timestamptz not null default now(),
  check (fin > inicio),
  constraint hor_sin_traslape exclude using gist (
    personal_id with =,
    tsrange(fecha + inicio, fecha + fin) with &&
  )
);
create index on public.hor_bloques (fecha, inicio);
create trigger trg_hor_tocar before update on public.hor_bloques for each row execute function public.tocar_actualizado();

create table public.tablero_claves (
  token     text primary key default encode(extensions.gen_random_bytes(18), 'hex'),
  creado_en timestamptz not null default now(),
  activo    boolean not null default true
);

alter table public.hor_puestos    enable row level security;
alter table public.hor_personal   enable row level security;
alter table public.hor_bloques    enable row level security;
alter table public.tablero_claves enable row level security;

create policy leer   on public.hor_puestos for select to authenticated using (privado.es_activo());
create policy ger    on public.hor_puestos for all to authenticated using (privado.es_gerencia()) with check (privado.es_gerencia());
create policy leer   on public.hor_personal for select to authenticated using (privado.es_activo());
create policy ger    on public.hor_personal for all to authenticated using (privado.es_gerencia()) with check (privado.es_gerencia());
create policy leer   on public.hor_bloques for select to authenticated using (privado.es_activo());
create policy editar on public.hor_bloques for all to authenticated
  using (privado.es_gerencia() or (privado.es_capitania() and fecha = (now() at time zone 'America/Panama')::date))
  with check (privado.es_gerencia() or (privado.es_capitania() and fecha = (now() at time zone 'America/Panama')::date));
create policy ger    on public.tablero_claves for all to authenticated using (privado.es_gerencia()) with check (privado.es_gerencia());

-- Lectura para la televisión: solo con un enlace válido, sin iniciar sesión
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
    'puestos', (select coalesce(json_agg(json_build_object('codigo',codigo,'nombre',nombre,'color',color,'instrucciones',instrucciones,'es_pausa',es_pausa) order by orden), '[]') from hor_puestos where activo),
    'bloques', (select coalesce(json_agg(json_build_object('persona',p.nombre,'area',p.area,'puesto',b.puesto,'inicio',to_char(b.inicio,'HH24:MI'),'fin',to_char(b.fin,'HH24:MI'),'nota',b.nota) order by b.inicio, p.nombre), '[]')
                from hor_bloques b join hor_personal p on p.id = b.personal_id where b.fecha = f and p.activo)
  );
end $$;
revoke execute on function public.tablero_dia(text, date) from public;
grant execute on function public.tablero_dia(text, date) to anon, authenticated;

alter publication supabase_realtime add table public.hor_bloques;

insert into public.hor_puestos (codigo, nombre, color, instrucciones, es_pausa, orden) values
 ('capitan',  'Capitán',        '#123d2a', 'Supervisar al equipo, el tee sheet y las salidas. Atender incidencias y entregar el turno.', false, 1),
 ('starter',  'Starter',        '#1f6f8b', 'Orden de salidas, puntualidad, control del tee 1 y paso por el hoyo 9.', false, 2),
 ('frente',   'Frente',         '#8a5a12', 'Recepción, control de bolsas, organización, atención y coordinación con Valet.', false, 3),
 ('carritos', 'Carritos',       '#5b4b8a', 'Limpieza, carga, ubicación, entrega, devolución y reporte de daños.', false, 4),
 ('range',    'Driving Range',  '#2e7d4f', 'Preparar el área, mantener bolas disponibles y cuidar la seguridad de práctica.', false, 5),
 ('divots',   'Divots',         '#7a6a2c', 'Reparar las áreas asignadas, con seguridad y coordinando con Mantenimiento.', false, 6),
 ('marshal',  'Marshal',        '#9b3d2e', 'Reglas, ritmo de juego y comunicación de incidentes en el campo.', false, 7),
 ('comodin',  'Comodín',        '#4a5a66', 'Refuerzos operativos y tareas específicas asignadas por el Capitán.', false, 8),
 ('almuerzo', 'Almuerzo / descanso', '#8c8c84', 'Tiempo de almuerzo o descanso.', true, 9);

insert into public.tablero_claves default values;
