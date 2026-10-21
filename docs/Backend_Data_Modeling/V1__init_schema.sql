-- =============================================================================
-- V1__init_schema.sql
-- Rental Management – Phase 1 Foundation Schema
-- Target: PostgreSQL 16+   Flyway 10+
-- Architecture decisions:
--   • UUID PKs generated server-side (gen_random_uuid / pgcrypto)
--   • Money stored as NUMERIC(12,2) – never floating point
--   • Timestamps stored as TIMESTAMPTZ (UTC)
--   • Soft deletes via active=false (property)
--   • audit_event is append-only – never UPDATE or DELETE
--   • pg_trgm GIN index powers the free-text ?q= search on property
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- GIN trigram for property full-text search

-- ---------------------------------------------------------------------------
-- Enum types
-- ---------------------------------------------------------------------------
CREATE TYPE user_role AS ENUM (
    'ADMIN',
    'LANDLORD',
    'FAMILY_VIEWER',
    'ACCOUNTANT'
);

CREATE TYPE property_type AS ENUM (
    'TERRACED',
    'SEMI_DETACHED',
    'DETACHED',
    'FLAT',
    'MAISONETTE',
    'BUNGALOW',
    'HMO',
    'OTHER'
);

CREATE TYPE tenancy_status AS ENUM (
    'DRAFT',
    'ACTIVE',
    'NOTICE',
    'ENDED',
    'CANCELLED'
);

-- ---------------------------------------------------------------------------
-- app_user
--   JIT snapshot of Keycloak users, keyed by idp_subject (Keycloak sub claim).
--   Read-only through this API; mutations happen in Keycloak and are synced on login.
-- ---------------------------------------------------------------------------
CREATE TABLE app_user (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    username        VARCHAR(100) NOT NULL,
    display_name    VARCHAR(200) NOT NULL,
    email           VARCHAR(320),
    role            user_role    NOT NULL,
    active          BOOLEAN      NOT NULL DEFAULT TRUE,
    idp_subject     VARCHAR(255),                        -- Keycloak sub claim; set on first login
    -- audit columns (managed by Spring Data JPA @EnableJpaAuditing)
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_app_user               PRIMARY KEY (id),
    CONSTRAINT uq_app_user_username      UNIQUE (username),
    CONSTRAINT uq_app_user_idp_subject   UNIQUE (idp_subject)
);

COMMENT ON TABLE  app_user              IS 'JIT Keycloak user snapshot; synced on OIDC login via sub claim.';
COMMENT ON COLUMN app_user.idp_subject  IS 'Keycloak realm sub claim; null until first login.';
COMMENT ON COLUMN app_user.role         IS 'Mapped from Keycloak realm_access.roles; ADMIN/LANDLORD can write.';

-- ---------------------------------------------------------------------------
-- property
--   Managed rental properties. Soft-deleted via active=false.
-- ---------------------------------------------------------------------------
CREATE TABLE property (
    id                   UUID          NOT NULL DEFAULT gen_random_uuid(),
    property_reference   VARCHAR(50)   NOT NULL,            -- immutable business key e.g. PROP-001
    property_name        VARCHAR(200),
    address_line1        VARCHAR(200)  NOT NULL,
    address_line2        VARCHAR(200),
    town                 VARCHAR(100),
    county               VARCHAR(100),
    postcode             VARCHAR(12)   NOT NULL,
    property_type        property_type,
    purchase_date        DATE,
    purchase_price       NUMERIC(12,2),                     -- Money: NUMERIC(12,2) never FLOAT
    ownership_percentage NUMERIC(5,2)  NOT NULL DEFAULT 100.00,
    notes                TEXT,
    active               BOOLEAN       NOT NULL DEFAULT TRUE, -- soft delete
    -- audit columns
    created_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_by           UUID,

    CONSTRAINT pk_property               PRIMARY KEY (id),
    CONSTRAINT uq_property_reference     UNIQUE (property_reference),
    CONSTRAINT chk_property_ownership    CHECK (ownership_percentage > 0 AND ownership_percentage <= 100),
    CONSTRAINT chk_property_purchase_price CHECK (purchase_price IS NULL OR purchase_price >= 0)
);

COMMENT ON TABLE  property                    IS 'Rental properties; soft-deleted via active=false.';
COMMENT ON COLUMN property.property_reference IS 'Immutable business key assigned at create; unique.';
COMMENT ON COLUMN property.purchase_price     IS 'NUMERIC(12,2) — stored as decimal, never float.';
COMMENT ON COLUMN property.ownership_percentage IS 'Owner share (>0 to 100). Default 100.';

-- GIN trigram index: powers GET /properties?q= free-text search
CREATE INDEX ix_property_fts
    ON property USING GIN (
        (   property_reference
         || ' ' || COALESCE(property_name, '')
         || ' ' || address_line1
         || ' ' || COALESCE(address_line2, '')
         || ' ' || COALESCE(town, '')
         || ' ' || COALESCE(postcode, '')
        ) gin_trgm_ops
    );

CREATE INDEX ix_property_active       ON property (active);
CREATE INDEX ix_property_type         ON property (property_type) WHERE active = TRUE;

