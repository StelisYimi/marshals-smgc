// Reportes por correo · Santa María Golf Club
// Cada checklist firmado (Marshals, Starter, Capitanes, Staff y Mecánico) entra en la cola "correos_reportes"
// (trigger en la base de datos). Esta función envía los pendientes al correo de Gerencia (config_sistema.correo_reportes)
// con un resumen y un Excel adjunto. El Excel trae la hoja "Registro" con columnas iguales para todos los módulos,
// para acumular la operación y armar gráficos.
// Acciones: { accion: "procesar", reporte_id? }  → envía los pendientes (todos o el de un reporte).
//           { accion: "reenviar", id }           → vuelve a enviar uno ya enviado (solo Capitanes o Gerencia).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import * as XLSX from "npm:xlsx@0.18.5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  return keys["default"] ?? Object.values(keys)[0] as string;
}
const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false, autoRefreshToken: false } });
const CAPITANIA = ["capitan", "gerente_operaciones", "gerente_golf", "admin"];
const LOGO = "https://stelisyimi.github.io/marshals-smgc/logo.png";
const APP = "https://app.smcapibara.com";

const TURNO: Record<string, string> = { apertura: "Apertura", cierre: "Cierre" };
const VAL: Record<string, string> = { si: "Sí", no: "No", na: "N/A" };
const POS: Record<string, string> = { F: "Frente", L: "Carritos", R: "Driving Range", M: "Mecánico" };
const CATS: Record<string, string> = { ritmo_juego: "Ritmo de juego", campo_carritos: "Campo y carritos", agronomia_riego: "Agronomía y riego", seguridad: "Seguridad", instalaciones: "Instalaciones", atencion_miembros: "Atención a miembros" };
const PRIO: Record<string, string> = { critica: "Crítica", alta: "Alta", ordinaria: "Ordinaria" };
const NIVEL: Record<string, string> = { suficiente: "Suficiente", bajo: "Bajo", agotado: "Agotado" };
const INSUMOS: Record<string, string> = { tarjetas: "Tarjetas de score", tees: "Tees", lapices: "Lápices", toallas: "Toallas", bolas: "Bolas de práctica", agua: "Agua" };
const EST_PUESTO: Record<string, string> = { presente: "Presente", ausente: "Ausente", cubierto: "Cubierto" };
const BANDERA: Record<string, string> = { frente: "Frente", centro: "Centro", atras: "Atrás", mixta: "Mixta" };
const CARRITOS: Record<string, string> = { libre: "Libre", "90": "Regla de 90°", cart_path: "Cart path only", sin_carritos: "Sin carritos" };
const NIVEL_BOLAS: Record<string, string> = { suficientes: "Suficientes", bajas: "Bajas", agotadas: "Agotadas" };

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const horaPA = (iso?: string | null) => iso ? new Date(iso).toLocaleTimeString("es-PA", { timeZone: "America/Panama", hour: "2-digit", minute: "2-digit", hour12: true }) : "";
const fechaLarga = (d: string) => new Date(d + "T12:00:00Z").toLocaleDateString("es-PA", { timeZone: "UTC", weekday: "long", day: "numeric", month: "long", year: "numeric" });
const fechaCorta = (d: string) => new Date(d + "T12:00:00Z").toLocaleDateString("es-PA", { timeZone: "UTC", day: "2-digit", month: "short" }).replace(".", "");
const archivo = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^A-Za-z0-9]+/g, "_").replace(/^_|_$/g, "");

async function config(clave: string) {
  const { data } = await admin.from("config_sistema").select("valor").eq("clave", clave).maybeSingle();
  return data?.valor ?? null;
}
async function nombrePerfil(id?: string | null) {
  if (!id) return "";
  const { data } = await admin.from("perfiles").select("nombre").eq("id", id).maybeSingle();
  return data?.nombre ?? "";
}

type Fila = { area: string; codigo: string; actividad: string; respuesta: string; valor: string; nota: string; hora: string };
type Datos = {
  modulo: string; moduloNombre: string; fecha: string; turno: string; colaborador: string; firmado: string;
  validado: string; filas: Fila[]; extra: Array<[string, string]>; observaciones: string; pendientes: string;
  hojas: Array<{ nombre: string; filas: Record<string, unknown>[] }>;
};

