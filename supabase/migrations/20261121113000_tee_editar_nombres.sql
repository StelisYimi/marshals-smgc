-- Editar los nombres de los jugadores del tee sheet:
-- Gerencia, Capitanes, Starters y Marshals pueden cambiar SOLO la lista de jugadores
-- de una salida existente. Hora, hoyo y estado siguen con los permisos de antes.
alter table public.tee_salidas
  add column if not exists jugadores_editado_por uuid references public.perfiles(id),
  add column if not exists jugadores_editado_en timestamptz;

create or replace function public.editar_jugadores_tee(p_salida uuid, p_jugadores text[])
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
    raise exception 'Su usuario no tiene permiso para editar los nombres del tee sheet.';
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
  update tee_salidas
     set jugadores = v_lista, jugadores_editado_por = auth.uid(), jugadores_editado_en = now()
   where id = p_salida
  returning * into v_fila;
  if not found then
    raise exception 'La salida ya no existe. Actualice la pantalla.';
  end if;
  return v_fila;
end $$;

revoke all on function public.editar_jugadores_tee(uuid, text[]) from public, anon;
grant execute on function public.editar_jugadores_tee(uuid, text[]) to authenticated;
