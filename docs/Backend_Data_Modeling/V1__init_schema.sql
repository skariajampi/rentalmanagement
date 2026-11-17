-- =============================================================================
-- V1__init_schema.sql
-- Rental Management – Complete Foundation Schema (31 tables)
-- Target: PostgreSQL 16+, Flyway 10+
-- =============================================================================
-- Generated from domain-model-design.md; replaces existing draft V1
-- Applies all agreed decisions:
--   • UUID PKs with gen_random_uuid()
--   • Money as NUMERIC(12,2); percentages NUMERIC(5,2)/NUMERIC(7,4)
--   • TIMESTAMPTZ (UTC) for all timestamps
--   • Soft-delete via active=FALSE + optional deactivated_at
--   • Version BIGINT on every aggregate root
--   • Audit columns: created_at, updated_at, created_by, updated_by
--   • Existing V1 enums (property_type, tenancy_status) retained
--   • New enum columns: VARCHAR(n) + CHECK constraint
--   • btree_gist extension for tenancy overlap GiST exclusion
--   • pg_trgm for full-text search indexes
--   • Identity: Keycloak (OIDC/OAuth2 JWT) owns authentication, usernames,
--     passwords, MFA and ROLES. No username/password/role is stored here;
--     app_user is a local identity anchor keyed by (idp_issuer, idp_subject).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid(), encrypt/decrypt
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- Trigram text search GIN index
CREATE EXTENSION IF NOT EXISTS btree_gist;    -- GiST index for range/exclusion constraints

-- ---------------------------------------------------------------------------
-- Enum Types (PostgreSQL CREATE TYPE)
-- ---------------------------------------------------------------------------
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
-- Local identity anchor for Keycloak-authenticated principals, keyed by
-- (idp_issuer, idp_subject) = JWT (iss, sub). Provisioned just-in-time on the
-- first authenticated request (upsert on issuer+subject). Keycloak owns
-- usernames, passwords, MFA, login and roles — none are stored here.
-- Roles arrive as JWT claims and are mapped to Spring Security authorities.
-- ---------------------------------------------------------------------------
CREATE TABLE app_user (
                          id            UUID         NOT NULL DEFAULT gen_random_uuid(),
                          idp_issuer    TEXT         NOT NULL,
                          idp_subject   TEXT         NOT NULL,
                          display_name  VARCHAR(200),
                          email         VARCHAR(320),
                          first_seen_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
                          last_seen_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
                          version       BIGINT       NOT NULL DEFAULT 0,

                          CONSTRAINT pk_app_user  PRIMARY KEY (id),
                          CONSTRAINT uq_app_user_idp UNIQUE (idp_issuer, idp_subject),
                          CONSTRAINT chk_app_user_seen CHECK (last_seen_at >= first_seen_at)
);

COMMENT ON TABLE  app_user               IS 'Local identity anchor for Keycloak principals; JIT-provisioned via upsert on (idp_issuer, idp_subject). Keycloak owns authentication, usernames, passwords, MFA and roles; none are stored here. Exists so FKs (created_by/updated_by, audit actor, owner, uploaded_by, locked_by, generated_by) have a stable target.';
COMMENT ON COLUMN app_user.id            IS 'Internal actor UUID; resolved from JWT (iss, sub) by CurrentActorProvider and used as the target of all user FKs.';
COMMENT ON COLUMN app_user.idp_issuer    IS 'JWT iss claim (Keycloak realm issuer URL). Half of the authentication key; owned by Keycloak.';
COMMENT ON COLUMN app_user.idp_subject   IS 'JWT sub claim (immutable Keycloak user id). Half of the authentication key; owned by Keycloak.';
COMMENT ON COLUMN app_user.display_name  IS 'Snapshot of the name claim, refreshed on login. Display/notifications only; never a key. Source of truth: Keycloak.';
COMMENT ON COLUMN app_user.email         IS 'Snapshot of the email claim, refreshed on login. Display/notifications only; never a key, not unique. Source of truth: Keycloak.';
COMMENT ON COLUMN app_user.active        IS 'App-level soft-disable (FALSE = app rejects the principal even with a valid token). Account enable/disable proper is managed in Keycloak.';
COMMENT ON COLUMN app_user.first_seen_at IS 'Time of JIT provisioning (first authenticated request).';
COMMENT ON COLUMN app_user.last_seen_at  IS 'Time of the most recent authenticated request/login that refreshed the snapshot.';
COMMENT ON COLUMN app_user.version       IS 'Optimistic lock version; auto-incremented by JPA @Version.';

CREATE INDEX ix_app_user_active         ON app_user (active) WHERE active = TRUE;

-- ---------------------------------------------------------------------------
-- property
-- Managed rental properties; soft-deleted via active=FALSE.
-- ---------------------------------------------------------------------------
CREATE TABLE property (
    id                   UUID          NOT NULL DEFAULT gen_random_uuid(),
    property_reference   VARCHAR(50)   NOT NULL,
    property_name        VARCHAR(200),
    address_line1        VARCHAR(200)  NOT NULL,
    address_line2        VARCHAR(200),
    town                 VARCHAR(100),
    county               VARCHAR(100),
    postcode             VARCHAR(12)   NOT NULL,
    property_type        property_type,
    purchase_date        DATE,
    purchase_price       NUMERIC(12,2),
    ownership_percentage NUMERIC(5,2)  NOT NULL DEFAULT 100.00,   -- DEPRECATED; read from property_owner
    notes                TEXT,
    active               BOOLEAN       NOT NULL DEFAULT TRUE,
    version              BIGINT        NOT NULL DEFAULT 0,
    created_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_by           UUID,

    CONSTRAINT pk_property                   PRIMARY KEY (id),
    CONSTRAINT uq_property_reference         UNIQUE (property_reference),
    CONSTRAINT chk_property_ownership        CHECK (ownership_percentage > 0 AND ownership_percentage <= 100),
    CONSTRAINT chk_property_purchase_price   CHECK (purchase_price IS NULL OR purchase_price >= 0)
);

COMMENT ON TABLE  property                    IS 'Rental properties; soft-deleted via active=FALSE.';
COMMENT ON COLUMN property.property_reference IS 'Immutable business key; unique.';
COMMENT ON COLUMN property.purchase_price     IS 'NUMERIC(12,2) — decimal, never floating point.';
COMMENT ON COLUMN property.ownership_percentage IS 'DEPRECATED: read from property_owner SCD Type 2 table instead.';
COMMENT ON COLUMN property.version            IS 'Optimistic lock version.';

CREATE INDEX ix_property_active              ON property (active) WHERE active = TRUE;
CREATE INDEX ix_property_type                ON property (property_type) WHERE active = TRUE;

-- GIN trigram index for full-text search on property (GET /properties?q=)
CREATE INDEX ix_property_fts
    ON property USING GIN (
        (   COALESCE(property_reference, '')
         || ' ' || COALESCE(property_name, '')
         || ' ' || COALESCE(address_line1, '')
         || ' ' || COALESCE(address_line2, '')
         || ' ' || COALESCE(town, '')
         || ' ' || COALESCE(postcode, '')
        ) gin_trgm_ops
    );

