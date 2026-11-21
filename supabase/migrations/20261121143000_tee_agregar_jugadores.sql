-- Agregar jugadores en un tee time libre: Gerencia, Capitanes, Starters y Marshals.
-- Crea la salida como "programada" solo con fecha, hora, hoyo y jugadores.
create or replace function public.agregar_salida_tee(p_fecha date, p_hora time, p_hoyo smallint, p_jugadores text[])
returns public.tee_salidas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok boolean;
  v_lista text[];
  v_fila public.tee_salidas;
begin
  select coalesce((select activo and rol::text in ('marshal','starter','capitan','gerente_operaciones','gerente_golf','admin')
                   from perfiles where id = auth.uid()), false) into v_ok;
  if not v_ok then
    raise exception 'Su usuario no tiene permiso para agregar jugadores al tee sheet.';
  end if;
  if p_hoyo not in (1, 10) then
    raise exception 'La salida debe ser por el hoyo 1 o el hoyo 10.';
  end if;
  if p_fecha < ((now() at time zone 'America/Panama')::date - 1) then
    raise exception 'No se pueden agregar jugadores en días pasados.';
  end if;
  select coalesce(array_agg(btrim(j) order by o), '{}') into v_lista
    from unnest(coalesce(p_jugadores, '{}')) with ordinality as u(j, o)
   where btrim(j) <> '';
  if array_length(v_lista, 1) is null then
    raise exception 'Escriba al menos un jugador.';
  end if;
  if array_length(v_lista, 1) > 4 then
    raise exception 'Un tee time tiene como máximo 4 jugadores.';
  end if;
  if exists (select 1 from unnest(v_lista) j where length(j) > 60) then
    raise exception 'Hay un nombre demasiado largo (máximo 60 caracteres).';
  end if;
  begin
    insert into tee_salidas (fecha, hora, hoyo, jugadores, jugadores_editado_por, jugadores_editado_en)
    values (p_fecha, p_hora, p_hoyo, v_lista, auth.uid(), now())
    returning * into v_fila;
  exception when unique_violation then
    raise exception 'Alguien acaba de ocupar ese tee time. Actualice la pantalla y use "+ Jugador" si quedan cupos.';
  end;
  return v_fila;
end $$;

revoke all on function public.agregar_salida_tee(date, time, smallint, text[]) from public, anon;
grant execute on function public.agregar_salida_tee(date, time, smallint, text[]) to authenticated;
