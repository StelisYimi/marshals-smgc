create table public.tee_salidas (
  id             uuid primary key default gen_random_uuid(),
  fecha          date not null,
  hora           time not null,
  jugadores      text[] not null default '{}',
  estado         text not null default 'programada' check (estado in ('programada','salio','no_show')),
  salida_real    timestamptz,
  marcado_por    uuid references public.perfiles(id),
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  unique (fecha, hora),
  check ((estado = 'salio') = (salida_real is not null))
);
create index on public.tee_salidas (fecha, hora);
create trigger trg_tee_tocar before update on public.tee_salidas
  for each row execute function public.tocar_actualizado();

alter table public.tee_salidas enable row level security;
create policy tee_leer   on public.tee_salidas for select to authenticated using (privado.es_activo());
create policy tee_crear  on public.tee_salidas for insert to authenticated with check (privado.es_capitania());
create policy tee_editar on public.tee_salidas for update to authenticated using (privado.es_capitania()) with check (privado.es_capitania());
create policy tee_borrar on public.tee_salidas for delete to authenticated using (privado.es_gerencia());

alter publication supabase_realtime add table public.tee_salidas;