-- ---------------------------------------------------------------------------
-- tenancy
--   Contractual tenancy per property.
--   Status machine: DRAFT→ACTIVE|CANCELLED  ACTIVE→NOTICE|ENDED  NOTICE→ENDED
--   ENDED and CANCELLED are terminal.
--   Overlap constraint (same property, non-ended) enforced in application layer.
-- ---------------------------------------------------------------------------
CREATE TABLE tenancy (
    id                    UUID           NOT NULL DEFAULT gen_random_uuid(),
    property_id           UUID           NOT NULL,
    start_date            DATE           NOT NULL,
    end_date              DATE,
    monthly_rent          NUMERIC(12,2)  NOT NULL,
    payment_day           SMALLINT,                          -- 1-31: day of month rent is due
    deposit_amount        NUMERIC(12,2),
    deposit_scheme        VARCHAR(150),                      -- UK TDP scheme name
    deposit_reference     VARCHAR(150),                      -- scheme registration reference
    status                tenancy_status NOT NULL DEFAULT 'DRAFT',
    agreement_document_id UUID,                              -- Phase 2 document module FK
    notes                 TEXT,
    -- audit columns
    created_at            TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ    NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_by            UUID,

    CONSTRAINT pk_tenancy            PRIMARY KEY (id),
    CONSTRAINT fk_tenancy_property   FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT chk_tenancy_dates     CHECK (end_date IS NULL OR end_date > start_date),
    CONSTRAINT chk_tenancy_rent      CHECK (monthly_rent >= 0),
    CONSTRAINT chk_tenancy_deposit   CHECK (deposit_amount IS NULL OR deposit_amount >= 0),
    CONSTRAINT chk_tenancy_pay_day   CHECK (payment_day IS NULL OR payment_day BETWEEN 1 AND 31)
);

COMMENT ON TABLE  tenancy                     IS 'Tenancy agreements linked to a property.';
COMMENT ON COLUMN tenancy.status              IS 'State machine: DRAFT→ACTIVE|CANCELLED ACTIVE→NOTICE|ENDED NOTICE→ENDED.';
COMMENT ON COLUMN tenancy.agreement_document_id IS 'Placeholder for Phase 2 document module; null until wired.';
COMMENT ON COLUMN tenancy.payment_day         IS 'Day of month rent falls due (1–31).';

CREATE INDEX ix_tenancy_property_id           ON tenancy (property_id);
CREATE INDEX ix_tenancy_status                ON tenancy (status);
-- Supports non-ended overlap check: property_id + active statuses + date range
CREATE INDEX ix_tenancy_overlap_check
    ON tenancy (property_id, status, start_date, end_date)
    WHERE status NOT IN ('ENDED', 'CANCELLED');

-- ---------------------------------------------------------------------------
-- tenant
--   Individual tenants linked to a tenancy (many per tenancy).
--   Use PUT with moveOutDate to record departures — prefer over DELETE.
-- ---------------------------------------------------------------------------
CREATE TABLE tenant (
    id                      UUID         NOT NULL DEFAULT gen_random_uuid(),
    tenancy_id              UUID         NOT NULL,
    full_name               VARCHAR(200) NOT NULL,
    email                   VARCHAR(320),
    phone                   VARCHAR(50),
    move_in_date            DATE,
    move_out_date           DATE,
    emergency_contact_name  VARCHAR(200),
    emergency_contact_phone VARCHAR(50),
    notes                   TEXT,
    -- audit columns
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_by              UUID,

    CONSTRAINT pk_tenant           PRIMARY KEY (id),
    CONSTRAINT fk_tenant_tenancy   FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT chk_tenant_dates    CHECK (move_out_date IS NULL OR move_out_date >= move_in_date)
);

COMMENT ON TABLE  tenant              IS 'Tenants on a tenancy. Set move_out_date rather than deleting.';
COMMENT ON COLUMN tenant.move_out_date IS 'Soft-exit: prefer PUT with moveOutDate over DELETE /tenants/{id}.';

CREATE INDEX ix_tenant_tenancy_id ON tenant (tenancy_id);

-- ---------------------------------------------------------------------------
-- audit_event
--   Append-only audit trail. Every mutating API operation writes a row here.
--   Row-level security / application guard: no UPDATE or DELETE on this table.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_event (
    id             UUID         NOT NULL DEFAULT gen_random_uuid(),
    occurred_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actor_id       UUID,                                     -- app_user.id; null for system/service events
    actor_username VARCHAR(100),                             -- denormalised for query convenience
    event_type     VARCHAR(100) NOT NULL,                    -- e.g. PROPERTY_CREATED, TENANCY_STATUS_CHANGED
    aggregate_type VARCHAR(50)  NOT NULL,                    -- e.g. PROPERTY, TENANCY, TENANT
    aggregate_id   UUID         NOT NULL,
    before_state   JSONB,                                    -- null on CREATE events
    after_state    JSONB,                                    -- null on DELETE events
    ip_address     INET,
    trace_id       VARCHAR(64),                              -- MDC/OpenTelemetry trace correlation

    CONSTRAINT pk_audit_event PRIMARY KEY (id)
);

COMMENT ON TABLE  audit_event              IS 'Append-only audit trail per architecture spec. No UPDATE/DELETE.';
COMMENT ON COLUMN audit_event.before_state IS 'JSONB row snapshot before mutation; null for CREATE.';
COMMENT ON COLUMN audit_event.after_state  IS 'JSONB row snapshot after mutation; null for DELETE.';
COMMENT ON COLUMN audit_event.trace_id     IS 'OpenTelemetry / MDC trace ID for log correlation.';

CREATE INDEX ix_audit_aggregate ON audit_event (aggregate_type, aggregate_id, occurred_at DESC);
CREATE INDEX ix_audit_actor     ON audit_event (actor_id, occurred_at DESC);
CREATE INDEX ix_audit_occurred  ON audit_event (occurred_at DESC);
