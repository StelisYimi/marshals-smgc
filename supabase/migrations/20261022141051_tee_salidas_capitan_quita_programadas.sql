-- Al recargar el tee sheet, un Capitán puede quitar salidas canceladas que aún no se marcaron
create policy tee_borrar_cap on public.tee_salidas for delete to authenticated
  using (privado.es_capitania() and estado = 'programada');