-- ---------------------------------------------------------------------------
-- property_owner
-- SCD Type 2: Joint ownership with percentage and effective dates.
-- Current owners: effective_to IS NULL. Aggregate by current to validate sum=100%.
-- ---------------------------------------------------------------------------
CREATE TABLE property_owner (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id     UUID         NOT NULL,
    owner_id        UUID         NOT NULL,
    ownership_pct   NUMERIC(5,2) NOT NULL,
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_property_owner              PRIMARY KEY (id),
    CONSTRAINT fk_property_owner_property     FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_property_owner_owner        FOREIGN KEY (owner_id) REFERENCES app_user (id),
    CONSTRAINT uq_property_owner_record       UNIQUE (property_id, owner_id, effective_from),
    CONSTRAINT chk_property_owner_pct         CHECK (ownership_pct > 0 AND ownership_pct <= 100),
    CONSTRAINT chk_property_owner_dates       CHECK (effective_to IS NULL OR effective_to > effective_from)
);

COMMENT ON TABLE  property_owner              IS 'Ownership history (SCD Type 2); sum of current (effective_to IS NULL) must equal 100%.';
COMMENT ON COLUMN property_owner.ownership_pct IS 'Owner''s share percentage (>0 to 100).';

CREATE INDEX ix_property_owner_current       ON property_owner (property_id) WHERE effective_to IS NULL;
CREATE INDEX ix_property_owner_by_owner      ON property_owner (owner_id);

-- ---------------------------------------------------------------------------
-- agency_agreement
-- Letting agency relationship for a property; active soft-delete.
-- ---------------------------------------------------------------------------
CREATE TABLE agency_agreement (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id         UUID         NOT NULL,
    agency_name         VARCHAR(200) NOT NULL,
    company_name        VARCHAR(200),
    contact_name        VARCHAR(200),
    email               VARCHAR(320),
    phone               VARCHAR(50),
    management_type     VARCHAR(30)  NOT NULL,
    fee_percentage      NUMERIC(7,4),
    fee_fixed           NUMERIC(12,2),
    agreement_start     DATE,
    agreement_end       DATE,
    notice_period_days  INTEGER,
    notes               TEXT,
    active              BOOLEAN      NOT NULL DEFAULT TRUE,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_agency_agreement            PRIMARY KEY (id),
    CONSTRAINT fk_agency_property             FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT chk_management_type            CHECK (management_type IN ('FULL_MANAGEMENT','RENT_COLLECTION','TENANT_FIND','NONE'))
);

COMMENT ON TABLE  agency_agreement            IS 'Letting agency relationship; soft-deleted via active=FALSE.';
COMMENT ON COLUMN agency_agreement.management_type IS 'Type of service: FULL_MANAGEMENT, RENT_COLLECTION, TENANT_FIND, or NONE.';

CREATE INDEX ix_agency_agreement_property    ON agency_agreement (property_id) WHERE active = TRUE;

-- ---------------------------------------------------------------------------
-- agent_fee_schedule
-- Historical fee rates per property and fee type; effective_to=NULL is current.
-- ---------------------------------------------------------------------------
CREATE TABLE agent_fee_schedule (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id     UUID         NOT NULL,
    fee_type        VARCHAR(50)  NOT NULL,
    value           NUMERIC(7,4) NOT NULL,
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_agent_fee_schedule          PRIMARY KEY (id),
    CONSTRAINT fk_agent_fee_property          FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT uq_agent_fee_record            UNIQUE (property_id, fee_type, effective_from),
    CONSTRAINT chk_fee_type                   CHECK (fee_type IN ('MANAGEMENT_MONTHLY_PCT','LETTING_FLAT','RENEWAL_FLAT','LETTING_PCT','RENEWAL_PCT'))
);

COMMENT ON TABLE  agent_fee_schedule         IS 'Historical fee schedule; effective_to=NULL is current rate.';

CREATE INDEX ix_agent_fee_schedule_current   ON agent_fee_schedule (property_id, fee_type) WHERE effective_to IS NULL;

-- ---------------------------------------------------------------------------
-- tenancy
-- Contractual tenancy per property. Status machine and overlap prevention.
-- ---------------------------------------------------------------------------
CREATE TABLE tenancy (
    id                    UUID           NOT NULL DEFAULT gen_random_uuid(),
    property_id           UUID           NOT NULL,
    start_date            DATE           NOT NULL,
    end_date              DATE,
    monthly_rent          NUMERIC(12,2)  NOT NULL,
    payment_day           SMALLINT,
    deposit_amount        NUMERIC(12,2),                      -- DEPRECATED; use tenancy_deposit table
    deposit_scheme        VARCHAR(150),                       -- DEPRECATED
    deposit_reference     VARCHAR(150),                       -- DEPRECATED
    status                tenancy_status NOT NULL DEFAULT 'DRAFT',
    agreement_document_id UUID,
    notes                 TEXT,
    version               BIGINT         NOT NULL DEFAULT 0,
    created_at            TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ    NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_by            UUID,

    CONSTRAINT pk_tenancy                     PRIMARY KEY (id),
    CONSTRAINT fk_tenancy_property            FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT chk_tenancy_dates              CHECK (end_date IS NULL OR end_date > start_date),
    CONSTRAINT chk_tenancy_rent               CHECK (monthly_rent >= 0),
    CONSTRAINT chk_tenancy_deposit            CHECK (deposit_amount IS NULL OR deposit_amount >= 0),
    CONSTRAINT chk_tenancy_payment_day        CHECK (payment_day IS NULL OR payment_day BETWEEN 1 AND 31),
    -- GiST exclusion constraint: no overlapping non-ended tenancies per property
    EXCLUDE USING gist (
        property_id WITH =,
        daterange(start_date, COALESCE(end_date, '9999-12-31'::date), '[)') WITH &&
    ) WHERE (status NOT IN ('ENDED','CANCELLED'))
);

COMMENT ON TABLE  tenancy                    IS 'Tenancy agreements; GiST exclusion prevents overlapping active tenancies on same property.';
COMMENT ON COLUMN tenancy.status             IS 'State machine: DRAFT→ACTIVE|CANCELLED, ACTIVE→NOTICE|ENDED, NOTICE→ENDED.';
COMMENT ON COLUMN tenancy.monthly_rent       IS 'Current rent (see rent_schedule for historical rates).';
COMMENT ON COLUMN tenancy.deposit_amount     IS 'DEPRECATED: use tenancy_deposit table instead.';

CREATE INDEX ix_tenancy_property             ON tenancy (property_id);
CREATE INDEX ix_tenancy_status               ON tenancy (status);
CREATE INDEX ix_tenancy_active               ON tenancy (property_id, status) WHERE status NOT IN ('ENDED','CANCELLED');