// Une respuestas con el catálogo (área y texto) en el orden del checklist
async function filasChecklist(tAreas: string, tItems: string, tResp: string, reporteId: string): Promise<Fila[]> {
  const [a, i, r] = await Promise.all([
    admin.from(tAreas).select("codigo, nombre, orden"),
    admin.from(tItems).select("id, area, texto, orden"),
    admin.from(tResp).select("item_id, valor, nota, respondido_en").eq("reporte_id", reporteId),
  ]);
  const areas = new Map((a.data ?? []).map((x: any) => [x.codigo, x]));
  const items = new Map((i.data ?? []).map((x: any) => [x.id, x]));
  return (r.data ?? []).map((x: any) => {
    const it: any = items.get(x.item_id) ?? { area: "", texto: x.item_id, orden: 999 };
    const ar: any = areas.get(it.area) ?? { codigo: it.area, nombre: "", orden: 999 };
    return { _o: [ar.orden ?? 999, it.orden ?? 999], area: `${ar.codigo} · ${ar.nombre}`.replace(/ · $/, ""), codigo: x.item_id, actividad: it.texto, respuesta: VAL[x.valor] ?? x.valor, valor: x.valor, nota: x.nota ?? "", hora: horaPA(x.respondido_en) } as any;
  }).sort((p: any, q: any) => p._o[0] - q._o[0] || p._o[1] - q._o[1]).map(({ _o, ...f }: any) => f);
}

