// Notifications de nouveaux incidents d'astreinte.
// Actions : cle (clé publique), abonner / desabonner (ce téléphone), tester (ce téléphone), alerter (nouvel incident).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { creerClesVapid, envoyer, type ClesVapid } from "./webpush.ts";

const CONTACT = "mailto:mairie@pasly.fr";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const rep = (corps: unknown, statut = 200) =>
  new Response(JSON.stringify(corps), { status: statut, headers: { ...CORS, "Content-Type": "application/json" } });

const URGENCES: Record<string, string> = { IMMEDIATE: "🔴 URGENCE", URGENT: "🟠 Urgent", A_TRAITER: "🟡 À traiter", INFO: "🔵 Information" };
const txt = (v: unknown, max: number) => String(v ?? "").replace(/\s+/g, " ").trim().slice(0, max);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return rep({ erreur: "Méthode non autorisée" }, 405);
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });

    // Appelant : compte actif uniquement
    const jeton = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(jeton);
    if (!u?.user) return rep({ erreur: "Connexion requise" }, 401);
    const { data: moi } = await db.from("profils").select("role, actif, nom").eq("id", u.user.id).maybeSingle();
    if (!moi || moi.actif === false) return rep({ erreur: "Compte désactivé" }, 403);
    const gestion = ["admin", "contributeur"].includes(moi.role);

    // Clés de signature : créées une fois, conservées côté serveur
    async function cles(): Promise<ClesVapid> {
      const r = await db.from("cles_serveur").select("valeur").eq("cle", "vapid").maybeSingle();
      if (r.error) throw new Error(/does not exist|schema cache|42P01|PGRST205/.test(r.error.message) ? "Base pas prête : exécutez migration-alertes.sql dans Supabase" : r.error.message);
      if (r.data) return r.data.valeur as ClesVapid;
      const n = await creerClesVapid();
      await db.from("cles_serveur").insert({ cle: "vapid", valeur: n });
      const relu = await db.from("cles_serveur").select("valeur").eq("cle", "vapid").single();   // en cas de création simultanée
      return relu.data!.valeur as ClesVapid;
    }

    const b = await req.json().catch(() => ({}));
    const endpointOk = (e: unknown) => typeof e === "string" && /^https:\/\/[a-z0-9.-]+\//i.test(e) && e.length < 1000;

    if (b.action === "cle") return rep({ ok: true, cle: (await cles()).publique });

    if (b.action === "abonner") {
      if (!gestion) return rep({ erreur: "Les alertes sont réservées aux téléphones de l'astreinte et des élus" }, 403);
      const a = b.abonnement || {};
      if (!endpointOk(a.endpoint) || typeof a.keys?.p256dh !== "string" || typeof a.keys?.auth !== "string") return rep({ erreur: "Abonnement invalide" }, 400);
      const { error } = await db.from("astreinte_abonnements").upsert({
        endpoint: a.endpoint, p256dh: a.keys.p256dh.slice(0, 200), auth: a.keys.auth.slice(0, 100),
        compte: u.user.id, appareil: txt(b.appareil, 80) || null, vu_le: new Date().toISOString(),
      }, { onConflict: "endpoint" });
      if (error) throw error;
      return rep({ ok: true });
    }

    if (b.action === "desabonner") {
      if (endpointOk(b.endpoint)) await db.from("astreinte_abonnements").delete().eq("endpoint", b.endpoint);
      return rep({ ok: true });
    }

    if (b.action === "tester") {
      const { data: ab } = await db.from("astreinte_abonnements").select("endpoint, p256dh, auth").eq("endpoint", b.endpoint).maybeSingle();
      if (!ab) return rep({ erreur: "Ce téléphone n'est pas abonné" }, 404);
      const code = await envoyer(ab, { title: "✅ Alertes activées", body: "Ce téléphone recevra les nouveaux incidents d'astreinte.", url: "./", tag: "test" }, await cles(), CONTACT, false);
      if (code === 404 || code === 410) await db.from("astreinte_abonnements").delete().eq("endpoint", ab.endpoint);
      return rep({ ok: code < 300, code });
    }

    if (b.action === "alerter") {
      const uuid = String(b.uuid || "");
      if (!/^[0-9a-f-]{36}$/i.test(uuid)) return rep({ erreur: "Incident inconnu" }, 400);
      const { data: inc } = await db.from("astreinte_incidents").select("uuid, numero, urgence, categorie, adresse, donnees, cree_par, cree_le").eq("uuid", uuid).maybeSingle();
      if (!inc) return rep({ erreur: "Incident inconnu" }, 404);
      if (inc.cree_par !== u.user.id) return rep({ erreur: "Seul l'auteur de l'incident peut déclencher l'alerte" }, 403);
      if (Date.now() - new Date(inc.cree_le).getTime() > 48 * 3600 * 1000) return rep({ ok: true, ignore: "incident ancien" });
      // Une seule alerte par incident
      const prise = await db.from("astreinte_alertes_envoyees").insert({ incident: uuid }).select("incident");
      if (prise.error) {
        if (prise.error.code === "23505") return rep({ ok: true, deja: true });
        throw prise.error;
      }
      // Libellé de la catégorie d'après les réglages communs
      let categorie = inc.categorie || "Incident";
      const cfg = await db.from("parametres").select("valeur").eq("cle", "astreinte_config").maybeSingle();
      const liste = cfg.data?.valeur?.categories?.v;
      if (Array.isArray(liste)) { const c = liste.find((x: any) => x?.id === inc.categorie); if (c?.label) categorie = `${c.emoji ? c.emoji + " " : ""}${c.label}`; }
      const d = inc.donnees || {};
      const lieu = txt(inc.adresse, 90) || "position GPS enregistrée";
      const auteur = txt(d.createdBy || moi.nom, 60);
      const message = {
        title: `${URGENCES[inc.urgence] || "Nouvel incident"} · ${txt(categorie, 50)}`,
        body: `${lieu}${auteur ? ` — signalé par ${auteur}` : ""}${d.description ? `\n${txt(d.description, 140)}` : ""}`,
        url: `./#fiche?uuid=${uuid}`,
        tag: `incident-${uuid}`,
        urgent: ["IMMEDIATE", "URGENT"].includes(inc.urgence),
      };
      const { data: abs } = await db.from("astreinte_abonnements").select("endpoint, p256dh, auth");
      const cibles = (abs || []).filter((a) => a.endpoint !== b.endpoint);       // pas le téléphone qui vient de saisir
      const k = await cles();
      let envoyes = 0;
      await Promise.all(cibles.map(async (a) => {
        try {
          const code = await envoyer(a, message, k, CONTACT, true);
          if (code === 404 || code === 410) await db.from("astreinte_abonnements").delete().eq("endpoint", a.endpoint);
          else if (code < 300) envoyes++;
        } catch { /* un téléphone injoignable ne bloque pas les autres */ }
      }));
      await db.from("astreinte_alertes_envoyees").update({ destinataires: envoyes }).eq("incident", uuid);
      return rep({ ok: true, envoyes });
    }

    return rep({ erreur: "Action inconnue" }, 400);
  } catch (e) {
    return rep({ erreur: e instanceof Error ? e.message : String(e) }, 500);
  }
});
