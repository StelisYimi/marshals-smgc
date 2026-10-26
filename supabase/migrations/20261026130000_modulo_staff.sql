-- Módulo Staff: directorio del personal, asistencia del día, editores asignados por Gerencia y tablero con asistencia.

-- 1. Directorio: datos de contacto y funciones que cada persona puede cubrir
alter table public.hor_personal
  add column if not exists telefono        text,
  add column if not exists funciones       text[] not null default '{}',
  add column if not exists puesto_habitual text references public.hor_puestos(codigo) on update cascade on delete set null,
  add column if not exists notas           text;
create unique index if not exists hor_personal_perfil_unico on public.hor_personal (perfil_id) where perfil_id is not null;

-- Vincula al personal con su cuenta de la app cuando el nombre coincide (sin importar tildes)
update public.hor_personal hp set perfil_id = p.id
from public.perfiles p
where hp.perfil_id is null
  and lower(translate(hp.nombre, 'ÁÉÍÓÚÜáéíóúüÑñ', 'AEIOUUaeiouuNn')) = lower(translate(p.nombre, 'ÁÉÍÓÚÜáéíóúüÑñ', 'AEIOUUaeiouuNn'))
  and not exists (select 1 from public.hor_personal x where x.perfil_id = p.id);
update public.hor_personal hp set area = case p.rol::text when 'capitan' then 'capitan' when 'marshal' then 'marshal' else hp.area end
from public.perfiles p where p.id = hp.perfil_id;

-- 2. Editores del Staff: personas que Gerencia autoriza a editar horario, directorio y asistencia
create table if not exists public.staff_editores (
  perfil_id    uuid primary key references public.perfiles(id) on delete cascade,
  agregado_por uuid references public.perfiles(id) default auth.uid(),
  agregado_en  timestamptz not null default now()
);
alter table public.staff_editores enable row level security;
create policy leer on public.staff_editores for select to authenticated using (privado.es_activo());
create policy ger  on public.staff_editores for all to authenticated using (privado.es_gerencia()) with check (privado.es_gerencia());

create or replace function privado.es_editor_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select privado.es_gerencia() or exists (
    select 1 from staff_editores e join perfiles p on p.id = e.perfil_id where e.perfil_id = auth.uid() and p.activo)
$$;

create policy editor on public.hor_personal for all to authenticated using (privado.es_editor_staff()) with check (privado.es_editor_staff());
create policy editor on public.hor_turnos   for all to authenticated using (privado.es_editor_staff()) with check (privado.es_editor_staff());
create policy editor on public.hor_puestos  for all to authenticated using (privado.es_editor_staff()) with check (privado.es_editor_staff());

-- 3. Asistencia del día
create table if not exists public.hor_asistencia (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null,
  personal_id    uuid not null references public.hor_personal(id) on delete cascade,
  estado         text not null default 'presente' check (estado in ('presente','ausente','permiso','incapacidad')),
  llegada        timestamptz,
  salida         timestamptz,
  nota           text,
  marcado_por    uuid references public.perfiles(id) default auth.uid(),
  actualizado_en timestamptz not null default now(),
  unique (fecha, personal_id),
  check (estado = 'presente' or (llegada is null and salida is null)),
  check (salida is null or (llegada is not null and salida > llegada))
);
create index if not exists hor_asistencia_fecha on public.hor_asistencia (fecha);
create trigger trg_asis_tocar before update on public.hor_asistencia for each row execute function public.tocar_actualizado();
alter table public.hor_asistencia enable row level security;
create policy leer   on public.hor_asistencia for select to authenticated using (privado.es_activo());
create policy editar on public.hor_asistencia for all to authenticated
  using (privado.es_capitania() or privado.es_editor_staff())
  with check (privado.es_capitania() or privado.es_editor_staff());
alter publication supabase_realtime add table public.hor_asistencia;

-- Cada colaborador con cuenta marca su propia llegada y salida (solo hoy y solo a la hora real)
create or replace function public.marcar_mi_asistencia(p_accion text)
returns json language plpgsql security definer set search_path = public as $$
declare pid uuid; f date := (now() at time zone 'America/Panama')::date; a hor_asistencia;
begin
  if not privado.es_activo() then raise exception 'Su cuenta no está activa.'; end if;
  select id into pid from hor_personal where perfil_id = auth.uid() and activo;
  if pid is null then raise exception 'Su cuenta todavía no está vinculada a un colaborador del Staff. Pídale a Gerencia que la vincule en el Directorio.'; end if;
  select * into a from hor_asistencia where fecha = f and personal_id = pid;
  if p_accion = 'llegada' then
    if a.id is not null and a.llegada is not null then raise exception 'Su llegada ya está marcada a las %.', to_char(a.llegada at time zone 'America/Panama', 'HH12:MI am'); end if;
    if a.id is not null and a.estado <> 'presente' then raise exception 'Hoy aparece como %. Pídale al Capitán que lo corrija.', a.estado; end if;
    insert into hor_asistencia (fecha, personal_id, estado, llegada) values (f, pid, 'presente', now())
      on conflict (fecha, personal_id) do update set llegada = now(), estado = 'presente', marcado_por = auth.uid();
  elsif p_accion = 'salida' then
    if a.id is null or a.llegada is null then raise exception 'Primero marque su llegada.'; end if;
    if a.salida is not null then raise exception 'Su salida ya está marcada.'; end if;
    update hor_asistencia set salida = now(), marcado_por = auth.uid() where id = a.id;
  else
    raise exception 'Acción no válida.';
  end if;
  select * into a from hor_asistencia where fecha = f and personal_id = pid;
  return row_to_json(a);
