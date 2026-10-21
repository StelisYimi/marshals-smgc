// Correos del módulo Capitanes · Santa María Golf Club
// Envía la confirmación de entrega y de cierre de palos de alquiler (vía Resend, dominio smcapibara.com).
// Acción: { accion: "procesar", alquiler_id? }  → envía los correos pendientes (de un alquiler o todos).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

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
const TIPOS: Record<string, string> = { regular: "Regular", stiff: "Stiff", senior: "Senior", damas: "Damas", zurdos: "Zurdos" };
const ESTADO_PIEZA: Record<string, string> = { ok: "En buen estado", falta: "No devuelta", danado: "Con daño" };

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const fecha = (iso: string) => new Date(iso).toLocaleString("es-PA", { timeZone: "America/Panama", weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });

async function config(clave: string) {
  const { data } = await admin.from("config_sistema").select("valor").eq("clave", clave).maybeSingle();
  return data?.valor ?? null;
}

function plantilla(titulo: string, cuerpo: string) {
  return `<!doctype html><html lang="es"><body style="margin:0;background:#f3f5f3;font-family:Arial,Helvetica,sans-serif;color:#17221c">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f3;padding:24px 12px"><tr><td align="center">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;overflow:hidden;border:1px solid #dbe3dd">
    <tr><td style="background:#123d2a;padding:18px 24px" align="left"><table role="presentation" cellpadding="0" cellspacing="0"><tr>
      <td style="background:#ffffff;border-radius:8px;padding:6px 8px"><img src="${LOGO}" alt="Santa Maria Golf Club" height="52" style="display:block;height:52px"></td>
      <td style="padding-left:14px;color:#ffffff;font-size:13px;letter-spacing:2px;text-transform:uppercase">Palos de alquiler</td></tr></table></td></tr>
    <tr><td style="padding:24px">
      <h1 style="margin:0 0 12px;font-family:Georgia,serif;font-weight:normal;font-size:24px;color:#123d2a">${titulo}</h1>
      ${cuerpo}
    </td></tr>
    <tr><td style="padding:16px 24px;border-top:3px solid #a8873a;font-size:12px;color:#5b6a61">Santa María Golf Club · Ciudad de Panamá<br>Este correo se envió automáticamente desde el sistema de Capitanes.</td></tr>
  </table></td></tr></table></body></html>`;
}

