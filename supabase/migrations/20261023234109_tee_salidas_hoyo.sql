-- Salidas simultáneas (double start): cada salida indica si sale por el hoyo 1 o por el 10
alter table public.tee_salidas add column hoyo smallint not null default 1 check (hoyo in (1, 10));
alter table public.tee_salidas drop constraint tee_salidas_fecha_hora_key;
alter table public.tee_salidas add constraint tee_salidas_fecha_hora_hoyo_key unique (fecha, hora, hoyo);
