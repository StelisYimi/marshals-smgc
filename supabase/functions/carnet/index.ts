// Verificación pública del carnet (QR) · Santa María Golf Club
// Recibe el token del QR y responde si el carnet está vigente, con nombre, cargo y foto temporal.
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
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* vacío */ }
  const token = String(body.token ?? "").trim();
  if (!UUID.test(token)) return json({ valido: false });
  try {
    const { data: c } = await admin.from("carnets").select("perfil_id,codigo,cargo,desde,foto_path").eq("token", token).maybeSingle();
    if (!c) return json({ valido: false });
    const { data: p } = await admin.from("perfiles").select("nombre,activo").eq("id", c.perfil_id).maybeSingle();
    let foto: string | null = null;
    if (c.foto_path && p?.activo) {
      const s = await admin.storage.from("carnets").createSignedUrl(c.foto_path, 300);
      foto = s.data?.signedUrl ?? null;
    }
    return json({ valido: true, vigente: !!p?.activo, nombre: p?.nombre ?? "", cargo: c.cargo, codigo: c.codigo, desde: c.desde, foto });
  } catch (e) {
    console.error(e);
    return json({ error: "Error interno" }, 500);
  }
});
