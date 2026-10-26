-- Staff: solo Gerencia y Capitanes administran (horario completo, directorio, contactos y asistencia).
-- El resto del personal (Marshals, Starters) solo ve el horario publicado, en la app y en la TV.

-- 1. Sin editores asignables ni marca propia de asistencia
drop policy if exists editor on public.hor_personal;
drop policy if exists editor on public.hor_turnos;
drop policy if exists editor on public.hor_puestos;
drop policy if exists ger    on public.hor_personal;
drop policy if exists ger    on public.hor_puestos;
drop policy if exists editar on public.hor_turnos;
drop function if exists public.marcar_mi_asistencia(text);
drop function if exists privado.es_editor_staff() cascade;
drop table if exists public.staff_editores;

-- 2. Gerencia y Capitanes editan el horario de cualquier día, el personal y las funciones
create policy capitania on public.hor_personal for all to authenticated using (privado.es_capitania()) with check (privado.es_capitania());
create policy capitania on public.hor_puestos  for all to authenticated using (privado.es_capitania()) with check (privado.es_capitania());
create policy capitania on public.hor_turnos   for all to authenticated using (privado.es_capitania()) with check (privado.es_capitania());

-- 3. Asistencia: solo Gerencia y Capitanes la ven y la marcan
drop policy if exists leer   on public.hor_asistencia;
drop policy if exists editar on public.hor_asistencia;
create policy capitania on public.hor_asistencia for all to authenticated using (privado.es_capitania()) with check (privado.es_capitania());

-- 4. Teléfono y notas del personal en tabla aparte, visible solo para Gerencia y Capitanes
create table public.hor_contactos (
  personal_id uuid primary key references public.hor_personal(id) on delete cascade,
  telefono    text,
  notas       text
);
insert into public.hor_contactos (personal_id, telefono, notas)
  select id, telefono, notas from public.hor_personal where telefono is not null or notas is not null;
alter table public.hor_personal drop column if exists telefono, drop column if exists notas;
alter table public.hor_contactos enable row level security;
create policy capitania on public.hor_contactos for all to authenticated using (privado.es_capitania()) with check (privado.es_capitania());

-- 5. Cargar horarios: Gerencia y Capitanes
create or replace function public.cargar_horario(p_lunes date, p_filas jsonb, p_reemplazar boolean default true)
returns json language plpgsql security definer set search_path = public as $$
declare
  f jsonb; pid uuid; nom text; creadas int := 0; actualizadas int := 0; omitidas int := 0; nuevas int := 0;
  orden_max smallint; ya boolean; fch date;
begin
  if not privado.es_capitania() then raise exception 'Solo Capitanes o Gerencia pueden cargar el horario.'; end if;
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
