# SMGC · Control operativo de Santa María Golf Club

Plataforma web del departamento de Operación de Golf: la usan Marshals, Starters, Capitanes y Gerencia desde el teléfono, y una televisión muestra el horario del personal en tiempo real.

- **App:** https://app.smcapibara.com
- **Tablero de TV:** `https://app.smcapibara.com/tablero/?k=<enlace>` (Gerencia obtiene el enlace en la app, pestaña **Staff → Horario**)
- **Datos:** Supabase, proyecto `smgc-marshals` (`kqupzmmudvegropbtbwu`)

## Módulos

| Módulo | Qué hace |
|---|---|
| **Marshals** | Checklist por turno, incidencias con fotos y prioridad, protocolo de juego lento, entrega de turno, panel de Gerencia con indicadores. |
| **Starter · Mi turno** | Checklist diario del Starter (36 actividades en 7 áreas; la de funciones de Marshal solo sábados y domingos), tee asignado (1 o 10), Capitán de turno, entrega del turno anterior, firma. Funciona sin señal y sincroniza al volver. |
| **Starter · Metas y novedades** | Los 10 criterios de éxito del Impact Filter del Starter calculados con los datos del día (salidas puntuales ≥ 95%, salidas registradas 100%, cruce del 9 en meta ≥ 90%, cruces registrados ≥ 90%, salidas sin coordinar 0, ausencias sin relevo 0, reclamos escalados 100%) y registro de novedades. |
| **Starter · Salidas** | Las salidas del día por su tee: marcar salida y **cruce por el hoyo 9** (meta de la primera vuelta: 2 h 15 min). El Starter no carga el tee sheet. |
| **Capitanes · Starters** | Checklists de los Starters por fechas, cumplimiento, salidas puntuales y tiempos de cruce de su tee; los 10 criterios de éxito por tee y periodo (incluye checklists firmados 100%, cumplimiento ≥ 95% y turnos validados 100%), novedades, y el Capitán (o Gerencia) valida o retira la validación. |
| **Capitanes · Mi turno** | Checklist del Capitán (55 actividades en 8 áreas), condiciones de la cancha, puestos del equipo, insumos, firma y validación de Gerencia. |
| **Capitanes · Salidas** | Salidas del tee sheet del día, con **salida simultánea por los hoyos 1 y 10** (filtro Ambos / Hoyo 1 / Hoyo 10, próxima salida y % puntual por hoyo). Botón **Cargar tee sheet**: PDF del sistema (lectura exacta por columnas, incluida la columna Hole), PDF hecho de capturas o capturas de pantalla (lectura de imagen en el propio teléfono) o texto pegado, siempre con revisión antes de guardar. Hora real de salida, no presentados y % de salidas puntuales (tolerancia 5 min). |
| **Staff · Hoy** | Asistencia del día: quién llegó, tarde (más de 5 min), sin marcar y ausente/permiso/incapacidad, con % de llegadas puntuales (meta 95%). Cada colaborador con cuenta vinculada ve su turno y marca su llegada y salida; Capitanes, Gerencia y editores marcan o corrigen la de cualquiera y revisan días anteriores. |
| **Staff · Horario** | Horario semanal del personal: turno, función (letra), almuerzo, descanso, vacaciones y compensatorio. Botón **Cargar horarios** (Capitanes, Gerencia y editores del Staff): foto tomada con el teléfono o de la galería, captura de pantalla, Excel, PDF o texto pegado (las fotos se enderezan solas, se leen en dos versiones de contraste y se prueban giradas si vienen de lado), con la fila de los días y un colaborador por fila; cada día se lee como horario y letra (`5-1 S`, `11-7 F`, `1-9 ER`, `9:30-6 P`), `D`/`Libre`, `VAC` o `COMP`. Empareja los nombres con el personal, permite agregar personas nuevas y siempre muestra la revisión antes de guardar (función `cargar_horario`). Copiar semana anterior, personal y funciones editables. |
| **Staff · Directorio** | Personal de campo, Marshals y Capitanes: área, grupo, teléfono (llamar o WhatsApp), función habitual, funciones que puede cubrir, horario de hoy y cuenta de la app vinculada. Altas, bajas y reactivación. |
| **Staff · Permisos** | Gerencia elige quién más puede editar el Staff (tabla `staff_editores`). |
| **Capitanes · Palos de alquiler** | Entrega con revisión de piezas y firma del huésped, devolución, historial y correos de confirmación. |
| **Capitanes · Bolsas** | Bolsas de miembros por casilla: entrega y recepción. |
| **Tablero de TV** | Quién está en cada función ahora (con su asistencia: llegó, sin marcar o ausente), próximas entradas con instrucciones, almuerzos y libres del día. Sin inicio de sesión; se actualiza cada 30 s. |
| **Equipo** | Gerencia crea cuentas del staff, asigna roles y restablece contraseñas. |