async function cargar(modulo: string, id: string): Promise<Datos> {
  if (modulo === "marshals") {
    const { data: r, error } = await admin.from("reportes_turno").select("*").eq("id", id).single(); if (error) throw error;
    const [filas, v, inc, col] = await Promise.all([
      filasChecklist("areas_checklist", "items_checklist", "respuestas_checklist", id),
      admin.from("validaciones").select("*").eq("reporte_id", id).maybeSingle(),
      admin.from("incidencias").select("*").eq("reporte_id", id).order("creado_en"),
      nombrePerfil(r.marshal_id),
    ]);
    return {
      modulo, moduloNombre: "Marshals", fecha: r.fecha, turno: TURNO[r.turno] ?? r.turno, colaborador: col, firmado: horaPA(r.firmado_en),
      validado: v.data ? `${await nombrePerfil(v.data.validado_por)} · ${horaPA(v.data.validado_en)}` : "Pendiente", filas,
      extra: [["Hoyos asignados", (r.hoyos ?? []).join(", ")], ["Vehículo", r.vehiculo ?? ""], ["Radio", r.radio ?? ""], ["Incidencias registradas", String((inc.data ?? []).length)]],
      observaciones: r.observaciones ?? "", pendientes: r.pendientes ?? "",
      hojas: [{ nombre: "Incidencias", filas: (inc.data ?? []).map((x: any) => ({
        Fecha: x.fecha, Hora: horaPA(x.creado_en), Prioridad: PRIO[x.prioridad] ?? x.prioridad, Categoría: CATS[x.categoria] ?? x.categoria,
        Ubicación: x.hoyo ? `Hoyo ${x.hoyo}` : x.ubicacion, Descripción: x.descripcion, "Acción correctiva": x.accion ?? "", Estado: x.estado,
      })) }],
    };
  }
  if (modulo === "starter") {
    const { data: r, error } = await admin.from("st_reportes").select("*").eq("id", id).single(); if (error) throw error;
    const [filas, v, col, cap] = await Promise.all([
      filasChecklist("st_areas", "st_items", "st_respuestas", id),
      admin.from("st_validaciones").select("*").eq("reporte_id", id).maybeSingle(),
      nombrePerfil(r.starter_id), nombrePerfil(r.capitan_id),
    ]);
    return {
      modulo, moduloNombre: "Starter", fecha: r.fecha, turno: TURNO[r.turno] ?? r.turno, colaborador: col, firmado: horaPA(r.firmado_en),
      validado: v.data ? `${await nombrePerfil(v.data.validado_por)} · ${horaPA(v.data.validado_en)}` : "Pendiente", filas,
      extra: [["Tee asignado", r.tee ? `Tee ${r.tee}` : ""], ["Capitán de turno", cap]],
      observaciones: r.observaciones ?? "", pendientes: r.pendientes ?? "", hojas: [],
    };
  }
  if (modulo === "capitanes") {
    const { data: r, error } = await admin.from("cap_reportes").select("*").eq("id", id).single(); if (error) throw error;
    const [filas, v, col] = await Promise.all([
      filasChecklist("cap_areas", "cap_items", "cap_respuestas", id),
      admin.from("cap_validaciones").select("*").eq("reporte_id", id).maybeSingle(),
      nombrePerfil(r.capitan_id),
    ]);
    const c = r.condiciones ?? {}, inv = r.inventario ?? {}, eq = r.equipo ?? {};
    return {
      modulo, moduloNombre: "Capitanes", fecha: r.fecha, turno: TURNO[r.turno] ?? r.turno, colaborador: col, firmado: horaPA(r.firmado_en),
      validado: v.data ? `${await nombrePerfil(v.data.validado_por)} · ${horaPA(v.data.validado_en)}` : "Pendiente", filas,
      extra: [["Velocidad de greens", c.velocidad_greens ?? ""], ["Posición de bandera", BANDERA[c.bandera] ?? c.bandera ?? ""], ["Regla de carritos", CARRITOS[c.regla_carritos] ?? c.regla_carritos ?? ""], ["Apertura del campo", c.apertura ?? ""], ["Obras o accidentes", c.obras ?? ""]],
      observaciones: r.observaciones ?? "", pendientes: r.pendientes ?? "",
      hojas: [
        { nombre: "Equipo del turno", filas: Object.entries(eq).map(([k, e]: any) => ({ Puesto: k, Estado: EST_PUESTO[e?.estado] ?? e?.estado ?? "", Nombre: e?.nombre ?? "" })) },
        { nombre: "Insumos", filas: Object.entries(inv).map(([k, e]: any) => ({ Insumo: INSUMOS[k] ?? k, Nivel: NIVEL[e?.nivel] ?? e?.nivel ?? "", Nota: e?.nota ?? "" })) },
      ],
    };
  }
  // Staff y Mecánico (op_reportes)
  const { data: r, error } = await admin.from("op_reportes").select("*").eq("id", id).single(); if (error) throw error;
  const [filas, v, per, dan] = await Promise.all([
    filasChecklist("op_areas", "op_items", "op_respuestas", id),
    admin.from("op_validaciones").select("*").eq("reporte_id", id).maybeSingle(),
    admin.from("hor_personal").select("nombre").eq("id", r.personal_id).maybeSingle(),
    admin.from("op_danos").select("*").eq("fecha", r.fecha).or(`personal_id.eq.${r.personal_id},reportado_por.eq.${r.autor_id ?? r.personal_id}`).order("creado_en"),
  ]);
  const d = r.datos ?? {}, extra: Array<[string, string]> = [["Posición", POS[r.posicion] ?? r.posicion]];
  if (r.posicion === "L") extra.push(["Carritos listos", String(d.carritos_listos ?? "")], ["Carritos fuera de servicio", String(d.carritos_fuera ?? "")]);
  if (r.posicion === "R") extra.push(["Nivel de bolas", NIVEL_BOLAS[d.nivel_bolas] ?? d.nivel_bolas ?? ""]);
  if (r.posicion === "M") {
    const o = +d.flota_operativos, f = +d.flota_fuera, disp = o + f > 0 ? Math.round(100 * o / (o + f)) : null;
    extra.push(["Carritos operativos", String(d.flota_operativos ?? "")], ["Fuera de servicio", String(d.flota_fuera ?? "")], ["Disponibilidad de flota", disp == null ? "" : `${disp} % (meta 95 %)`]);
  }
  extra.push(["Daños a carritos reportados", String((dan.data ?? []).length)]);
  return {
    modulo, moduloNombre: r.posicion === "M" ? "Mecánico" : `Staff · ${POS[r.posicion] ?? r.posicion}`, fecha: r.fecha, turno: POS[r.posicion] ?? r.posicion,
    colaborador: per.data?.nombre ?? await nombrePerfil(r.autor_id), firmado: horaPA(r.firmado_en),
    validado: v.data ? `${await nombrePerfil(v.data.validado_por)} · ${horaPA(v.data.validado_en)}` : "Pendiente", filas, extra,
    observaciones: r.observaciones ?? "", pendientes: r.entrega ?? "",
    hojas: [{ nombre: "Daños a carritos", filas: (dan.data ?? []).map((x: any) => ({ Fecha: x.fecha, Hora: horaPA(x.creado_en), Carrito: x.carrito, Descripción: x.descripcion, "Fuera de servicio": x.fuera_servicio ? "Sí" : "No", Estado: x.estado === "cerrado" ? "Atendido" : "Abierto", Acción: x.accion ?? "" })) }],
  };
}

