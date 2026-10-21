-- ============ Módulo Capitanes: palos de alquiler y bolsas de miembros ============
create or replace function privado.es_capitania() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select activo and rol::text in ('capitan','gerente_operaciones','gerente_golf','admin') from perfiles where id = auth.uid()), false)
$$;
revoke execute on function privado.es_capitania() from public, anon;
grant execute on function privado.es_capitania() to authenticated;

create type tipo_juego      as enum ('regular','stiff','senior','damas','zurdos');
create type estado_juego    as enum ('disponible','alquilado','mantenimiento');
create type estado_alquiler as enum ('activo','cerrado','anulado');
create type estado_bolsa    as enum ('en_casilla','entregada','sin_bolsa');

create table juegos_alquiler (
  id            text primary key,                 -- REG-01, STF-01…
  tipo          tipo_juego not null,
  estado        estado_juego not null default 'disponible',
  descripcion   text,                             -- marca / modelo
  notas         text,
  orden         smallint not null default 0,
  activo        boolean not null default true,
  actualizado_en timestamptz not null default now()
);
create table juego_piezas (
  id        uuid primary key default gen_random_uuid(),
  juego_id  text not null references juegos_alquiler(id) on delete cascade,
  pieza     text not null,
  cantidad  smallint not null default 1 check (cantidad > 0),
  orden     smallint not null default 0
);
create index on juego_piezas (juego_id, orden);