-- ---------------------------------------------------------------------------
-- tenant
-- Individual tenants linked to tenancy. Use move_out_date rather than DELETE.
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
    version                 BIGINT       NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_by              UUID,

    CONSTRAINT pk_tenant                      PRIMARY KEY (id),
    CONSTRAINT fk_tenant_tenancy              FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT chk_tenant_dates               CHECK (move_out_date IS NULL OR move_out_date >= move_in_date)
);

COMMENT ON TABLE  tenant                     IS 'Tenants on a tenancy; use move_out_date to record departures rather than DELETE.';

CREATE INDEX ix_tenant_tenancy               ON tenant (tenancy_id);

-- ---------------------------------------------------------------------------
-- rent_schedule
-- Rent rate history per tenancy; effective_to=NULL is current rate.
-- ---------------------------------------------------------------------------
CREATE TABLE rent_schedule (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    tenancy_id      UUID         NOT NULL,
    monthly_rent    NUMERIC(12,2) NOT NULL,
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    notes           TEXT,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_rent_schedule               PRIMARY KEY (id),
    CONSTRAINT fk_rent_schedule_tenancy      FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT uq_rent_schedule_record        UNIQUE (tenancy_id, effective_from),
    CONSTRAINT chk_rent_amount                CHECK (monthly_rent >= 0)
);

COMMENT ON TABLE  rent_schedule              IS 'Rent rate history; effective_to=NULL is current agreed rent.';

CREATE INDEX ix_rent_schedule_tenancy        ON rent_schedule (tenancy_id, effective_from DESC);

-- ---------------------------------------------------------------------------
-- rent_payment
-- Rent payment records; tracks due/paid/partial/late/waived status.
-- ---------------------------------------------------------------------------
CREATE TABLE rent_payment (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    tenancy_id      UUID         NOT NULL,
    due_date        DATE         NOT NULL,
    amount_due      NUMERIC(12,2) NOT NULL,
    amount_paid     NUMERIC(12,2),
    paid_date       DATE,
    payment_method  VARCHAR(50),
    status          VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
    notes           TEXT,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_rent_payment                PRIMARY KEY (id),
    CONSTRAINT fk_rent_payment_tenancy       FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT chk_rent_payment_due           CHECK (amount_due >= 0),
    CONSTRAINT chk_rent_payment_paid          CHECK (amount_paid IS NULL OR amount_paid >= 0),
    CONSTRAINT chk_rent_payment_status        CHECK (status IN ('PENDING','PAID','PARTIAL','LATE','WAIVED'))
);

COMMENT ON TABLE  rent_payment              IS 'Rent payment tracking; statuses: PENDING, PAID, PARTIAL, LATE, WAIVED.';

CREATE INDEX ix_rent_payment_tenancy_due     ON rent_payment (tenancy_id, due_date DESC);
CREATE INDEX ix_rent_payment_status          ON rent_payment (status) WHERE status NOT IN ('PAID','WAIVED');

-- ---------------------------------------------------------------------------
-- tenancy_deposit
-- Tenancy Deposit Scheme registration; one per tenancy (1:1).
-- ---------------------------------------------------------------------------
CREATE TABLE tenancy_deposit (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    tenancy_id          UUID         NOT NULL,
    amount              NUMERIC(12,2) NOT NULL,
    scheme              VARCHAR(30)  NOT NULL,
    scheme_reference    VARCHAR(200),
    registered_date     DATE,
    returned_date       DATE,
    returned_amount     NUMERIC(12,2),
    deductions          NUMERIC(12,2),
    deduction_reason    TEXT,
    status              VARCHAR(20)  NOT NULL DEFAULT 'PENDING_REGISTRATION',
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_tenancy_deposit             PRIMARY KEY (id),
    CONSTRAINT fk_tenancy_deposit_tenancy    FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT uq_tenancy_deposit_tenancy    UNIQUE (tenancy_id),
    CONSTRAINT chk_deposit_amount             CHECK (amount >= 0),
    CONSTRAINT chk_deposit_returned           CHECK (returned_amount IS NULL OR returned_amount >= 0),
    CONSTRAINT chk_deposit_deductions         CHECK (deductions IS NULL OR deductions >= 0),
    CONSTRAINT chk_deposit_scheme             CHECK (scheme IN ('DPS','TDS','MYDEPOSITS','NONE')),
    CONSTRAINT chk_deposit_status             CHECK (status IN ('PENDING_REGISTRATION','HELD','RETURNED','DISPUTED'))
);

COMMENT ON TABLE  tenancy_deposit           IS 'Tenancy Deposit Scheme registration (1:1 with tenancy).';
COMMENT ON COLUMN tenancy_deposit.scheme    IS 'Scheme name: DPS, TDS, MYDEPOSITS, or NONE.';

-- ---------------------------------------------------------------------------
-- income_line
-- Income records (rent, deposits, etc.); soft-deleted via active=FALSE.
-- ---------------------------------------------------------------------------
CREATE TABLE income_line (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id     UUID         NOT NULL,
    tenancy_id      UUID,
    category        VARCHAR(50)  NOT NULL,
    amount          NUMERIC(12,2) NOT NULL,
    received_date   DATE         NOT NULL,
    description     TEXT,
    tax_year        VARCHAR(7),
    active          BOOLEAN      NOT NULL DEFAULT TRUE,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_income_line                 PRIMARY KEY (id),
    CONSTRAINT fk_income_property             FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_income_tenancy              FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT chk_income_category            CHECK (category IN ('RENT','HOLDING_DEPOSIT','DEPOSIT','RENT_GUARANTEE','INSURANCE_CLAIM','OTHER')),
    CONSTRAINT chk_income_amount              CHECK (amount >= 0)
);

COMMENT ON TABLE  income_line              IS 'Income records; soft-deleted via active=FALSE. Categories: RENT, HOLDING_DEPOSIT, DEPOSIT, RENT_GUARANTEE, INSURANCE_CLAIM, OTHER.';

CREATE INDEX ix_income_property_taxyear     ON income_line (property_id, tax_year) WHERE active = TRUE;
CREATE INDEX ix_income_received             ON income_line (received_date DESC);

