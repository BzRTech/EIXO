vcl 4.1;

# ============================================================
# Varnish 7.5 — Tile Cache Agressivo para WebGIS
# Referência: Crunchy Data — TTL 60s "reduz CPU quase a zero"
# Estratégia: zoom 0-12 TTL longo, zoom 13+ TTL curto
# ============================================================

import std;

backend martin {
    .host = "martin";
    .port = "3000";
    .connect_timeout   = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
    .probe = {
        .url = "/health";
        .interval = 10s;
        .timeout = 5s;
        .threshold = 3;
    }
}

# ── ACL para purge (só do próprio servidor) ────────────────
acl purge_acl {
    "localhost";
    "127.0.0.1";
    "::1";
    "10.0.0.0"/8;
    "172.16.0.0"/12;
    "192.168.0.0"/16;
}

sub vcl_recv {

    # ── PURGE manual de tiles ──────────────────────────────
    if (req.method == "PURGE") {
        if (!client.ip ~ purge_acl) {
            return (synth(403, "Purge não autorizado"));
        }
        return (purge);
    }

    # ── Apenas GET/HEAD são cacheáveis ─────────────────────
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # ── Rotas de tiles (Martin: /{table}/{z}/{x}/{y}) ──────
    # Cache apenas URLs de tiles vector (MVT)
    if (req.url ~ "^/tiles/") {
        # Remove parâmetros de query desnecessários para cache
        set req.url = regsuball(req.url, "\?(token|_)=[^&]*&?", "?");
        set req.url = regsub(req.url, "\?$", "");

        # Remove cookies para que o cache seja efetivo
        unset req.http.Cookie;
        unset req.http.Authorization;

        return (hash);
    }

    # ── Health check não precisa de cache ──────────────────
    if (req.url == "/health" || req.url == "/catalog") {
        return (pass);
    }

    return (pass);
}

sub vcl_hash {
    hash_data(req.url);
    hash_data(req.http.host);
    return (lookup);
}

sub vcl_backend_response {

    # ── TTL por nível de zoom ──────────────────────────────
    # Extrai zoom da URL: /tiles/{table}/{z}/{x}/{y}.mvt
    if (bereq.url ~ "^/tiles/") {

        # Zoom 0-8: dados raramente mudam → cache 24h
        if (bereq.url ~ "^/tiles/[^/]+/[0-8]/") {
            set beresp.ttl = 86400s;  # 24 horas
            set beresp.grace = 3600s;

        # Zoom 9-12: muda raramente → cache 1h
        } else if (bereq.url ~ "^/tiles/[^/]+/(9|10|11|12)/") {
            set beresp.ttl = 3600s;   # 1 hora
            set beresp.grace = 600s;

        # Zoom 13+: dinâmico → cache 60s (recomendação Crunchy Data)
        } else {
            set beresp.ttl = 60s;
            set beresp.grace = 30s;
        }

        # Não respeitar Cache-Control do backend para tiles
        unset beresp.http.Set-Cookie;
        set beresp.uncacheable = false;
    }

    # ── Compressão ────────────────────────────────────────
    # MVT já é comprimido (protobuf), não recomprimir
    if (beresp.http.Content-Type ~ "application/x-protobuf") {
        set beresp.do_gzip = false;
    }

    return (deliver);
}

sub vcl_deliver {

    # ── Headers de debug (remover em produção) ─────────────
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }

    # ── CORS para MapLibre GL JS ───────────────────────────
    if (req.url ~ "^/tiles/") {
        set resp.http.Access-Control-Allow-Origin = "*";
        set resp.http.Access-Control-Allow-Methods = "GET, OPTIONS";
        set resp.http.Access-Control-Allow-Headers = "Origin, X-Requested-With, Content-Type, Accept";
        set resp.http.Access-Control-Max-Age = "86400";

        # Headers de cache para CDN (Cloudflare)
        set resp.http.Cache-Control = "public, max-age=60, s-maxage=3600";
        set resp.http.Vary = "Accept-Encoding";
    }

    # Remove headers que revelam infraestrutura
    unset resp.http.X-Powered-By;
    unset resp.http.Server;
    unset resp.http.Via;
    unset resp.http.X-Varnish;

    return (deliver);
}

sub vcl_synth {
    if (resp.status == 403) {
        set resp.http.Content-Type = "application/json";
        synthetic({"{"error": "Acesso negado"}"});
        return (deliver);
    }
}