function resumen(d: Datos) {
  const si = d.filas.filter((f) => f.valor === "si").length, no = d.filas.filter((f) => f.valor === "no").length;
  const na = d.filas.filter((f) => f.valor === "na").length, naJ = d.filas.filter((f) => f.valor === "na" && f.nota.trim()).length;
  const total = d.filas.length, cumpl = total ? Math.round(100 * (si + naJ) / total) : 0;
  return { si, no, na, total, cumpl };
}

function excel(d: Datos) {
  const s = resumen(d), wb = XLSX.utils.book_new();
  const res = [
    ["Santa María Golf Club · Reporte de checklist"], [],
    ["Módulo", d.moduloNombre], ["Fecha", d.fecha], [d.modulo === "staff" ? "Posición" : "Turno", d.turno], ["Colaborador", d.colaborador],
    ["Firmado", d.firmado], ["Validación", d.validado], [],
    ["Actividades", s.total], ["Sí", s.si], ["No", s.no], ["N/A", s.na], ["Cumplimiento", s.cumpl / 100], [],
    ...d.extra, [], ["Observaciones", d.observaciones], [d.modulo === "staff" ? "Entrega de pendientes" : "Pendientes para el siguiente turno", d.pendientes],
  ];
  const ws = XLSX.utils.aoa_to_sheet(res);
  ws["!cols"] = [{ wch: 30 }, { wch: 60 }];
  const iC = res.findIndex((x) => x[0] === "Cumplimiento"); if (iC >= 0) ws[XLSX.utils.encode_cell({ r: iC, c: 1 })].z = "0%";
  XLSX.utils.book_append_sheet(wb, ws, "Resumen");

  // Hoja "Registro": mismas columnas en todos los módulos → se pueden juntar para tablas dinámicas y gráficos
  const reg = d.filas.map((f) => ({
    Fecha: d.fecha, Módulo: d.moduloNombre, "Turno o posición": d.turno, Colaborador: d.colaborador, Área: f.area, Código: f.codigo,
    Actividad: f.actividad, Respuesta: f.respuesta, Cumple: f.valor === "si" || (f.valor === "na" && !!f.nota.trim()) ? 1 : 0, Observación: f.nota, "Hora de respuesta": f.hora,
  }));
  const wr = XLSX.utils.json_to_sheet(reg);
  wr["!cols"] = [{ wch: 11 }, { wch: 18 }, { wch: 16 }, { wch: 22 }, { wch: 28 }, { wch: 8 }, { wch: 60 }, { wch: 10 }, { wch: 8 }, { wch: 40 }, { wch: 12 }];
  wr["!autofilter"] = { ref: wr["!ref"]! };
  XLSX.utils.book_append_sheet(wb, wr, "Registro");

  for (const h of d.hojas) {
    const w = h.filas.length ? XLSX.utils.json_to_sheet(h.filas) : XLSX.utils.aoa_to_sheet([["Sin registros en este turno."]]);
    w["!cols"] = Array.from({ length: 8 }, () => ({ wch: 22 }));
    XLSX.utils.book_append_sheet(wb, w, h.nombre.slice(0, 31));
  }
  return XLSX.write(wb, { type: "base64", bookType: "xlsx" }) as string;
}