-- ---------------------------------------------------------------------------
-- expense
-- Expense records with category, approval, and owner split.
-- Soft-deleted via active=FALSE.
-- ---------------------------------------------------------------------------
CREATE TABLE expense (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id         UUID         NOT NULL,
    category            VARCHAR(50)  NOT NULL,
    amount              NUMERIC(12,2) NOT NULL,
    expense_date        DATE         NOT NULL,
    payee               VARCHAR(200),
    description         TEXT,
    tax_classification  VARCHAR(20)  NOT NULL DEFAULT 'UNKNOWN',
    tax_deductible      BOOLEAN      NOT NULL DEFAULT TRUE,
    tax_year            VARCHAR(7),
    vat_amount          NUMERIC(12,2),
    owner_id            UUID,
    work_order_id       UUID,
    approval_status     VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
    active              BOOLEAN      NOT NULL DEFAULT TRUE,
    deactivated_at      TIMESTAMPTZ,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_expense                     PRIMARY KEY (id),
    CONSTRAINT fk_expense_property            FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_expense_owner               FOREIGN KEY (owner_id) REFERENCES app_user (id),
    -- fk_expense_work_order (-> work_order) is added via ALTER TABLE after work_order is created
    CONSTRAINT chk_expense_category           CHECK (category IN (
        'AGENT_MANAGEMENT_FEE','AGENT_LETTING_FEE','AGENT_RENEWAL_FEE','ADMIN_FEE',
        'PAT_TEST','GAS_SAFETY_CERT','EICR','EPC','FIRE_ALARM_TEST','EMERGENCY_LIGHTING_TEST',
        'LEGIONELLA_RISK','REPAIR','MAINTENANCE','PROFESSIONAL_CLEANING','LEGAL_FEES',
        'INSURANCE','MORTGAGE_INTEREST','ACCOUNTANCY_FEES','ADVERTISING','COUNCIL_TAX',
        'UTILITIES','GROUND_RENT','SERVICE_CHARGE','TRAVEL','OTHER'
    )),
    CONSTRAINT chk_expense_amount             CHECK (amount >= 0),
    CONSTRAINT chk_expense_vat                CHECK (vat_amount IS NULL OR vat_amount >= 0),
    CONSTRAINT chk_tax_classification         CHECK (tax_classification IN ('REVENUE','CAPITAL','PRIVATE','FINANCE','UNKNOWN')),
    CONSTRAINT chk_approval_status            CHECK (approval_status IN ('PENDING','APPROVED','REJECTED','VOIDED'))
);

COMMENT ON TABLE  expense                   IS 'Expense records; soft-deleted via active=FALSE. Only APPROVED status feeds tax calculations.';
COMMENT ON COLUMN expense.category          IS '25 categories including agent fees, certifications, repairs, and professional services.';
COMMENT ON COLUMN expense.tax_classification IS 'SA105 classification: REVENUE (allowable), CAPITAL, PRIVATE (excluded), FINANCE, UNKNOWN.';
COMMENT ON COLUMN expense.owner_id          IS 'NULL means joint expense; split via expense_allocation.';

CREATE INDEX ix_expense_property_taxyear    ON expense (property_id, tax_year) WHERE active = TRUE;
CREATE INDEX ix_expense_category            ON expense (category);
CREATE INDEX ix_expense_date                ON expense (expense_date DESC);
CREATE INDEX ix_expense_approval            ON expense (approval_status) WHERE approval_status = 'PENDING';
CREATE INDEX ix_expense_workorder           ON expense (work_order_id) WHERE work_order_id IS NOT NULL;

-- Forward reference in work_order constraint; work_order defined below

-- ---------------------------------------------------------------------------
-- expense_allocation
-- Splits an expense among owners. If no rows, default to property_owner splits.
-- ---------------------------------------------------------------------------
CREATE TABLE expense_allocation (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    expense_id          UUID         NOT NULL,
    owner_id            UUID         NOT NULL,
    allocated_amount    NUMERIC(12,2) NOT NULL,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,

    CONSTRAINT pk_expense_allocation          PRIMARY KEY (id),
    CONSTRAINT fk_expense_allocation_expense FOREIGN KEY (expense_id) REFERENCES expense (id),
    CONSTRAINT fk_expense_allocation_owner   FOREIGN KEY (owner_id) REFERENCES app_user (id),
    CONSTRAINT uq_expense_allocation_owner    UNIQUE (expense_id, owner_id),
    CONSTRAINT chk_allocation_amount          CHECK (allocated_amount >= 0)
);

COMMENT ON TABLE  expense_allocation        IS 'Expense split among owners. If no rows, sum property_owner current percentages.';

-- ---------------------------------------------------------------------------
-- contractor
-- Maintenance/repair contractors; soft-deleted via active=FALSE.
-- ---------------------------------------------------------------------------
CREATE TABLE contractor (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    name            VARCHAR(200) NOT NULL,
    company_name    VARCHAR(200),
    trade           VARCHAR(50)  NOT NULL,
    phone           VARCHAR(50),
    email           VARCHAR(320),
    notes           TEXT,
    active          BOOLEAN      NOT NULL DEFAULT TRUE,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_contractor                  PRIMARY KEY (id),
    CONSTRAINT chk_contractor_trade           CHECK (trade IN (
        'ELECTRICIAN','GAS_ENGINEER','PLUMBER','GENERAL_BUILDER','CLEANER',
        'LOCKSMITH','GLAZIER','ROOFER','PAINTER','CARPET_FITTER','GARDENER','OTHER'
    ))
);

COMMENT ON TABLE  contractor                IS 'Contractors; soft-deleted via active=FALSE. 12 trade types.';

-- ---------------------------------------------------------------------------
-- work_order
-- Maintenance/repair work requests; links to contractor and expense.
-- ---------------------------------------------------------------------------
CREATE TABLE work_order (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id         UUID         NOT NULL,
    contractor_id       UUID,
    title               VARCHAR(300) NOT NULL,
    description         TEXT,
    category            VARCHAR(30)  NOT NULL,
    priority            VARCHAR(20),
    raised_date         DATE         NOT NULL DEFAULT CURRENT_DATE,
    scheduled_date      DATE,
    completed_date      DATE,
    labour_cost         NUMERIC(12,2),
    materials_cost      NUMERIC(12,2),
    total_cost          NUMERIC(12,2),
    status              VARCHAR(20)  NOT NULL DEFAULT 'OPEN',
    raised_by_id        UUID,
    notes               TEXT,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_work_order                  PRIMARY KEY (id),
    CONSTRAINT fk_work_order_property         FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_work_order_contractor       FOREIGN KEY (contractor_id) REFERENCES contractor (id),
    CONSTRAINT fk_work_order_raised_by        FOREIGN KEY (raised_by_id) REFERENCES app_user (id),
    CONSTRAINT chk_work_order_category        CHECK (category IN ('REPAIR','MAINTENANCE','COMPLIANCE','INSPECTION','EMERGENCY','IMPROVEMENT')),
    CONSTRAINT chk_work_order_priority        CHECK (priority IS NULL OR priority IN ('EMERGENCY','URGENT','ROUTINE','COSMETIC')),
    CONSTRAINT chk_work_order_status          CHECK (status IN ('OPEN','SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED')),
    CONSTRAINT chk_work_order_costs           CHECK (labour_cost IS NULL OR labour_cost >= 0),
    CONSTRAINT chk_work_order_materials       CHECK (materials_cost IS NULL OR materials_cost >= 0),
    CONSTRAINT chk_work_order_total           CHECK (total_cost IS NULL OR total_cost >= 0)
);