## Estructura del repositorio

```
index.html                 App completa (una sola página: HTML, estilos y JavaScript)
tablero/index.html         Pantalla para la Smart TV (escenario 1920×1080 que se escala)
aplicaciones/index.html    Módulo de aplicaciones de Superintendencia (usa otro proyecto de Supabase)
manifest.webmanifest, icon-*.png, apple-touch-icon.png, logo.png   Instalación en el teléfono e identidad
CNAME                      Dominio personalizado app.smcapibara.com
supabase/
  migrations/              Base de datos completa, en orden (tablas, permisos, funciones y contenido inicial)
  functions/staff/         Función del servidor: cuentas del staff (crear, restablecer, primer gerente)
  functions/correos/       Función del servidor: correos de palos de alquiler vía Resend
```

## Cómo se publica

- **Páginas:** cada cambio en la rama `main` se publica solo con GitHub Pages en 1 o 2 minutos.
- **Dominio:** en Cloudflare (cuenta donde está `smcapibara.com`), el registro DNS `app` es un CNAME a `stelisyimi.github.io`, con proxy de Cloudflare y SSL en modo *Full*. El proyecto de Cloudflare Pages `smgc-app` es una copia vieja que ya no se usa.
- **Base de datos y funciones:** viven en Supabase. Los archivos de `supabase/` son su respaldo y la forma de recrearlas; cambiar un archivo aquí **no** cambia Supabase por sí solo.

## Restaurar o recrear el backend

Con la [CLI de Supabase](https://supabase.com/docs/guides/cli):

```bash
supabase link --project-ref <proyecto>
supabase db push                       # aplica supabase/migrations en orden
supabase functions deploy staff --no-verify-jwt
supabase functions deploy correos --no-verify-jwt
supabase secrets set RESEND_API_KEY=<clave de Resend>
```

Después, en la tabla `config_sistema`, cargar `dominio_usuarios`, `correo_gerente_inicial`, `correo_remitente` y `nombre_club`, y en `index.html` y `tablero/index.html` actualizar la URL del proyecto y la clave pública.

## Seguridad

- La clave que aparece en `index.html` y `tablero/index.html` es la **clave pública** del proyecto. Todo el acceso está protegido con seguridad a nivel de fila: solo el staff activo lee datos, y cada rol escribe solo lo suyo.
- El tablero de TV solo lee a través de la función `tablero_dia`, que exige un enlace válido de `tablero_claves`. Gerencia puede cambiar el enlace desde la app y el anterior deja de funcionar.
- Las claves secretas (Resend, clave de servicio) están solo en los *secrets* de Supabase y nunca en este repositorio.

## Roles

| Rol | Acceso |
|---|---|
| Marshal | Módulo Marshals |
| Starter | Módulo Starter y módulo Marshals (fines de semana de 3 a 7 p. m. cumple funciones de Marshal) |
| Capitán | Módulo Capitanes; en Staff marca la asistencia, ajusta a mano solo el horario de hoy y carga la semana completa con **Cargar horarios** |
| Editor del Staff (cualquier rol que Gerencia autorice) | Edita horario completo, directorio, funciones y asistencia |
| Todo el staff | Módulo Staff: ve horario, directorio y asistencia, y marca su propia llegada y salida |
| Gerente de Operaciones / de Golf, Administrador | Ambos módulos, supervisión, validación, horario semanal, cuentas del staff y enlace de la TV |
