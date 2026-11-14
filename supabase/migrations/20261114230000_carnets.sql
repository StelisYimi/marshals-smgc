-- Carnets digitales del staff
-- Un carnet por cuenta de la app: código de empleado, cargo, año de ingreso, foto y un token para el QR de verificación.
create table if not exists public.carnets (
  perfil_id   uuid primary key references public.perfiles(id) on delete cascade,
  codigo      text,
  cargo       text not null default '',
  desde       int check (desde between 1990 and 2100),
  foto_path   text,
  token       uuid not null unique default gen_random_uuid(),
  actualizado_en timestamptz not null default now()
);
alter table public.carnets enable row level security;
create policy carnets_leer on public.carnets for select to authenticated using (true);
create policy carnets_gestion on public.carnets for all to authenticated
  using (privado.es_capitania()) with check (privado.es_capitania());
create policy solo_staff on public.carnets as restrictive for all to authenticated
  using ((select privado.es_activo())) with check ((select privado.es_activo()));

-- Fotos: bucket privado; todos los activos las ven, solo Capitanes y Gerencia suben o cambian.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('carnets', 'carnets', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy carnets_fotos_leer on storage.objects for select to authenticated
  using (bucket_id = 'carnets' and (select privado.es_activo()));
create policy carnets_fotos_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'carnets' and (select privado.es_capitania()));
create policy carnets_fotos_cambiar on storage.objects for update to authenticated
  using (bucket_id = 'carnets' and (select privado.es_capitania()))
  with check (bucket_id = 'carnets' and (select privado.es_capitania()));
create policy carnets_fotos_borrar on storage.objects for delete to authenticated
  using (bucket_id = 'carnets' and (select privado.es_capitania()));

-- Carga inicial de las 19 fotos: llegan cifradas en el repositorio de la app; la clave solo la entrega esta función a Capitanes y Gerencia.
create table if not exists privado.carnets_importacion (id int primary key default 1, clave text not null, hecho boolean not null default false);
revoke all on privado.carnets_importacion from public, anon, authenticated;

create or replace function public.clave_fotos_carnets()
returns text language sql stable security definer set search_path = public as $$
  select clave from privado.carnets_importacion where id = 1 and not hecho and privado.es_capitania()
$$;
create or replace function public.fotos_carnets_importadas()
returns void language sql security definer set search_path = public as $$
  update privado.carnets_importacion set hecho = true, clave = '' where id = 1 and privado.es_capitania()
$$;
revoke all on function public.clave_fotos_carnets(), public.fotos_carnets_importadas() from public, anon;
grant execute on function public.clave_fotos_carnets(), public.fotos_carnets_importadas() to authenticated;

-- Datos de la planilla (código, cargo y año de ingreso)
insert into public.carnets (perfil_id, codigo, cargo, desde)
select p.id, d.codigo, d.cargo, d.desde
from (values
  ('gurrunaga','004','Capitán de Caddie',2013), ('acordoba','00214','Capitán de Caddie',2018),
  ('drodriguez','001','Marshal',2013), ('evargas','00222','Marshal',2018), ('ndominguez','00345','Marshal',2025),
  ('jcarlos','00226','Starter',2018), ('ltaylor','00353','Starter',2025), ('rrojas','00215','Técnico',2018),
  ('gmclean','069','Starter',2015), ('jenrique','00223','Agente de Servicio / Caddie',2018),
  ('curena','00263','Agente de Servicio / Caddie',2021), ('aotero','00323','Agente de Servicio / Caddie',2026),
  ('icalvo','00335','Agente de Servicio / Caddie',2024), ('rcorrea','00337','Agente de Servicio / Caddie',2024),
  ('jrodriguez','00341','Agente de Servicio / Caddie',2025), ('echanis','00342','Agente de Servicio / Caddie',2025),
  ('jmendoza','00362','Agente de Servicio / Caddie',2026), ('lcaballero','00364','Agente de Servicio / Caddie',2026),
  ('acanto','00365','Agente de Servicio / Caddie',2026)
) as d(usuario, codigo, cargo, desde)
join public.perfiles p on p.usuario = d.usuario
on conflict (perfil_id) do nothing;
insert into public.carnets (perfil_id, codigo, cargo, desde)
select id, '00249', 'Gerente de Operaciones', 2023 from public.perfiles where rol = 'gerente_operaciones' and usuario is null
on conflict (perfil_id) do nothing;
-- La clave de importación se inserta aparte (no queda en el repositorio).