COMMENT ON TABLE  work_order               IS 'Work order; can generate an expense record on completion.';
COMMENT ON COLUMN work_order.category      IS 'Work type: REPAIR, MAINTENANCE, COMPLIANCE, INSPECTION, EMERGENCY, IMPROVEMENT.';

CREATE INDEX ix_work_order_property_status   ON work_order (property_id, status);
CREATE INDEX ix_work_order_contractor        ON work_order (contractor_id) WHERE contractor_id IS NOT NULL;

-- Now add the constraint on expense.work_order_id that was forward-referenced
ALTER TABLE expense
    ADD CONSTRAINT fk_expense_work_order FOREIGN KEY (work_order_id) REFERENCES work_order (id);

-- ---------------------------------------------------------------------------
-- compliance_certificate
-- Regulatory certificates (gas, electrical, EPC, etc.); not soft-deleted.
-- ---------------------------------------------------------------------------
CREATE TABLE compliance_certificate (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id         UUID         NOT NULL,
    cert_type           VARCHAR(50)  NOT NULL,
    issue_date          DATE,
    expiry_date         DATE,
    issued_by           VARCHAR(200),
    certificate_reference VARCHAR(200),
    is_current          BOOLEAN      NOT NULL DEFAULT TRUE,
    notes               TEXT,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_compliance_certificate      PRIMARY KEY (id),
    CONSTRAINT fk_compliance_property         FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT chk_compliance_type            CHECK (cert_type IN (
        'GAS_SAFETY','EICR','EPC','PAT_TEST','FIRE_ALARM','EMERGENCY_LIGHTING',
        'LEGIONELLA_RISK','HMO_LICENCE','SELECTIVE_LICENCE','SMOKE_ALARM','CO_ALARM',
        'BOILER_SERVICE','INSURANCE','PROPERTY_INSPECTION','OTHER'
    ))
);

COMMENT ON TABLE  compliance_certificate   IS 'Compliance certificates; not soft-deleted (historical by nature). Used for expiry alerting.';

CREATE INDEX ix_compliance_expiry           ON compliance_certificate (property_id, cert_type, expiry_date)
    WHERE is_current = TRUE AND expiry_date IS NOT NULL;

-- ---------------------------------------------------------------------------
-- inspection
-- Property inspections (move-in, periodic, move-out, etc.).
-- ---------------------------------------------------------------------------
CREATE TABLE inspection (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id         UUID         NOT NULL,
    tenancy_id          UUID,
    inspection_type     VARCHAR(30)  NOT NULL,
    scheduled_date      DATE,
    conducted_date      DATE,
    conducted_by        VARCHAR(200),
    overall_condition   VARCHAR(20),
    notes               TEXT,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_inspection                  PRIMARY KEY (id),
    CONSTRAINT fk_inspection_property         FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_inspection_tenancy          FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT chk_inspection_type            CHECK (inspection_type IN ('MOVE_IN','PERIODIC','MOVE_OUT','EMERGENCY','PRE_LETTING')),
    CONSTRAINT chk_inspection_condition       CHECK (overall_condition IS NULL OR overall_condition IN ('EXCELLENT','GOOD','FAIR','POOR'))
);

COMMENT ON TABLE  inspection                IS 'Property inspections; types: MOVE_IN, PERIODIC, MOVE_OUT, EMERGENCY, PRE_LETTING.';

CREATE INDEX ix_inspection_property_date     ON inspection (property_id, conducted_date DESC);

-- ---------------------------------------------------------------------------
-- inspection_item
-- Findings for a specific room/area in an inspection.
-- ---------------------------------------------------------------------------
CREATE TABLE inspection_item (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    inspection_id       UUID         NOT NULL,
    room_or_area        VARCHAR(200) NOT NULL,
    description         TEXT,
    condition           VARCHAR(20),
    action_required     BOOLEAN      NOT NULL DEFAULT FALSE,
    action_description  TEXT,
    photo_document_id   UUID,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,

    CONSTRAINT pk_inspection_item             PRIMARY KEY (id),
    CONSTRAINT fk_inspection_item_inspection FOREIGN KEY (inspection_id) REFERENCES inspection (id) ON DELETE CASCADE,
    CONSTRAINT chk_inspection_item_condition  CHECK (condition IS NULL OR condition IN ('EXCELLENT','GOOD','FAIR','POOR','DAMAGED','MISSING'))
);

COMMENT ON TABLE  inspection_item          IS 'Room/area findings within an inspection (child of inspection).';

-- ---------------------------------------------------------------------------
-- audit_event
-- Append-only audit trail; never UPDATE or DELETE.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_event (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    occurred_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actor_id        UUID,
    actor_display_name VARCHAR(200),
    event_type      VARCHAR(100) NOT NULL,
    aggregate_type  VARCHAR(50)  NOT NULL,
    aggregate_id    UUID         NOT NULL,
    before_state    JSONB,
    after_state     JSONB,
    ip_address      INET,
    trace_id        VARCHAR(64),

    CONSTRAINT pk_audit_event                 PRIMARY KEY (id)
);

COMMENT ON TABLE  audit_event              IS 'Append-only audit trail; no UPDATE or DELETE permitted.';
COMMENT ON COLUMN audit_event.actor_id      IS 'app_user.id of the actor, resolved from JWT (iss, sub).';
COMMENT ON COLUMN audit_event.actor_display_name IS 'Copy of app_user.display_name at event time (point-in-time snapshot; username is not stored).';
COMMENT ON COLUMN audit_event.before_state  IS 'JSONB row snapshot before mutation; NULL on CREATE.';
COMMENT ON COLUMN audit_event.after_state   IS 'JSONB row snapshot after mutation; NULL on DELETE.';
COMMENT ON COLUMN audit_event.trace_id      IS 'OpenTelemetry/MDC trace ID for log correlation.';

CREATE INDEX ix_audit_aggregate             ON audit_event (aggregate_type, aggregate_id, occurred_at DESC);
CREATE INDEX ix_audit_actor                 ON audit_event (actor_id, occurred_at DESC);
CREATE INDEX ix_audit_occurred              ON audit_event (occurred_at DESC);

-- ---------------------------------------------------------------------------
-- correspondence
-- Email, letter, SMS, or portal messages related to property/tenancy.
-- ---------------------------------------------------------------------------
CREATE TABLE correspondence (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id         UUID         NOT NULL,
    tenancy_id          UUID,
    direction           VARCHAR(10)  NOT NULL,
    channel             VARCHAR(20)  NOT NULL,
    subject             VARCHAR(500),
    summary             TEXT,
    correspondence_date DATE         NOT NULL,
    from_party          VARCHAR(200),
    to_party            VARCHAR(200),
    is_legal            BOOLEAN      NOT NULL DEFAULT FALSE,
    notes               TEXT,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_correspondence              PRIMARY KEY (id),
    CONSTRAINT fk_correspondence_property    FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_correspondence_tenancy     FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT chk_correspondence_direction   CHECK (direction IN ('INBOUND','OUTBOUND')),
    CONSTRAINT chk_correspondence_channel     CHECK (channel IN ('EMAIL','LETTER','SMS','PORTAL','PHONE'))
);

