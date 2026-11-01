-- Reportes por correo: cada checklist firmado (Marshals, Starter, Capitanes, Staff y Mecánico)
-- entra en una cola y la función "reportes" lo envía con un Excel adjunto al correo de Gerencia.
insert into public.config_sistema (clave, valor) values ('correo_reportes', 'Ystelis@santamariapanama.com')
on conflict (clave) do update set valor = excluded.valor;

create table public.correos_reportes (
  id uuid primary key default gen_random_uuid(),
  modulo text not null check (modulo in ('marshals','starter','capitanes','staff')),
  reporte_id uuid not null,
  fecha date not null,
  destinatario text,
  estado text not null default 'pendiente' check (estado in ('pendiente','enviado','error')),
  intentos smallint not null default 0,
  error text,
  proveedor_id text,
  creado_en timestamptz not null default now(),
  enviado_en timestamptz,
  unique (modulo, reporte_id)
);
create index on public.correos_reportes (estado, creado_en);
alter table public.correos_reportes enable row level security;
create policy leer on public.correos_reportes for select to authenticated
  using (exists (select 1 from public.perfiles p where p.id = auth.uid() and p.activo and p.rol in ('capitan','gerente_operaciones','gerente_golf','admin')));

create or replace function privado.encolar_reporte_correo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.estado::text = 'firmado' and (tg_op = 'INSERT' or old.estado is distinct from new.estado) then
    insert into public.correos_reportes (modulo, reporte_id, fecha)
    values (tg_argv[0], new.id, new.fecha)
    on conflict (modulo, reporte_id) do nothing;
  end if;
  return new;
end $$;
revoke all on function privado.encolar_reporte_correo() from public;

create trigger trg_correo_reporte after insert or update of estado on public.reportes_turno for each row execute function privado.encolar_reporte_correo('marshals');
create trigger trg_correo_reporte after insert or update of estado on public.st_reportes    for each row execute function privado.encolar_reporte_correo('starter');
create trigger trg_correo_reporte after insert or update of estado on public.cap_reportes   for each row execute function privado.encolar_reporte_correo('capitanes');
create trigger trg_correo_reporte after insert or update of estado on public.op_reportes    for each row execute function privado.encolar_reporte_correo('staff');

-- (aplicado aparte) Envío automático: la base de datos llama a la función "reportes" al firmar,
-- con la cabecera x-reportes-secreto (config_sistema.reportes_secreto). Ver también las columnas
-- colaborador y detalle que llena el trigger para el panel de Gerencia.