function correoHTML(d: Datos) {
  const s = resumen(d), malos = d.filas.filter((f) => f.valor !== "si");
  const color = s.cumpl >= 90 ? "#1f7a4d" : s.cumpl >= 75 ? "#a8640a" : "#b42318";
  const fila = (k: string, v: string) => v ? `<tr><td style="padding:6px 0;color:#5b6a61;font-size:13px;width:42%">${esc(k)}</td><td style="padding:6px 0;font-size:14px">${esc(v)}</td></tr>` : "";
  return `<!doctype html><html lang="es"><body style="margin:0;background:#f3f5f3;font-family:Arial,Helvetica,sans-serif;color:#17221c">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f3;padding:24px 12px"><tr><td align="center">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:12px;overflow:hidden;border:1px solid #dbe3dd">
    <tr><td style="background:#123d2a;padding:18px 24px"><table role="presentation" cellpadding="0" cellspacing="0"><tr>
      <td style="background:#ffffff;border-radius:8px;padding:6px 8px"><img src="${LOGO}" alt="Santa Maria Golf Club" height="48" style="display:block;height:48px"></td>
      <td style="padding-left:14px;color:#ffffff;font-size:13px;letter-spacing:2px;text-transform:uppercase">Checklist firmado · ${esc(d.moduloNombre)}</td></tr></table></td></tr>
    <tr><td style="padding:24px">
      <h1 style="margin:0 0 4px;font-family:Georgia,serif;font-weight:normal;font-size:24px;color:#123d2a">${esc(d.colaborador || "Colaborador")}</h1>
      <p style="margin:0 0 16px;color:#5b6a61;font-size:14px">${esc(fechaLarga(d.fecha))} · ${esc(d.turno)} · firmado ${esc(d.firmado)}</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px"><tr>
        <td style="padding:12px;border:1px solid #dbe3dd;border-radius:8px" align="center"><div style="font-size:28px;font-family:Georgia,serif;color:${color}">${s.cumpl}%</div><div style="font-size:12px;color:#5b6a61">Cumplimiento</div></td>
        <td width="8"></td><td style="padding:12px;border:1px solid #dbe3dd;border-radius:8px" align="center"><div style="font-size:28px;font-family:Georgia,serif;color:#1f7a4d">${s.si}</div><div style="font-size:12px;color:#5b6a61">Sí</div></td>
        <td width="8"></td><td style="padding:12px;border:1px solid #dbe3dd;border-radius:8px" align="center"><div style="font-size:28px;font-family:Georgia,serif;color:#b42318">${s.no}</div><div style="font-size:12px;color:#5b6a61">No</div></td>
        <td width="8"></td><td style="padding:12px;border:1px solid #dbe3dd;border-radius:8px" align="center"><div style="font-size:28px;font-family:Georgia,serif;color:#5b6a61">${s.na}</div><div style="font-size:12px;color:#5b6a61">N/A</div></td>
      </tr></table>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #eef2ef;margin-bottom:12px">${d.extra.map(([k, v]) => fila(k, v)).join("")}${fila("Validación", d.validado)}</table>
      ${malos.length ? `<h2 style="font-size:15px;margin:16px 0 8px;color:#123d2a">Actividades con No o N/A</h2>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px">${malos.map((f) => `<tr>
          <td style="padding:8px;border-bottom:1px solid #eef2ef;vertical-align:top;width:52px"><b style="color:${f.valor === "no" ? "#b42318" : "#5b6a61"}">${esc(f.respuesta)}</b></td>
          <td style="padding:8px;border-bottom:1px solid #eef2ef">${esc(f.actividad)}${f.nota ? `<br><span style="color:#5b6a61">${esc(f.nota)}</span>` : ""}</td></tr>`).join("")}</table>`
        : `<p style="margin:12px 0;font-size:14px;color:#1f7a4d"><b>Todas las actividades se cumplieron.</b></p>`}
      ${d.observaciones ? `<p style="margin:16px 0 6px;font-size:14px"><b>Observaciones:</b> ${esc(d.observaciones)}</p>` : ""}
      ${d.pendientes ? `<p style="margin:6px 0;font-size:14px"><b>${d.modulo === "staff" ? "Entrega de pendientes" : "Pendientes para el siguiente turno"}:</b> ${esc(d.pendientes)}</p>` : ""}
      <p style="margin:18px 0 0;font-size:13px;color:#5b6a61">El Excel adjunto trae el detalle completo. La hoja <b>Registro</b> tiene las mismas columnas en todos los módulos: puede juntar varios días para hacer gráficos y tablas dinámicas.</p>
      <p style="margin:16px 0 0"><a href="${APP}" style="display:inline-block;background:#123d2a;color:#ffffff;text-decoration:none;padding:10px 18px;border-radius:8px;font-size:14px">Abrir la app SMGC</a></p>
    </td></tr>
    <tr><td style="padding:16px 24px;border-top:3px solid #a8873a;font-size:12px;color:#5b6a61">Santa María Golf Club · Control operativo<br>Correo automático: se envía cada vez que un colaborador firma su checklist diario.</td></tr>
  </table></td></tr></table></body></html>`;
}

async function enviar(c: any, apiKey: string, remitente: string, destino: string) {
  try {
    const d = await cargar(c.modulo, c.reporte_id), s = resumen(d);
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: remitente, to: [destino],
        subject: `Checklist ${d.moduloNombre} · ${d.colaborador || "Colaborador"} · ${fechaCorta(d.fecha)} ${d.turno} · ${s.cumpl}%`,
        html: correoHTML(d),
        attachments: [{ filename: `SMGC_${archivo(d.moduloNombre)}_${d.fecha}_${archivo(d.colaborador || "colaborador")}.xlsx`, content: excel(d) }],
      }),
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body?.message ?? `HTTP ${r.status}`);
    await admin.from("correos_reportes").update({ estado: "enviado", enviado_en: new Date().toISOString(), proveedor_id: body.id ?? null, error: null, destinatario: destino, intentos: c.intentos + 1 }).eq("id", c.id);
    return { id: c.id, estado: "enviado" };
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 300);
    await admin.from("correos_reportes").update({ estado: "error", error: msg, destinatario: destino, intentos: c.intentos + 1 }).eq("id", c.id);
    return { id: c.id, estado: "error", error: msg };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  // Llamada interna de la base de datos al firmar (cabecera secreta) o de un usuario activo de la app
  const secreto = req.headers.get("x-reportes-secreto");
  let p: { rol: string; activo: boolean } | null = null;
  if (secreto) {
    if (secreto !== await config("reportes_secreto")) return json({ error: "No autorizado." }, 401);
    p = { rol: "sistema", activo: true };
  } else {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(token);
    if (!u?.user) return json({ error: "Inicie sesión." }, 401);
    const { data } = await admin.from("perfiles").select("rol, activo").eq("id", u.user.id).maybeSingle();
    p = data;
  }
  if (!p?.activo) return json({ error: "Cuenta inactiva." }, 403);

  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* vacío */ }
  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return json({ configurado: false, mensaje: "El envío de correos aún no está configurado. Los reportes quedan en cola." });
  const remitente = ((await config("correo_remitente")) ?? "Santa María Golf Club <palos@smcapibara.com>").replace(/<[^>]+>/, "<reportes@smcapibara.com>");
  const destino = (await config("correo_reportes")) ?? (await config("correo_gerente_inicial"));
  if (!destino) return json({ error: "Falta el correo de destino de los reportes." }, 500);

  if (body.accion === "reenviar") {
    if (!CAPITANIA.includes(p.rol)) return json({ error: "Solo Capitanes o Gerencia." }, 403);
    const { data: c } = await admin.from("correos_reportes").select("*").eq("id", body.id).maybeSingle();
    if (!c) return json({ error: "No existe ese reporte." }, 404);
    return json({ configurado: true, destino, resultados: [await enviar(c, apiKey, remitente, destino)] });
  }
  let q = admin.from("correos_reportes").select("*").in("estado", ["pendiente", "error"]).lt("intentos", 5).order("creado_en").limit(10);
  if (body.reporte_id) q = q.eq("reporte_id", body.reporte_id);
  const { data: lista, error } = await q;
  if (error) return json({ error: error.message }, 500);
  const resultados = [];
  for (const c of lista ?? []) resultados.push(await enviar(c, apiKey, remitente, destino));
  return json({ configurado: true, destino, resultados });
});