COMMENT ON TABLE  correspondence           IS 'Correspondence record; channels: EMAIL, LETTER, SMS, PORTAL, PHONE.';

CREATE INDEX ix_correspondence_property_date ON correspondence (property_id, correspondence_date DESC);

-- ---------------------------------------------------------------------------
-- legal_notice
-- Legal notices (Section 21, Section 8, etc.); not soft-deleted.
-- ---------------------------------------------------------------------------
CREATE TABLE legal_notice (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id         UUID         NOT NULL,
    tenancy_id          UUID,
    notice_type         VARCHAR(50)  NOT NULL,
    served_date         DATE,
    effective_date      DATE,
    response_due_date   DATE,
    status              VARCHAR(30)  NOT NULL DEFAULT 'DRAFT',
    notes               TEXT,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_legal_notice                PRIMARY KEY (id),
    CONSTRAINT fk_legal_notice_property      FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_legal_notice_tenancy       FOREIGN KEY (tenancy_id) REFERENCES tenancy (id),
    CONSTRAINT chk_legal_notice_type         CHECK (notice_type IN (
        'SECTION_21','SECTION_8','DEPOSIT_PRESCRIBED_INFO','RENT_INCREASE',
        'INSPECTION_NOTICE','NOTICE_TO_QUIT','OTHER'
    )),
    CONSTRAINT chk_legal_notice_status       CHECK (status IN ('DRAFT','SERVED','ACKNOWLEDGED','EXPIRED','WITHDRAWN','DISPUTED'))
);

COMMENT ON TABLE  legal_notice             IS 'Legal notices (Section 21, Section 8, etc.); statuses: DRAFT, SERVED, ACKNOWLEDGED, EXPIRED, WITHDRAWN, DISPUTED.';

CREATE INDEX ix_legal_notice_property       ON legal_notice (property_id, tenancy_id);

-- ---------------------------------------------------------------------------
-- document
-- Document metadata; binaries stored in S3. Soft-deleted via active=FALSE.
-- ---------------------------------------------------------------------------
CREATE TABLE document (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    display_name        VARCHAR(500) NOT NULL,
    original_filename   VARCHAR(500),
    s3_bucket           VARCHAR(200) NOT NULL,
    s3_key              VARCHAR(1000) NOT NULL,
    content_type        VARCHAR(200),
    size_bytes          BIGINT,
    sha256_hash         VARCHAR(64),
    uploaded_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    uploaded_by_id      UUID,
    description         TEXT,
    document_type       VARCHAR(50)  NOT NULL,
    supplier_name       VARCHAR(200),
    extracted_text      TEXT,
    upload_status       VARCHAR(30)  NOT NULL DEFAULT 'UPLOADING',
    search_vector       TSVECTOR     NOT NULL GENERATED ALWAYS AS (
        to_tsvector('english', 
            COALESCE(display_name,'') || ' ' || COALESCE(original_filename,'') || ' ' ||
            COALESCE(document_type,'') || ' ' || COALESCE(supplier_name,'') || ' ' ||
            COALESCE(extracted_text,'')
        )
    ) STORED,
    active              BOOLEAN      NOT NULL DEFAULT TRUE,
    deactivated_at      TIMESTAMPTZ,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_document                    PRIMARY KEY (id),
    CONSTRAINT fk_document_uploaded_by        FOREIGN KEY (uploaded_by_id) REFERENCES app_user (id),
    CONSTRAINT chk_document_type              CHECK (document_type IN (
        'RECEIPT','INVOICE','LEASE_AGREEMENT','GAS_CERTIFICATE','EICR','EPC',
        'PAT_REPORT','FIRE_ALARM_REPORT','EMERGENCY_LIGHTING_REPORT','INSPECTION_REPORT',
        'CORRESPONDENCE','LEGAL','BANK_STATEMENT','TAX_DOCUMENT','CONTRACTOR_QUOTE',
        'CONTRACTOR_INVOICE','PHOTO','AGENT_STATEMENT','INSURANCE_POLICY','MORTGAGE_DOCUMENT','OTHER'
    )),
    CONSTRAINT chk_upload_status              CHECK (upload_status IN (
        'UPLOADING','AVAILABLE','OCR_PENDING','OCR_PROCESSING','SEARCHABLE',
        'UPLOAD_FAILED','OCR_FAILED'
    ))
);

COMMENT ON TABLE  document                 IS 'Document metadata; binaries in S3, metadata here. Soft-deleted via active=FALSE.';
COMMENT ON COLUMN document.search_vector   IS 'Full-text search vector; automatically generated from display_name, filename, type, supplier, OCR text.';
COMMENT ON COLUMN document.upload_status   IS 'Upload pipeline state: UPLOADING → AVAILABLE → [OCR] → SEARCHABLE | FAILED.';

