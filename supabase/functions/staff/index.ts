// Gestión de cuentas del staff · Santa María Golf Club · Marshals
// Acciones: estado · primer_gerente · crear · restablecer
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  return keys["default"] ?? Object.values(keys)[0] as string;
}
const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), {
  auth: { persistSession: false, autoRefreshToken: false },
});

const GERENCIA = ["gerente_operaciones", "gerente_golf", "admin"];
const ROLES_CREABLES = ["colaborador", "marshal", "starter", "capitan", "gerente_operaciones", "gerente_golf"];
const USUARIO_RE = /^[a-z0-9][a-z0-9._-]{2,29}$/;

async function config(clave: string) {
  const { data } = await admin.from("config_sistema").select("valor").eq("clave", clave).maybeSingle();
  return data?.valor ?? null;
}
async function hayGerente() {
  const { count } = await admin.from("perfiles").select("id", { count: "exact", head: true })
    .in("rol", GERENCIA).eq("activo", true);
  return (count ?? 0) > 0;
}
async function quienLlama(req: Request) {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data } = await admin.auth.getUser(token);
  if (!data?.user) return null;
  const { data: p } = await admin.from("perfiles").select("id, rol, activo").eq("id", data.user.id).maybeSingle();
  return p && p.activo ? p : null;
}
function errorAuth(msg: string) {
  if (/already been registered|already exists|duplicate/i.test(msg)) return "Ese usuario ya existe.";
  if (/password/i.test(msg)) return "La contraseña no cumple los requisitos (mínimo 8 caracteres).";
  if (/email/i.test(msg)) return "El usuario o correo no es válido.";
  return msg;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* cuerpo vacío */ }
  const accion = body.accion;

  try {
    if (accion === "estado") {
      return json({ dominio: await config("dominio_usuarios"), hayGerente: await hayGerente() });
    }

    if (accion === "primer_gerente") {
      if (await hayGerente()) return json({ error: "Ya existe una cuenta de Gerencia. Pida a Gerencia que cree su usuario." }, 409);
      const correo = String(body.correo ?? "").trim().toLowerCase();
      const esperado = (await config("correo_gerente_inicial") ?? "").toLowerCase();
      if (!correo || correo !== esperado) return json({ error: "Ese correo no está autorizado para la configuración inicial." }, 403);
      const password = String(body.password ?? "");
      if (password.length < 8) return json({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
      const nombre = String(body.nombre ?? "").trim() || "Gerencia";
      const { data, error } = await admin.auth.admin.createUser({
        email: correo, password, email_confirm: true,
        user_metadata: { nombre }, app_metadata: { alta_gerencia: true, usuario: null },
      });
      if (error) return json({ error: errorAuth(error.message) }, 400);
      await admin.from("perfiles").update({ rol: "gerente_operaciones", activo: true }).eq("id", data.user!.id);
      return json({ ok: true });
    }

    const yo = await quienLlama(req);
    if (!yo || !GERENCIA.includes(yo.rol)) return json({ error: "Solo Gerencia puede gestionar cuentas." }, 403);

    if (accion === "crear") {
      const nombre = String(body.nombre ?? "").trim();
      const usuario = String(body.usuario ?? "").trim().toLowerCase();
      const password = String(body.password ?? "");
      const rol = ROLES_CREABLES.includes(body.rol) ? body.rol : "marshal";
      if (!nombre) return json({ error: "Escriba el nombre completo." }, 400);
      if (!USUARIO_RE.test(usuario)) return json({ error: "El usuario debe tener 3 a 30 letras minúsculas, números, punto o guion, sin espacios." }, 400);
      if (password.length < 8) return json({ error: "La contraseña temporal debe tener al menos 8 caracteres." }, 400);
      const dominio = await config("dominio_usuarios");
      const { data, error } = await admin.auth.admin.createUser({
        email: `${usuario}@${dominio}`, password, email_confirm: true,
        user_metadata: { nombre }, app_metadata: { alta_gerencia: true, usuario },
      });
      if (error) return json({ error: errorAuth(error.message) }, 400);
      await admin.from("perfiles").update({ rol, activo: true, usuario, nombre }).eq("id", data.user!.id);
      // Vincula la cuenta con su nombre en el horario (el elegido en el formulario o, si no, el que coincide por nombre)
      let pid = String(body.personal_id ?? "") || null;
      if (!pid) {
        const norm = (t: string) => t.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
        const { data: lista } = await admin.from("hor_personal").select("id, nombre").is("perfil_id", null).eq("activo", true);
        pid = (lista ?? []).find((x) => norm(x.nombre) === norm(nombre))?.id ?? null;
      }
      let vinculado = false;
      if (pid) {
        const { error: ev } = await admin.from("hor_personal").update({ perfil_id: data.user!.id }).eq("id", pid).is("perfil_id", null);
        vinculado = !ev;
      }
      return json({ ok: true, id: data.user!.id, vinculado });
    }

    if (accion === "restablecer") {
      const id = String(body.id ?? "");
      const password = String(body.password ?? "");
      if (password.length < 8) return json({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
      const { error } = await admin.auth.admin.updateUserById(id, { password });
      if (error) return json({ error: errorAuth(error.message) }, 400);
      return json({ ok: true });
    }

    return json({ error: "Acción desconocida" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: "Error interno. Intente de nuevo." }, 500);
  }
});