function tablaPiezas(filas: Array<{ pieza: string; cantidad: number; estado?: string; nota?: string }>, conEstado: boolean) {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:14px;margin:12px 0">
    <tr><th align="left" style="padding:8px;border-bottom:2px solid #dbe3dd;color:#5b6a61;font-size:12px;text-transform:uppercase">Pieza</th>
    <th align="center" style="padding:8px;border-bottom:2px solid #dbe3dd;color:#5b6a61;font-size:12px;text-transform:uppercase">Cant.</th>
    ${conEstado ? `<th align="left" style="padding:8px;border-bottom:2px solid #dbe3dd;color:#5b6a61;font-size:12px;text-transform:uppercase">Estado</th>` : ""}</tr>
    ${filas.map((f) => `<tr><td style="padding:8px;border-bottom:1px solid #eef2ef">${esc(f.pieza)}</td><td align="center" style="padding:8px;border-bottom:1px solid #eef2ef">${esc(f.cantidad)}</td>
      ${conEstado ? `<td style="padding:8px;border-bottom:1px solid #eef2ef;color:${f.estado === "ok" ? "#1f7a4d" : "#b42318"}">${esc(ESTADO_PIEZA[f.estado ?? "ok"] ?? f.estado)}${f.nota ? ` · ${esc(f.nota)}` : ""}</td>` : ""}</tr>`).join("")}
  </table>`;
}

async function armar(correo: any) {
  const { data: a } = await admin.from("alquileres").select("*, juegos_alquiler(tipo, descripcion)").eq("id", correo.alquiler_id).single();
  const { data: caps } = await admin.from("perfiles").select("id, nombre").in("id", [a.capitan_salida, a.capitan_entrada].filter(Boolean));
  const capNom = (id: string) => caps?.find((c: any) => c.id === id)?.nombre ?? "nuestro equipo";
  const juego = `${a.juego_id} · ${TIPOS[a.juegos_alquiler?.tipo] ?? ""}${a.juegos_alquiler?.descripcion ? ` · ${a.juegos_alquiler.descripcion}` : ""}`;
  if (correo.tipo === "entrega") {
    return {
      asunto: `Confirmación de entrega de palos · Folio ${a.folio}`,
      html: plantilla("Recibió sus palos de alquiler", `
        <p style="margin:0 0 10px;font-size:15px">Hola ${esc(a.huesped_nombre)}:</p>
        <p style="margin:0 0 10px;font-size:15px">Confirmamos que recibió el juego <b>${esc(juego)}</b> el ${esc(fecha(a.salida_en))}, entregado por ${esc(capNom(a.capitan_salida))}. Usted revisó cada pieza y firmó la recepción.</p>
        ${tablaPiezas(a.check_salida, false)}
        <p style="margin:0 0 10px;font-size:15px">Al terminar su ronda, entregue los palos a cualquiera de nuestros Capitanes. Le enviaremos un segundo correo confirmando la devolución.</p>
        <p style="margin:16px 0 0;font-size:13px;color:#5b6a61">Folio ${a.folio}${a.referencia ? ` · ${esc(a.referencia)}` : ""}</p>`),
    };
  }
  const malas = (a.check_entrada ?? []).filter((p: any) => p.estado !== "ok");
  return {
    asunto: `Devolución de palos completada · Folio ${a.folio}`,
    html: plantilla(a.todo_ok ? "Gracias, todo está en orden" : "Devolución registrada", `
      <p style="margin:0 0 10px;font-size:15px">Hola ${esc(a.huesped_nombre)}:</p>
      <p style="margin:0 0 10px;font-size:15px">Recibimos el juego <b>${esc(juego)}</b> el ${esc(fecha(a.devuelto_en))}. ${a.todo_ok
        ? "Revisamos cada pieza y todo quedó en orden. El proceso de alquiler está cerrado."
        : `Revisamos cada pieza y encontramos ${malas.length === 1 ? "una observación" : malas.length + " observaciones"}. Nuestro equipo se comunicará con usted si hace falta algún paso adicional.`}</p>
      ${tablaPiezas(a.check_entrada ?? [], true)}
      ${a.observaciones_cierre ? `<p style="margin:0 0 10px;font-size:15px"><b>Observaciones:</b> ${esc(a.observaciones_cierre)}</p>` : ""}
      <p style="margin:0 0 10px;font-size:15px">Gracias por jugar en Santa María Golf Club. Esperamos verle pronto.</p>
      <p style="margin:16px 0 0;font-size:13px;color:#5b6a61">Folio ${a.folio} · Recibido por ${esc(capNom(a.capitan_entrada))}</p>`),
  };
}

async function enviar(correo: any, apiKey: string, remitente: string) {
  try {
    const { asunto, html } = await armar(correo);
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: remitente, to: [correo.destinatario], subject: asunto, html }),
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body?.message ?? `HTTP ${r.status}`);
    await admin.from("correos").update({ estado: "enviado", enviado_en: new Date().toISOString(), proveedor_id: body.id ?? null, error: null, intentos: correo.intentos + 1 }).eq("id", correo.id);
    return { id: correo.id, estado: "enviado" };
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 300);
    await admin.from("correos").update({ estado: "error", error: msg, intentos: correo.intentos + 1 }).eq("id", correo.id);
    return { id: correo.id, estado: "error", error: msg };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: u } = await admin.auth.getUser(token);
  if (!u?.user) return json({ error: "Inicie sesión." }, 401);
  const { data: p } = await admin.from("perfiles").select("rol, activo").eq("id", u.user.id).maybeSingle();
  if (!p?.activo || !CAPITANIA.includes(p.rol)) return json({ error: "Solo Capitanes o Gerencia." }, 403);

  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* vacío */ }
  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return json({ configurado: false, mensaje: "El envío de correos aún no está configurado. Los correos quedan en cola." });
  const remitente = (await config("correo_remitente")) ?? "Santa María Golf Club <palos@smcapibara.com>";

  let q = admin.from("correos").select("*").in("estado", ["pendiente", "error"]).lt("intentos", 5).order("creado_en").limit(20);
  if (body.alquiler_id) q = q.eq("alquiler_id", body.alquiler_id);
  const { data: lista, error } = await q;
  if (error) return json({ error: error.message }, 500);
  const resultados = [];
  for (const c of lista ?? []) resultados.push(await enviar(c, apiKey, remitente));
  return json({ configurado: true, resultados });
});