CREATE INDEX ix_document_search             ON document USING GIN (search_vector);
CREATE INDEX ix_document_type               ON document (document_type) WHERE active = TRUE;
CREATE INDEX ix_document_sha256             ON document (sha256_hash) WHERE sha256_hash IS NOT NULL;
CREATE INDEX ix_document_supplier_trgm      ON document USING GIN (supplier_name gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- document_version
-- Version history for document updates; immutable once created.
-- ---------------------------------------------------------------------------
CREATE TABLE document_version (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    document_id         UUID         NOT NULL,
    version_number      INTEGER      NOT NULL,
    s3_key              VARCHAR(1000) NOT NULL,
    size_bytes          BIGINT,
    sha256_hash         VARCHAR(64),
    uploaded_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    uploaded_by_id      UUID,

    CONSTRAINT pk_document_version            PRIMARY KEY (id),
    CONSTRAINT fk_document_version_document  FOREIGN KEY (document_id) REFERENCES document (id),
    CONSTRAINT fk_document_version_uploader  FOREIGN KEY (uploaded_by_id) REFERENCES app_user (id),
    CONSTRAINT uq_document_version_number    UNIQUE (document_id, version_number)
);

COMMENT ON TABLE  document_version         IS 'Document version history; immutable (child of document).';

-- ---------------------------------------------------------------------------
-- document_link
-- Polymorphic join linking documents to entities (property, expense, etc.).
-- ---------------------------------------------------------------------------
CREATE TABLE document_link (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    document_id         UUID         NOT NULL,
    entity_type         VARCHAR(50)  NOT NULL,
    entity_id           UUID         NOT NULL,
    relationship        VARCHAR(50)  NOT NULL DEFAULT 'ATTACHED_TO',
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,

    CONSTRAINT pk_document_link               PRIMARY KEY (id),
    CONSTRAINT fk_document_link_document     FOREIGN KEY (document_id) REFERENCES document (id) ON DELETE CASCADE,
    CONSTRAINT uq_document_link               UNIQUE (document_id, entity_type, entity_id),
    CONSTRAINT chk_entity_type                CHECK (entity_type IN (
        'PROPERTY','EXPENSE','WORK_ORDER','COMPLIANCE_CERT','TENANCY','INCOME_LINE',
        'CONTRACTOR','TAX_PACK','CORRESPONDENCE','INSPECTION','LEGAL_NOTICE',
        'RENT_PAYMENT','AGENCY_AGREEMENT','AGENT_STATEMENT'
    )),
    CONSTRAINT chk_relationship               CHECK (relationship IN ('SUPPORTS','EVIDENCE_FOR','ATTACHED_TO','SOURCE_OF'))
);

COMMENT ON TABLE  document_link            IS 'Polymorphic join: documents linked to any entity type (property, expense, etc.). No FK on entity_id (application-layer validation).';
COMMENT ON COLUMN document_link.entity_type IS '14 entity types linkable to documents.';
COMMENT ON COLUMN document_link.relationship IS 'Link semantic: SUPPORTS, EVIDENCE_FOR, ATTACHED_TO, SOURCE_OF.';

CREATE INDEX ix_document_link_entity        ON document_link (entity_type, entity_id);
CREATE INDEX ix_document_link_document      ON document_link (document_id);

-- ---------------------------------------------------------------------------
-- agent_statement
-- Reconciliation of agency statements; issued by lettings agency.
-- ---------------------------------------------------------------------------
CREATE TABLE agent_statement (
    id                      UUID         NOT NULL DEFAULT gen_random_uuid(),
    agency_agreement_id     UUID         NOT NULL,
    property_id             UUID         NOT NULL,
    statement_period_start  DATE         NOT NULL,
    statement_period_end    DATE         NOT NULL,
    gross_rent              NUMERIC(12,2),
    management_fee          NUMERIC(12,2),
    other_deductions        NUMERIC(12,2),
    net_amount              NUMERIC(12,2),
    status                  VARCHAR(30)  NOT NULL DEFAULT 'UPLOADED',
    version                 BIGINT       NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_by              UUID,

    CONSTRAINT pk_agent_statement             PRIMARY KEY (id),
    CONSTRAINT fk_agent_statement_agreement  FOREIGN KEY (agency_agreement_id) REFERENCES agency_agreement (id),
    CONSTRAINT fk_agent_statement_property   FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT chk_statement_period           CHECK (statement_period_end > statement_period_start),
    CONSTRAINT chk_statement_status           CHECK (status IN ('UPLOADED','RECONCILED','PARTIALLY_RECONCILED','DISPUTED'))
);

COMMENT ON TABLE  agent_statement          IS 'Agency statement for reconciliation; statuses: UPLOADED, RECONCILED, PARTIALLY_RECONCILED, DISPUTED.';

CREATE INDEX ix_agent_statement_property    ON agent_statement (property_id, statement_period_start DESC);

-- ---------------------------------------------------------------------------
-- agent_statement_line
-- Line items on an agent statement; semi-automated matching to income/expense.
-- ---------------------------------------------------------------------------
CREATE TABLE agent_statement_line (
    id                      UUID         NOT NULL DEFAULT gen_random_uuid(),
    agent_statement_id      UUID         NOT NULL,
    transaction_date        DATE         NOT NULL,
    description             TEXT,
    amount                  NUMERIC(12,2) NOT NULL,
    line_type               VARCHAR(30)  NOT NULL,
    matched_income_id       UUID,
    matched_expense_id      UUID,
    reconciliation_status   VARCHAR(30)  NOT NULL DEFAULT 'UNMATCHED',
    match_confidence        NUMERIC(3,2),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by              UUID,

    CONSTRAINT pk_agent_statement_line       PRIMARY KEY (id),
    CONSTRAINT fk_agent_statement_line_stmt FOREIGN KEY (agent_statement_id) REFERENCES agent_statement (id) ON DELETE CASCADE,
    CONSTRAINT fk_agent_statement_line_inc   FOREIGN KEY (matched_income_id) REFERENCES income_line (id),
    CONSTRAINT fk_agent_statement_line_exp   FOREIGN KEY (matched_expense_id) REFERENCES expense (id),
    CONSTRAINT chk_line_type                 CHECK (line_type IN ('RENT','MANAGEMENT_FEE','REPAIR','INSURANCE','OTHER_DEDUCTION','TRANSFER')),
    CONSTRAINT chk_reconciliation_status     CHECK (reconciliation_status IN ('UNMATCHED','MATCHED','IGNORED','REVIEW_REQUIRED')),
    CONSTRAINT chk_match_confidence          CHECK (match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1))
);

COMMENT ON TABLE  agent_statement_line     IS 'Agent statement line item; semi-automated matching via match_confidence suggestion.';
COMMENT ON COLUMN agent_statement_line.amount IS 'Signed: positive=income, negative=deduction.';
COMMENT ON COLUMN agent_statement_line.match_confidence IS 'System match suggestion score 0.00–1.00; user confirms or overrides.';
COMMENT ON COLUMN agent_statement_line.reconciliation_status IS 'UNMATCHED (no match yet), MATCHED (user confirmed), IGNORED (user skipped), REVIEW_REQUIRED (high discrepancy).';

CREATE INDEX ix_agent_statement_line_recon  ON agent_statement_line (reconciliation_status)
    WHERE reconciliation_status IN ('UNMATCHED','REVIEW_REQUIRED');

-- ---------------------------------------------------------------------------
-- tax_year
-- UK fiscal year (6 April – 5 April); tracks open/closed/filed status.
-- ---------------------------------------------------------------------------
CREATE TABLE tax_year (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    tax_year_label  VARCHAR(7)   NOT NULL,
    start_date      DATE         NOT NULL,
    end_date        DATE         NOT NULL,
    status          VARCHAR(20)  NOT NULL DEFAULT 'OPEN',
    locked_at       TIMESTAMPTZ,
    locked_by_id    UUID,
    unlock_reason   TEXT,
    version         BIGINT       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID,

    CONSTRAINT pk_tax_year                    PRIMARY KEY (id),
    CONSTRAINT uq_tax_year_label              UNIQUE (tax_year_label),
    CONSTRAINT fk_tax_year_locked_by          FOREIGN KEY (locked_by_id) REFERENCES app_user (id),
    CONSTRAINT chk_tax_year_dates             CHECK (end_date > start_date),
    CONSTRAINT chk_tax_year_status            CHECK (status IN ('OPEN','CLOSED','FILED'))
);

COMMENT ON TABLE  tax_year                 IS 'UK fiscal year (6 April – 5 April); OPEN→CLOSED→FILED status machine.';
COMMENT ON COLUMN tax_year.tax_year_label  IS 'Format: YYYY-YY e.g. 2025-26.';

