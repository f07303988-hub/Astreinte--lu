// Envoi de notifications Web Push (RFC 8291 « aes128gcm » + RFC 8292 « VAPID »), avec la seule Web Crypto.
const enc = new TextEncoder();

export const b64u = {
  encode(b: Uint8Array): string {
    let s = ""; for (const x of b) s += String.fromCharCode(x);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
  decode(s: string): Uint8Array {
    const t = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
    return Uint8Array.from(atob(t), (c) => c.charCodeAt(0));
  },
};
const concat = (...l: Uint8Array[]) => { const o = new Uint8Array(l.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of l) { o.set(x, i); i += x.length; } return o; };

async function hmac(cle: Uint8Array, donnees: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", cle, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, donnees));
}

export type ClesVapid = { publique: string; jwk: JsonWebKey };

/** Nouvelle paire de clés VAPID (P-256). */
export async function creerClesVapid(): Promise<ClesVapid> {
  const p = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", p.privateKey);
  const brute = new Uint8Array(await crypto.subtle.exportKey("raw", p.publicKey));
  return { publique: b64u.encode(brute), jwk };
}

/** En-tête Authorization VAPID pour un service de notification donné. */
async function enteteVapid(endpoint: string, cles: ClesVapid, contact: string): Promise<string> {
  const aud = new URL(endpoint).origin;
  const tete = b64u.encode(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const corps = b64u.encode(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: contact })));
  const k = await crypto.subtle.importKey("jwk", cles.jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k, enc.encode(`${tete}.${corps}`)));
  return `vapid t=${tete}.${corps}.${b64u.encode(sig)}, k=${cles.publique}`;
}

/** Chiffrement du message pour un abonné (RFC 8291). */
export async function chiffrer(message: Uint8Array, p256dh: string, auth: string, sel?: Uint8Array, ephemere?: CryptoKeyPair): Promise<Uint8Array> {
  const uaPublic = b64u.decode(p256dh), secret = b64u.decode(auth);
  const as = ephemere ?? await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));
  const prkKey = await hmac(secret, ecdh);
  const ikm = await hmac(prkKey, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic, new Uint8Array([1])));
  const salt = sel ?? crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(enc.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(enc.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);
  const k = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const chiffre = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, k, concat(message, new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]);                       // taille d'enregistrement : 4096
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, chiffre);
}

export type Abonnement = { endpoint: string; p256dh: string; auth: string };

/** Envoie une notification ; renvoie le code HTTP du service (201 = accepté, 404/410 = abonnement expiré). */
export async function envoyer(ab: Abonnement, donnees: unknown, cles: ClesVapid, contact: string, urgent = true): Promise<number> {
  const corps = await chiffrer(enc.encode(JSON.stringify(donnees)), ab.p256dh, ab.auth);
  const r = await fetch(ab.endpoint, {
    method: "POST",
    headers: {
      Authorization: await enteteVapid(ab.endpoint, cles, contact),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: "86400",
      Urgency: urgent ? "high" : "normal",
    },
    body: corps,
  });
  await r.body?.cancel();
  return r.status;
}
