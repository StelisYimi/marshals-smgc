-- Starter, área D: ya no se registra el cruce por el hoyo 9
update st_areas set nota = 'Registre en la pestaña Salidas la hora real de cada salida.' where codigo = 'D';
-- D5 se desactiva (no se borra) para conservar las respuestas de reportes anteriores
update st_items set activo = false where id = 'D5';