-- ---------------------------------------------------------------------------
-- tax_year_summary
-- Aggregated tax data per property and owner for a tax year.
-- Is_draft=TRUE until explicitly reviewed; never auto-used for filing.
-- ---------------------------------------------------------------------------
CREATE TABLE tax_year_summary (
    id                      UUID         NOT NULL DEFAULT gen_random_uuid(),
    property_id             UUID         NOT NULL,
    tax_year_id             UUID         NOT NULL,
    owner_id                UUID         NOT NULL,
    gross_income            NUMERIC(12,2) NOT NULL DEFAULT 0,
    allowable_expenses      NUMERIC(12,2) NOT NULL DEFAULT 0,
    finance_costs           NUMERIC(12,2) NOT NULL DEFAULT 0,
    capital_expenses        NUMERIC(12,2) NOT NULL DEFAULT 0,
    net_profit              NUMERIC(12,2) NOT NULL DEFAULT 0,
    owner_share_pct         NUMERIC(5,2) NOT NULL,
    owner_net_profit        NUMERIC(12,2) NOT NULL DEFAULT 0,
    personal_allowance_used NUMERIC(12,2),
    tax_due                 NUMERIC(12,2),
    is_draft                BOOLEAN      NOT NULL DEFAULT TRUE,
    notes                   TEXT,
    version                 BIGINT       NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_by              UUID,

    CONSTRAINT pk_tax_year_summary            PRIMARY KEY (id),
    CONSTRAINT fk_tax_year_summary_property  FOREIGN KEY (property_id) REFERENCES property (id),
    CONSTRAINT fk_tax_year_summary_taxyear   FOREIGN KEY (tax_year_id) REFERENCES tax_year (id),
    CONSTRAINT fk_tax_year_summary_owner     FOREIGN KEY (owner_id) REFERENCES app_user (id),
    CONSTRAINT uq_tax_year_summary            UNIQUE (property_id, tax_year_id, owner_id)
);

COMMENT ON TABLE  tax_year_summary         IS 'Aggregated tax summary per property/owner/year; is_draft=TRUE until reviewed (never auto-filed).';
COMMENT ON COLUMN tax_year_summary.allowable_expenses IS 'Sum of APPROVED REVENUE-classified expenses.';
COMMENT ON COLUMN tax_year_summary.finance_costs IS 'Sum of APPROVED FINANCE-classified expenses.';
COMMENT ON COLUMN tax_year_summary.owner_share_pct IS 'Snapshot of ownership percentage at tax year end.';

CREATE INDEX ix_tax_year_summary_taxyear    ON tax_year_summary (tax_year_id, property_id);

-- ---------------------------------------------------------------------------
-- self_assessment_pack
-- Container for self-assessment generation; one per owner per tax year.
-- ---------------------------------------------------------------------------
CREATE TABLE self_assessment_pack (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    tax_year_id         UUID         NOT NULL,
    owner_id            UUID         NOT NULL,
    generated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    status              VARCHAR(20)  NOT NULL DEFAULT 'DRAFT',
    submission_reference VARCHAR(200),
    notes               TEXT,
    generated_by_id     UUID,
    version             BIGINT       NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,

    CONSTRAINT pk_self_assessment_pack       PRIMARY KEY (id),
    CONSTRAINT fk_self_assessment_taxyear   FOREIGN KEY (tax_year_id) REFERENCES tax_year (id),
    CONSTRAINT fk_self_assessment_owner     FOREIGN KEY (owner_id) REFERENCES app_user (id),
    CONSTRAINT fk_self_assessment_generated_by FOREIGN KEY (generated_by_id) REFERENCES app_user (id),
    CONSTRAINT uq_self_assessment_pack       UNIQUE (tax_year_id, owner_id),
    CONSTRAINT chk_sa_pack_status            CHECK (status IN ('DRAFT','READY','SUBMITTED'))
);

COMMENT ON TABLE  self_assessment_pack     IS 'Self-assessment pack container; one per owner/tax_year; statuses: DRAFT, READY, SUBMITTED.';

-- ---------------------------------------------------------------------------
-- reminder_rule
-- Rule-based reminders for expiring certificates, overdue rent, etc.
-- One rule per channel; multi-channel requires multiple rules.
-- ---------------------------------------------------------------------------
CREATE TABLE reminder_rule (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    target_type     VARCHAR(50)  NOT NULL,
    target_id       UUID         NOT NULL,
    reminder_type   VARCHAR(50)  NOT NULL,
    days_before     INTEGER      NOT NULL,
    recurrence      VARCHAR(30)  NOT NULL,
    channel         VARCHAR(30)  NOT NULL,
    enabled         BOOLEAN      NOT NULL DEFAULT TRUE,
    recipient       VARCHAR(320),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by      UUID,

    CONSTRAINT pk_reminder_rule               PRIMARY KEY (id),
    CONSTRAINT chk_reminder_recurrence        CHECK (recurrence IN ('ONCE','DAILY','WEEKLY','MONTHLY','ANNUALLY')),
    CONSTRAINT chk_reminder_channel           CHECK (channel IN ('IN_APP','EMAIL','SMS','NTFY'))
);

COMMENT ON TABLE  reminder_rule            IS 'Reminder rule; one per channel. Multi-channel: create multiple rules with same target_type/target_id.';
COMMENT ON COLUMN reminder_rule.target_type IS 'Entity type: PROPERTY, TENANCY, COMPLIANCE_CERT, RENT_PAYMENT, etc.';
COMMENT ON COLUMN reminder_rule.reminder_type IS 'Reminder trigger: CERT_EXPIRY, RENT_OVERDUE, INSPECTION_DUE, etc.';

-- ---------------------------------------------------------------------------
-- reminder_instance
-- Scheduled reminder instances generated from rules; one per due_date.
-- ---------------------------------------------------------------------------
CREATE TABLE reminder_instance (
    id              UUID         NOT NULL DEFAULT gen_random_uuid(),
    reminder_rule_id UUID        NOT NULL,
    due_date        DATE         NOT NULL,
    status          VARCHAR(30)  NOT NULL DEFAULT 'PENDING',
    sent_at         TIMESTAMPTZ,
    snoozed_until   DATE,
    completed_at    TIMESTAMPTZ,

    CONSTRAINT pk_reminder_instance           PRIMARY KEY (id),
    CONSTRAINT fk_reminder_instance_rule     FOREIGN KEY (reminder_rule_id) REFERENCES reminder_rule (id),
    CONSTRAINT uq_reminder_instance           UNIQUE (reminder_rule_id, due_date),
    CONSTRAINT chk_reminder_instance_status   CHECK (status IN ('PENDING','SENT','SNOOZED','COMPLETED','FAILED'))
);

COMMENT ON TABLE  reminder_instance        IS 'Scheduled reminder instance; statuses: PENDING, SENT, SNOOZED, COMPLETED, FAILED.';

CREATE INDEX ix_reminder_instance_pending   ON reminder_instance (due_date) WHERE status = 'PENDING';

-- =============================================================================
-- End of V1__init_schema.sql
-- =============================================================================
