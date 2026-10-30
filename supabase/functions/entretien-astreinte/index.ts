// Nettoyage de nuit : photos des incidents d'astreinte supprimées 1 an après la clôture.
// Appelée uniquement par la tâche planifiée de la base (clé interne vérifiée).
import { createClient } from "jsr:@supabase/supabase-js@2";

const rep = (corps: unknown, statut = 200) => new Response(JSON.stringify(corps), { status: statut, headers: { "Content-Type": "application/json" } });
const DELAI_JOURS = 365;

Deno.serve(async (req) => {
  if (req.method !== "POST") return rep({ erreur: "Méthode non autorisée" }, 405);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const cle = await db.from("cles_serveur").select("valeur").eq("cle", "entretien").maybeSingle();
  const attendu = cle.data?.valeur?.v;
  if (!attendu || req.headers.get("x-cle-entretien") !== attendu) return rep({ erreur: "Non autorisé" }, 401);

  const limite = new Date(Date.now() - DELAI_JOURS * 86400000).toISOString();
  const { data: lignes, error } = await db.from("astreinte_incidents").select("uuid, donnees")
    .in("statut", ["RESOLU", "ARCHIVE"]).lt("clos_le", limite).limit(200);
  if (error) return rep({ erreur: error.message }, 500);

  let incidents = 0, fichiers = 0;
  for (const l of lignes || []) {
    const d = l.donnees || {};
    const chemins: string[] = (Array.isArray(d.photos) ? d.photos : []).map((p: any) => p?.chemin).filter((c: unknown) => typeof c === "string");
    if (!chemins.length) continue;
    const rm = await db.storage.from("astreinte").remove(chemins);
    if (rm.error) continue;                                   // on réessaiera la nuit suivante
    const deja: string[] = Array.isArray(d.photosSupprimees) ? d.photosSupprimees : [];
    const ts = new Date().toISOString();
    const donnees = {
      ...d,
      photos: (d.photos || []).filter((p: any) => !chemins.includes(p?.chemin)),
      photosSupprimees: [...new Set([...deja, ...chemins])],
      updatedAt: ts,
      history: [...(Array.isArray(d.history) ? d.history : []), { ts, text: `📷 Photos supprimées (${chemins.length}), 1 an après la clôture` }],
    };
    const up = await db.from("astreinte_incidents").update({ donnees, maj_le: ts }).eq("uuid", l.uuid);
    if (!up.error) { incidents++; fichiers += chemins.length; }
  }
  return rep({ ok: true, incidents, fichiers });
});