end $$;
revoke execute on function public.marcar_mi_asistencia(text) from public, anon;
grant execute on function public.marcar_mi_asistencia(text) to authenticated;

-- 4. Tablero de TV: ahora incluye la asistencia de cada persona
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
                 'almuerzo_inicio',to_char(t.almuerzo_inicio,'HH24:MI'),'almuerzo_fin',to_char(t.almuerzo_fin,'HH24:MI'),'nota',t.nota,
                 'asistencia',a.estado,
                 'llegada',to_char(a.llegada at time zone 'America/Panama','HH24:MI'),
                 'salida',to_char(a.salida at time zone 'America/Panama','HH24:MI'))
                 order by t.inicio nulls last, p.orden, p.nombre), '[]')
               from hor_turnos t join hor_personal p on p.id = t.personal_id
               left join hor_asistencia a on a.fecha = t.fecha and a.personal_id = t.personal_id
               where t.fecha = f and p.activo)
  );
end $$;
revoke execute on function public.tablero_dia(text, date) from public;
grant execute on function public.tablero_dia(text, date) to anon, authenticated;

-- 5. Cargar horarios: también pueden usarlo los editores del Staff
create or replace function public.cargar_horario(p_lunes date, p_filas jsonb, p_reemplazar boolean default true)
returns json language plpgsql security definer set search_path = public as $$
declare
  f jsonb; pid uuid; nom text; creadas int := 0; actualizadas int := 0; omitidas int := 0; nuevas int := 0;
  orden_max smallint; ya boolean; fch date;
begin
  if not (privado.es_capitania() or privado.es_editor_staff()) then raise exception 'Solo Capitanes, Gerencia o los editores del Staff pueden cargar el horario.'; end if;
  if extract(isodow from p_lunes) <> 1 then raise exception 'La semana debe empezar en lunes.'; end if;
  if jsonb_typeof(p_filas) <> 'array' or jsonb_array_length(p_filas) = 0 then raise exception 'No hay días para guardar.'; end if;
  if jsonb_array_length(p_filas) > 700 then raise exception 'Demasiadas filas en una sola carga.'; end if;

  for f in select * from jsonb_array_elements(p_filas) loop
    fch := (f->>'fecha')::date;
    if fch < p_lunes or fch > p_lunes + 6 then raise exception 'La fecha % no pertenece a la semana del %.', fch, p_lunes; end if;

    pid := nullif(f->>'personal_id', '')::uuid;
    if pid is null then
      nom := btrim(regexp_replace(coalesce(f->>'nombre_nuevo', ''), '\s+', ' ', 'g'));
      if length(nom) < 3 then raise exception 'Falta indicar a quién corresponde una fila.'; end if;
      select id into pid from hor_personal where activo and lower(nombre) = lower(nom) limit 1;
      if pid is null then
        select coalesce(max(orden), 0) into orden_max from hor_personal;
        insert into hor_personal (nombre, grupo, orden)
          values (nom, coalesce(nullif(btrim(f->>'grupo'), ''), 'Operación de golf'), orden_max + 1)
          returning id into pid;
        nuevas := nuevas + 1;
      end if;
    elsif not exists (select 1 from hor_personal where id = pid and activo) then
      raise exception 'Una de las personas ya no está activa en el horario.';
    end if;

    ya := exists (select 1 from hor_turnos where fecha = fch and personal_id = pid);
    if ya and not p_reemplazar then omitidas := omitidas + 1; continue; end if;

    insert into hor_turnos (fecha, personal_id, tipo, inicio, fin, puesto, almuerzo_inicio, almuerzo_fin, nota)
    values (fch, pid, f->>'tipo',
            nullif(f->>'inicio','')::time, nullif(f->>'fin','')::time, nullif(f->>'puesto',''),
            nullif(f->>'almuerzo_inicio','')::time, nullif(f->>'almuerzo_fin','')::time, nullif(btrim(coalesce(f->>'nota','')), ''))
    on conflict (fecha, personal_id) do update set
      tipo = excluded.tipo, inicio = excluded.inicio, fin = excluded.fin, puesto = excluded.puesto,
      almuerzo_inicio = excluded.almuerzo_inicio, almuerzo_fin = excluded.almuerzo_fin, nota = excluded.nota,
      creado_por = auth.uid();
    if ya then actualizadas := actualizadas + 1; else creadas := creadas + 1; end if;
  end loop;

  return json_build_object('creadas', creadas, 'actualizadas', actualizadas, 'omitidas', omitidas, 'personas_nuevas', nuevas);
end $$;
revoke execute on function public.cargar_horario(date, jsonb, boolean) from public, anon;
grant execute on function public.cargar_horario(date, jsonb, boolean) to authenticated;
