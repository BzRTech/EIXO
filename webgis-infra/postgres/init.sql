-- ============================================================
-- Inicialização do banco WebGIS
-- PostGIS 3.6 + índices GiST otimizados
-- ============================================================

-- Extensões obrigatórias
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_trgm;          -- Busca textual em atributos
CREATE EXTENSION IF NOT EXISTS btree_gist;        -- Índices GiST em tipos escalares

-- Verificar versões instaladas
DO $$
BEGIN
  RAISE NOTICE 'PostgreSQL: %', version();
  RAISE NOTICE 'PostGIS: %', PostGIS_Version();
  RAISE NOTICE 'GEOS: %', PostGIS_GEOS_Version();
END $$;

-- ── SCHEMA PADRÃO ─────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS gis;
SET search_path TO gis, public;

-- ── TABELA DE EXEMPLO: Geometrias principais ───────────────
-- Substitua/expanda conforme seu domínio de negócio
CREATE TABLE IF NOT EXISTS gis.features (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT,
    category    TEXT,
    properties  JSONB DEFAULT '{}',
    geom        GEOMETRY(GEOMETRY, 4326) NOT NULL,  -- WGS84
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── ÍNDICES GiST ──────────────────────────────────────────
-- Obrigatório para queries espaciais em 200k+ geometrias
-- Retorno: 1-50ms para point-in-polygon e bounding box
CREATE INDEX IF NOT EXISTS idx_features_geom
    ON gis.features USING GIST (geom);

-- Índice GiST em bounding box (mais rápido para tiles)
CREATE INDEX IF NOT EXISTS idx_features_geom_bbox
    ON gis.features USING GIST (geom gist_geometry_ops_nd);

-- Índice para filtros por categoria
CREATE INDEX IF NOT EXISTS idx_features_category
    ON gis.features (category);

-- Índice GIN para busca em propriedades JSONB
CREATE INDEX IF NOT EXISTS idx_features_properties
    ON gis.features USING GIN (properties);

-- Índice de texto para busca por nome
CREATE INDEX IF NOT EXISTS idx_features_name_trgm
    ON gis.features USING GIN (name gin_trgm_ops);

-- ── FUNÇÃO: Auto-update de updated_at ─────────────────────
CREATE OR REPLACE FUNCTION gis.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_features_updated_at
    BEFORE UPDATE ON gis.features
    FOR EACH ROW EXECUTE FUNCTION gis.update_updated_at();

-- ── FUNÇÃO: Simplificação para tiles por zoom ─────────────
-- Reduz complexidade de geometrias conforme nível de zoom
-- Usado internamente pelo Martin tile server
CREATE OR REPLACE FUNCTION gis.simplify_for_zoom(
    geom GEOMETRY,
    zoom INTEGER
) RETURNS GEOMETRY AS $$
DECLARE
    tolerance FLOAT;
BEGIN
    -- Tolerância em graus por nível de zoom (WGS84)
    tolerance := CASE
        WHEN zoom <= 5  THEN 0.01
        WHEN zoom <= 8  THEN 0.005
        WHEN zoom <= 10 THEN 0.001
        WHEN zoom <= 12 THEN 0.0005
        ELSE 0.0001
    END;
    RETURN ST_Simplify(geom, tolerance, true);
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- ── VIEW MATERIALIZÁVEL PARA TILES ────────────────────────
-- Pré-processa geometrias para serving de tiles rápido
-- Refresca via: REFRESH MATERIALIZED VIEW CONCURRENTLY gis.tiles_cache;
CREATE MATERIALIZED VIEW IF NOT EXISTS gis.tiles_cache AS
SELECT
    id,
    name,
    category,
    properties,
    ST_Simplify(geom, 0.0001, true) AS geom,
    ST_Envelope(geom)               AS bbox
FROM gis.features
WHERE ST_IsValid(geom)
  AND NOT ST_IsEmpty(geom);

CREATE UNIQUE INDEX IF NOT EXISTS idx_tiles_cache_id
    ON gis.tiles_cache (id);

CREATE INDEX IF NOT EXISTS idx_tiles_cache_geom
    ON gis.tiles_cache USING GIST (geom);

-- ── ROLE DE LEITURA PARA MARTIN ───────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'martin_ro') THEN
    CREATE ROLE martin_ro LOGIN PASSWORD 'martin_readonly_pass';
  END IF;
END $$;

GRANT CONNECT ON DATABASE webgis TO martin_ro;
GRANT USAGE ON SCHEMA gis TO martin_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA gis TO martin_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA gis GRANT SELECT ON TABLES TO martin_ro;

-- ── DADOS DE EXEMPLO (remova em produção) ─────────────────
-- 5 pontos de exemplo no Brasil
INSERT INTO gis.features (name, category, properties, geom) VALUES
    ('São Paulo - Centro',   'cidade', '{"pop": 12000000}', ST_SetSRID(ST_MakePoint(-46.6333, -23.5505), 4326)),
    ('Rio de Janeiro',       'cidade', '{"pop": 6700000}',  ST_SetSRID(ST_MakePoint(-43.1729, -22.9068), 4326)),
    ('Brasília',             'capital','{"pop": 3000000}',  ST_SetSRID(ST_MakePoint(-47.9292, -15.7801), 4326)),
    ('Manaus',               'cidade', '{"pop": 2100000}',  ST_SetSRID(ST_MakePoint(-60.0212, -3.1190),  4326)),
    ('Porto Alegre',         'cidade', '{"pop": 1400000}',  ST_SetSRID(ST_MakePoint(-51.2177, -30.0346), 4326))
ON CONFLICT DO NOTHING;

-- Atualiza cache de tiles após inserção de exemplo
REFRESH MATERIALIZED VIEW gis.tiles_cache;

RAISE NOTICE '✅ WebGIS database inicializado com sucesso!';
