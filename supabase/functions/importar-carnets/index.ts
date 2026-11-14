// Importación de fotos iniciales de carnets: ya se completó (14 nov 2026). Función desactivada.
Deno.serve(() => new Response(JSON.stringify({ error: "desactivada" }), { status: 410, headers: { "Content-Type": "application/json" } }));