create table alquileres (
  id               uuid primary key default gen_random_uuid(),
  folio            bigint generated always as identity unique,
  juego_id         text not null references juegos_alquiler(id),
  huesped_nombre   text not null,
  huesped_correo   text not null check (huesped_correo ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  huesped_telefono text,
  tipo_cliente     text not null default 'huesped' check (tipo_cliente in ('huesped','invitado')),
  referencia       text,                         -- habitación o miembro anfitrión
  salida_en        timestamptz not null default now(),
  capitan_salida   uuid not null references perfiles(id),
  check_salida     jsonb not null,               -- [{pieza, cantidad, ok}]
  firma            text,                         -- imagen PNG (data URL) de la firma del huésped
  estado           estado_alquiler not null default 'activo',
  devuelto_en      timestamptz,
  capitan_entrada  uuid references perfiles(id),
  check_entrada    jsonb,                        -- [{pieza, cantidad, estado:'ok'|'falta'|'danado', nota}]
  todo_ok          boolean,
  observaciones_cierre text
);
create index on alquileres (estado, salida_en desc);
create index on alquileres (juego_id);
create unique index un_alquiler_activo_por_juego on alquileres (juego_id) where estado = 'activo';

create table correos (
  id            uuid primary key default gen_random_uuid(),
  alquiler_id   uuid references alquileres(id) on delete cascade,
  tipo          text not null check (tipo in ('entrega','cierre')),
  destinatario  text not null,
  estado        text not null default 'pendiente' check (estado in ('pendiente','enviado','error')),
  error         text,
  proveedor_id  text,
  intentos      smallint not null default 0,
  creado_en     timestamptz not null default now(),
  enviado_en    timestamptz
);
create index on correos (estado);
create index on correos (alquiler_id);

create table casillas (
  numero  integer primary key check (numero > 0),
  zona    text,
  activa  boolean not null default true
);
create table miembros (
  id            uuid primary key default gen_random_uuid(),
  numero        text not null unique,
  nombre        text not null,
  telefono      text,
  casilla       integer unique references casillas(numero),
  estado_bolsa  estado_bolsa not null default 'en_casilla',
  notas         text,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now()
);
create index on miembros (lower(nombre));
create table movimientos_bolsa (
  id          uuid primary key default gen_random_uuid(),
  miembro_id  uuid not null references miembros(id) on delete cascade,
  casilla     integer,
  tipo        text not null check (tipo in ('entrega','recepcion')),
  por         uuid not null references perfiles(id),
  en          timestamptz not null default now(),
  nota        text
);
create index on movimientos_bolsa (en desc);
create index on movimientos_bolsa (miembro_id, en desc);

-- ---------- Operaciones atómicas (mantienen el tablero siempre consistente) ----------
create or replace function public.entregar_juego(p_juego text, p_nombre text, p_correo text, p_telefono text,
  p_tipo_cliente text, p_referencia text, p_check jsonb, p_firma text) returns uuid
language plpgsql security definer set search_path = public as $$
declare j juegos_alquiler; nuevo uuid;
begin
  if not privado.es_capitania() then raise exception 'Solo Capitanes o Gerencia pueden entregar palos'; end if;
  select * into j from juegos_alquiler where id = p_juego for update;
  if j.id is null or not j.activo then raise exception 'Juego no encontrado'; end if;
  if j.estado <> 'disponible' then raise exception 'El juego % no está disponible', p_juego; end if;
  if exists (select 1 from jsonb_array_elements(p_check) e where coalesce((e->>'ok')::boolean, false) = false) then
    raise exception 'El huésped debe confirmar cada pieza'; end if;
  if coalesce(length(p_firma), 0) < 200 then raise exception 'Falta la firma del huésped'; end if;
  insert into alquileres (juego_id, huesped_nombre, huesped_correo, huesped_telefono, tipo_cliente, referencia, capitan_salida, check_salida, firma)
  values (p_juego, trim(p_nombre), lower(trim(p_correo)), nullif(trim(p_telefono),''), p_tipo_cliente, nullif(trim(p_referencia),''), auth.uid(), p_check, p_firma)
  returning id into nuevo;
  update juegos_alquiler set estado = 'alquilado', actualizado_en = now() where id = p_juego;
  insert into correos (alquiler_id, tipo, destinatario) values (nuevo, 'entrega', lower(trim(p_correo)));
  return nuevo;
end $$;

create or replace function public.recibir_juego(p_alquiler uuid, p_check jsonb, p_observaciones text, p_mantenimiento boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a alquileres; ok boolean;
begin
  if not privado.es_capitania() then raise exception 'Solo Capitanes o Gerencia pueden recibir palos'; end if;
  select * into a from alquileres where id = p_alquiler for update;
  if a.id is null then raise exception 'Alquiler no encontrado'; end if;
  if a.estado <> 'activo' then raise exception 'Este alquiler ya fue cerrado'; end if;
  ok := not exists (select 1 from jsonb_array_elements(p_check) e where coalesce(e->>'estado','') <> 'ok');
  update alquileres set estado = 'cerrado', devuelto_en = now(), capitan_entrada = auth.uid(), check_entrada = p_check,
    todo_ok = ok, observaciones_cierre = nullif(trim(p_observaciones),'') where id = p_alquiler;
  update juegos_alquiler set estado = case when p_mantenimiento or not ok then 'mantenimiento'::estado_juego else 'disponible'::estado_juego end,
    actualizado_en = now() where id = a.juego_id;
  insert into correos (alquiler_id, tipo, destinatario) values (p_alquiler, 'cierre', a.huesped_correo);
end $$;

create or replace function public.mover_bolsa(p_miembro uuid, p_tipo text, p_nota text default null) returns estado_bolsa
language plpgsql security definer set search_path = public as $$
declare m miembros; nuevo estado_bolsa;
begin
  if not privado.es_capitania() then raise exception 'Solo Capitanes o Gerencia pueden mover bolsas'; end if;
  select * into m from miembros where id = p_miembro for update;
  if m.id is null then raise exception 'Miembro no encontrado'; end if;
  if p_tipo = 'entrega' then
    if m.estado_bolsa <> 'en_casilla' then raise exception 'La bolsa de este miembro no está en su casilla'; end if;
    nuevo := 'entregada';
  elsif p_tipo = 'recepcion' then
    if m.casilla is null then raise exception 'Asigne una casilla al miembro antes de guardar la bolsa'; end if;
    nuevo := 'en_casilla';
  else raise exception 'Movimiento no válido'; end if;
  update miembros set estado_bolsa = nuevo where id = p_miembro;
  insert into movimientos_bolsa (miembro_id, casilla, tipo, por, nota) values (p_miembro, m.casilla, p_tipo, auth.uid(), nullif(trim(p_nota),''));
  return nuevo;
end $$;
revoke execute on function public.entregar_juego(text,text,text,text,text,text,jsonb,text), public.recibir_juego(uuid,jsonb,text,boolean), public.mover_bolsa(uuid,text,text) from public, anon;
grant execute on function public.entregar_juego(text,text,text,text,text,text,jsonb,text), public.recibir_juego(uuid,jsonb,text,boolean), public.mover_bolsa(uuid,text,text) to authenticated;

-- ---------- Permisos: solo Capitanes y Gerencia ----------
alter table juegos_alquiler   enable row level security;
alter table juego_piezas      enable row level security;
alter table alquileres        enable row level security;
alter table correos           enable row level security;
alter table casillas          enable row level security;
alter table miembros          enable row level security;
alter table movimientos_bolsa enable row level security;

create policy cap_leer on juegos_alquiler   for select to authenticated using ((select privado.es_capitania()));
create policy cap_leer on juego_piezas      for select to authenticated using ((select privado.es_capitania()));
create policy cap_leer on alquileres        for select to authenticated using ((select privado.es_capitania()));
create policy cap_leer on correos           for select to authenticated using ((select privado.es_capitania()));
create policy cap_leer on casillas          for select to authenticated using ((select privado.es_capitania()));
create policy cap_leer on miembros          for select to authenticated using ((select privado.es_capitania()));
create policy cap_leer on movimientos_bolsa for select to authenticated using ((select privado.es_capitania()));

create policy cap_editar  on juegos_alquiler for update to authenticated using ((select privado.es_capitania())) with check ((select privado.es_capitania()));
create policy cap_ins     on juego_piezas    for insert to authenticated with check ((select privado.es_capitania()));
create policy cap_upd     on juego_piezas    for update to authenticated using ((select privado.es_capitania())) with check ((select privado.es_capitania()));
create policy cap_del     on juego_piezas    for delete to authenticated using ((select privado.es_capitania()));
create policy cap_ins     on casillas        for insert to authenticated with check ((select privado.es_capitania()));
create policy cap_upd     on casillas        for update to authenticated using ((select privado.es_capitania())) with check ((select privado.es_capitania()));
create policy cap_ins     on miembros        for insert to authenticated with check ((select privado.es_capitania()));
create policy cap_upd     on miembros        for update to authenticated using ((select privado.es_capitania())) with check ((select privado.es_capitania()));

create policy solo_staff on juegos_alquiler   as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on juego_piezas      as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on alquileres        as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on correos           as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on casillas          as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on miembros          as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));
create policy solo_staff on movimientos_bolsa as restrictive for all to authenticated using ((select privado.es_activo())) with check ((select privado.es_activo()));

-- ---------- Inventario inicial de palos de alquiler ----------
insert into juegos_alquiler (id, tipo, orden)
select prefijo || '-' || lpad(n::text, 2, '0'), tipo::tipo_juego, ord * 100 + n
from (values ('REG','regular',8,1),('STF','stiff',5,2),('SEN','senior',4,3),('DAM','damas',4,4),('ZUR','zurdos',3,5)) as t(prefijo,tipo,total,ord),
     generate_series(1, total) as n;

insert into juego_piezas (juego_id, pieza, cantidad, orden)
select j.id, p.pieza, p.cantidad, p.orden
from juegos_alquiler j,
     (values ('Driver',1,1),('Madera 3',1,2),('Híbrido',1,3),('Hierros 5 al 9',5,4),('Pitching wedge',1,5),('Sand wedge',1,6),('Putter',1,7),('Bolsa',1,8),('Cubrepalos',3,9)) as p(pieza,cantidad,orden);

insert into config_sistema (clave, valor) values
 ('correo_remitente', 'Santa María Golf Club <palos@smcapibara.com>'),
 ('nombre_club', 'Santa María Golf Club')
on conflict (clave) do nothing;
