Domain Model & Database Design — Rental Management System

Comprehensive domain model and PostgreSQL database design for a family-use rental property management system. Extends the existing V1 foundation (app\_user, property, tenancy, tenant, audit\_event) to cover property ownership (SCD Type 2), agency agreements, rent schedules/payments, income, expenses with owner allocation, agent fee schedules and statement reconciliation, contractors and work orders, compliance certificates, documents (S3 metadata), inspections, correspondence, legal notices, tenancy deposits, tax year reporting, reminders, and self-assessment packs. **32 tables** across 6 Spring modules.

# Confirmed Technology Decisions

| **Decision** | **Value** |
| --- | --- |
| Language / Framework | Java 25, Spring Boot 4.1.0, Maven |
| Database | PostgreSQL 16 with btree\_gist, pgcrypto, pg\_trgm extensions |
| Persistence | JPA / Hibernate, Flyway migrations |
| File Storage | AWS S3 (binaries); PostgreSQL holds metadata only |
| Deployment | K3s homelab; no Spring Cloud, no microservices |
| Module layout | rental-shared → rental-identity → rental-core → rental-document → rental-tax → rental-app |
| Money | NUMERIC(12,2) everywhere; no floating point |
| Percentages | NUMERIC(5,2) for ownership; NUMERIC(7,4) for fee rates |
| Audit | Append-only audit\_event table; no enforcing triggers yet |
| Roles | ADMIN > LANDLORD > ACCOUNTANT > FAMILY\_VIEWER |
| Optimistic locking | version BIGINT NOT NULL DEFAULT 0 on every mutable aggregate |
| New enums | VARCHAR(n) + CHECK constraint (not PostgreSQL CREATE TYPE) |
| Existing enums | Keep V1 PostgreSQL CREATE TYPE enums (user\_role, property\_type, tenancy\_status) |
| Soft-delete | active BOOLEAN NOT NULL DEFAULT TRUE + optional deactivated\_at TIMESTAMPTZ (consistent with V1 pattern) |
| PKs | UUID with gen\_random\_uuid() |
| Timestamps | TIMESTAMPTZ (UTC) |
| Tax year | UK fiscal year: 6 April – 5 April |

## Resolved Design Questions

1. **Agent statement reconciliation**: Semi-automated with suggestions — system proposes matches by amount/date; user confirms or overrides.
2. **Reminder channels**: One channel per rule; users create multiple rules for multiple channels (EMAIL, SMS, NTFY, IN\_APP).
3. **Expense category extensibility**: CHECK constraint (25 categories); migrate to reference table only if >30 categories or non-developer users need to add categories.

# Goals

* Define bounded contexts and map every aggregate root to its Spring module
* Specify every new table with columns, PostgreSQL types, constraints, defaults, nullability, and descriptions
* Extend V1 tables (app\_user, property, tenancy, tenant, audit\_event) with identified gaps (version, idp\_issuer, GiST overlap constraint)
* Model joint property ownership with percentage history (SCD Type 2)
* Design a complete financial ledger (income, expenses, agent fees, rent payments) suitable for UK self-assessment
* Design polymorphic document linking with S3 metadata storage
* Define index strategy for all query patterns (free-text search, date range, FK lookups, compliance alerts)
* Establish cross-cutting conventions: audit columns, optimistic locking, soft-delete, money types
* Identify reporting anchors for self-assessment, HMRC queries, and agent fee reconciliation
* Ensure extensibility to multi-property portfolio without schema rewrites

# Bounded Contexts & Module Placement

| **Module** | **Aggregate Roots** | **Justification** |
| --- | --- | --- |
| **rental-shared** | AuditEvent, Auditable base | Cross-cutting: audit, enums, money utils, error types |
| **rental-identity** | AppUser | Keycloak JIT sync, roles, identity anchoring |
| **rental-core** | Property, PropertyOwner, AgencyAgreement, AgentFeeSchedule, Tenancy (w/ Tenant, TenancyDeposit), RentSchedule, RentPayment, IncomeLine, Expense (w/ ExpenseAllocation), Contractor, WorkOrder, ComplianceCertificate, Inspection (w/ InspectionItem), Correspondence, LegalNotice, AgentStatement (w/ AgentStatementLine), ReminderRule (w/ ReminderInstance) | Core domain — property, tenancy, finance, maintenance, compliance, agency, reminders |
| **rental-document** | Document (w/ DocumentVersion, DocumentLink) | Document lifecycle, S3 interaction, OCR status, search vectors |
| **rental-tax** | TaxYear, TaxYearSummary, SelfAssessmentPack | Tax reporting, SA105 mapping, year locking |
| **rental-app** | — | Boot main, Flyway migrations, config, composition root |

## Module Dependency Graph

rental-shared (base — no upward dependencies)

↑

rental-identity (depends on shared)

↑

rental-core (depends on shared, identity)

↑

rental-document (depends on shared, identity)

↑

rental-tax (depends on shared, identity, core)

↑

rental-app (composition root — depends on all)

New Maven modules to add to parent POM: rental-document, rental-tax.

# Domain Model by Bounded Context

## Context 1: Identity & Users

**Aggregate root**: AppUser

AppUser (rental-identity)

├── id : UUID [PK]

├── username : VARCHAR(100) [UNIQUE]

├── display\_name : VARCHAR(200)

├── email : VARCHAR(320)

├── role : user\_role [PG ENUM]

├── active : BOOLEAN

├── idp\_issuer : VARCHAR(500) [NEW]

├── idp\_subject : VARCHAR(255)

├── version : BIGINT [NEW]

└── audit columns (created\_at, updated\_at, created\_by, updated\_by)

**Business rules enforced at DB level**:

* UNIQUE(idp\_issuer, idp\_subject) — replaces V1's UNIQUE(idp\_subject) to handle multi-realm
* UNIQUE(username) — retained
* role is a PostgreSQL enum (existing V1)

## Context 2: Property & Ownership

**Aggregate roots**: Property, PropertyOwner, AgencyAgreement, AgentFeeSchedule

Property (rental-core) PropertyOwner (SCD Type 2)

├── id : UUID [PK] ├── id : UUID [PK]

├── property\_reference [UNIQUE] ├── property\_id → Property

├── address fields ├── owner\_id → AppUser

├── property\_type : PG ENUM ├── ownership\_pct : NUMERIC(5,2)

├── purchase\_date / purchase\_price ├── effective\_from : DATE

├── ownership\_percentage [DEPRECATED] ├── effective\_to : DATE (NULL=current)

├── active : BOOLEAN └── version, audit columns

├── version : BIGINT [NEW]

├── audit columns AgencyAgreement

└── tenancies[] ├── id : UUID [PK]

├── property\_id → Property

AgentFeeSchedule ├── agency\_name, contact, email, phone

├── id : UUID [PK] ├── management\_type : VARCHAR(30)

├── property\_id → Property ├── fee\_percentage, fee\_fixed

├── fee\_type : VARCHAR(50) ├── agreement\_start / agreement\_end

├── value : NUMERIC(7,4) ├── notice\_period\_days

├── effective\_from / effective\_to ├── active : BOOLEAN

└── version, audit columns └── version, audit columns

**Business rules**:

* Sum of ownership\_pct for current owners (effective\_to IS NULL) of a property must equal 100 — enforced in application layer
* property.ownership\_percentage is deprecated; application reads from property\_owner but column retained during migration window
* UNIQUE(property\_id, owner\_id, effective\_from) on property\_owner
* UNIQUE(property\_id, fee\_type, effective\_from) on agent\_fee\_schedule

## Context 3: Tenancy & Rent

**Aggregate roots**: Tenancy (with child entities Tenant, TenancyDeposit), RentSchedule, RentPayment

Tenancy (rental-core) Tenant

├── id : UUID [PK] ├── id : UUID [PK]

├── property\_id → Property ├── tenancy\_id → Tenancy

├── start\_date / end\_date ├── full\_name, email, phone

├── monthly\_rent : NUMERIC(12,2) ├── move\_in\_date / move\_out\_date

├── payment\_day : SMALLINT ├── emergency contact fields

├── status : tenancy\_status [PG ENUM] ├── version : BIGINT [NEW]

├── deposit fields [DEPRECATED] └── audit columns

├── version : BIGINT [NEW]

├── audit columns TenancyDeposit (1:1 with Tenancy)

└── tenants[] ├── id : UUID [PK]

├── tenancy\_id → Tenancy [UNIQUE]

RentSchedule ├── amount : NUMERIC(12,2)

├── id : UUID [PK] ├── scheme : VARCHAR(30)

├── tenancy\_id → Tenancy ├── scheme\_reference

├── monthly\_rent : NUMERIC(12,2) ├── registered\_date / returned\_date

├── effective\_from / effective\_to ├── returned\_amount / deductions

└── version, audit columns ├── deduction\_reason

├── status : VARCHAR(20)

RentPayment └── version, audit columns

├── id : UUID [PK]

├── tenancy\_id → Tenancy

├── due\_date, amount\_due, amount\_paid

├── paid\_date, payment\_method

├── status : VARCHAR(20)

└── version, audit columns

**Business rules at DB level**:

* GiST exclusion constraint on tenancy: no overlapping non-ended tenancies per property

EXCLUDE USING gist (

property\_id WITH =,

daterange(start\_date, COALESCE(end\_date, '9999-12-31'::date), '[)') WITH &&

) WHERE (status NOT IN ('ENDED','CANCELLED'))

* CHECK (end\_date IS NULL OR end\_date > start\_date) on tenancy
* UNIQUE(tenancy\_id) on tenancy\_deposit — one deposit per tenancy
* UNIQUE(tenancy\_id, effective\_from) on rent\_schedule
* Status machines enforced in application layer, transitions audited
* tenancy.monthly\_rent and tenancy.deposit\_\* columns retained; rent\_schedule and tenancy\_deposit provide the full-fidelity records. Application keeps tenancy.monthly\_rent in sync with the latest rent\_schedule entry.

## Context 4: Finance (Income, Expenses, Agent Reconciliation)

**Aggregate roots**: IncomeLine, Expense (with child ExpenseAllocation), AgentStatement (with child AgentStatementLine)

IncomeLine Expense

├── id : UUID [PK] ├── id : UUID [PK]

├── property\_id → Property ├── property\_id → Property

├── tenancy\_id → Tenancy (nullable) ├── category : VARCHAR(50) [25 categories]

├── category : VARCHAR(50) ├── amount : NUMERIC(12,2)

├── amount : NUMERIC(12,2) ├── expense\_date : DATE

├── received\_date : DATE ├── payee, description

├── description, tax\_year ├── tax\_classification : VARCHAR(20)

├── active : BOOLEAN ├── tax\_deductible : BOOLEAN

└── version, audit columns ├── tax\_year : VARCHAR(7)

├── vat\_amount : NUMERIC(12,2)

ExpenseAllocation ├── owner\_id → AppUser (nullable=joint)

├── id : UUID [PK] ├── work\_order\_id → WorkOrder (nullable)

├── expense\_id → Expense ├── approval\_status : VARCHAR(20)

├── owner\_id → AppUser ├── active : BOOLEAN

├── allocated\_amount : NUMERIC(12,2) ├── deactivated\_at : TIMESTAMPTZ

└── created\_at, created\_by └── version, audit columns

AgentStatement AgentStatementLine

├── id : UUID [PK] ├── id : UUID [PK]

├── agency\_agreement\_id → AgencyAgr. ├── agent\_statement\_id → AgentStatement

├── property\_id → Property ├── transaction\_date, description

├── statement\_period\_start/end ├── amount : NUMERIC(12,2) [signed]

├── gross\_rent, management\_fee ├── line\_type : VARCHAR(30)

├── other\_deductions, net\_amount ├── matched\_income\_id → IncomeLine

├── status : VARCHAR(30) ├── matched\_expense\_id → Expense

└── version, audit columns ├── reconciliation\_status : VARCHAR(30)

│ (UNMATCHED/MATCHED/IGNORED/REVIEW\_REQUIRED)

├── match\_confidence : NUMERIC(3,2) [NEW]

│ (0.00-1.00, system suggestion score)

└── created\_at, created\_by

**Business rules**:

* Expense categories (25): AGENT\_MANAGEMENT\_FEE, AGENT\_LETTING\_FEE, AGENT\_RENEWAL\_FEE, ADMIN\_FEE, PAT\_TEST, GAS\_SAFETY\_CERT, EICR, EPC, FIRE\_ALARM\_TEST, EMERGENCY\_LIGHTING\_TEST, LEGIONELLA\_RISK, REPAIR, MAINTENANCE, PROFESSIONAL\_CLEANING, LEGAL\_FEES, INSURANCE, MORTGAGE\_INTEREST, ACCOUNTANCY\_FEES, ADVERTISING, COUNCIL\_TAX, UTILITIES, GROUND\_RENT, SERVICE\_CHARGE, TRAVEL, OTHER
* Tax classifications: REVENUE, CAPITAL, PRIVATE, FINANCE, UNKNOWN — kept distinct, never silently inferred
* Only approval\_status = 'APPROVED' expenses feed tax calculations
* expense\_allocation: If no rows exist for an expense, default split is per property\_owner current percentages. If rows exist, they must sum to expense.amount.
* UNIQUE(expense\_id, owner\_id) on expense\_allocation
* Agent reconciliation is **semi-automated**: system suggests matches by amount ± tolerance and date proximity, populates match\_confidence; user confirms or overrides

## Context 5: Maintenance, Compliance & Inspections

**Aggregate roots**: Contractor, WorkOrder, ComplianceCertificate, Inspection (with child InspectionItem)

Contractor WorkOrder

├── id : UUID [PK] ├── id : UUID [PK]

├── name, company\_name ├── property\_id → Property

├── trade : VARCHAR(50) ├── contractor\_id → Contractor (nullable)

├── phone, email ├── title, description

├── notes ├── category, priority

├── active : BOOLEAN ├── raised\_date, scheduled\_date, completed\_date

└── version, audit columns ├── labour\_cost, materials\_cost, total\_cost

├── status : VARCHAR(20)

ComplianceCertificate ├── raised\_by\_id → AppUser

├── id : UUID [PK] └── version, audit columns

├── property\_id → Property

├── cert\_type : VARCHAR(50) Inspection

├── issue\_date, expiry\_date ├── id : UUID [PK]

├── issued\_by, certificate\_reference ├── property\_id → Property

├── is\_current : BOOLEAN ├── tenancy\_id → Tenancy (nullable)

└── version, audit columns ├── inspection\_type : VARCHAR(30)

├── scheduled\_date, conducted\_date

InspectionItem ├── conducted\_by : VARCHAR(200)

├── id : UUID [PK] ├── overall\_condition : VARCHAR(20)

├── inspection\_id → Inspection └── version, audit columns

├── room\_or\_area, description

├── condition, action\_required

├── action\_description

├── photo\_document\_id → Document

└── created\_at, created\_by

**Business rules**:

* Completed work orders can generate an expense record (linked via expense.work\_order\_id)
* Compliance certificates expiring within 60 days surface in reports and feed reminder rules
* Contractor trades (12): ELECTRICIAN, GAS\_ENGINEER, PLUMBER, GENERAL\_BUILDER, CLEANER, LOCKSMITH, GLAZIER, ROOFER, PAINTER, CARPET\_FITTER, GARDENER, OTHER
* Work order statuses: OPEN → SCHEDULED → IN\_PROGRESS → COMPLETED | CANCELLED

## Context 6: Communication & Legal

**Aggregate roots**: Correspondence, LegalNotice

Correspondence LegalNotice

├── id : UUID [PK] ├── id : UUID [PK]

├── property\_id → Property ├── property\_id → Property

├── tenancy\_id → Tenancy (nullable) ├── tenancy\_id → Tenancy (nullable)

├── direction : INBOUND/OUTBOUND ├── notice\_type : VARCHAR(50)

├── channel : EMAIL/LETTER/SMS/ ├── served\_date, effective\_date

│ PORTAL/PHONE ├── response\_due\_date

├── subject, summary ├── status : VARCHAR(30)

├── correspondence\_date └── version, audit columns

├── from\_party, to\_party

├── is\_legal : BOOLEAN

└── version, audit columns

**Business rules**:

* Correspondence and legal notices link to documents via document\_link
* Legal notice statuses: DRAFT → SERVED → ACKNOWLEDGED | EXPIRED | WITHDRAWN | DISPUTED

## Context 7: Documents (rental-document module)

**Aggregate root**: Document (with children DocumentVersion, DocumentLink)

Document DocumentVersion

├── id : UUID [PK] ├── id : UUID [PK]

├── display\_name ├── document\_id → Document

├── original\_filename ├── version\_number : INT

├── s3\_bucket, s3\_key ├── s3\_key

├── content\_type, size\_bytes ├── size\_bytes, sha256\_hash

├── sha256\_hash ├── uploaded\_at, uploaded\_by\_id

├── uploaded\_at, uploaded\_by\_id └── UNIQUE(document\_id, version\_number)

├── description

├── document\_type : VARCHAR(50) DocumentLink (polymorphic join)

├── supplier\_name ├── id : UUID [PK]

├── extracted\_text ├── document\_id → Document [FK CASCADE]

├── upload\_status : VARCHAR(30) ├── entity\_type : VARCHAR(50)

├── search\_vector : TSVECTOR [GEN] ├── entity\_id : UUID (no FK)

├── active : BOOLEAN ├── relationship : VARCHAR(50)

├── deactivated\_at ├── created\_at, created\_by

└── version, audit columns └── UNIQUE(document\_id, entity\_type, entity\_id)

**Upload status state machine**:

UPLOADING → AVAILABLE → OCR\_PENDING → OCR\_PROCESSING → SEARCHABLE

↘ OCR\_FAILED

UPLOADING → UPLOAD\_FAILED

**Document types** (21): RECEIPT, INVOICE, LEASE\_AGREEMENT, GAS\_CERTIFICATE, EICR, EPC, PAT\_REPORT, FIRE\_ALARM\_REPORT, EMERGENCY\_LIGHTING\_REPORT, INSPECTION\_REPORT, CORRESPONDENCE, LEGAL, BANK\_STATEMENT, TAX\_DOCUMENT, CONTRACTOR\_QUOTE, CONTRACTOR\_INVOICE, PHOTO, AGENT\_STATEMENT, INSURANCE\_POLICY, MORTGAGE\_DOCUMENT, OTHER

**Linkable entity types** (14): PROPERTY, EXPENSE, WORK\_ORDER, COMPLIANCE\_CERT, TENANCY, INCOME\_LINE, CONTRACTOR, TAX\_PACK, CORRESPONDENCE, INSPECTION, LEGAL\_NOTICE, RENT\_PAYMENT, AGENCY\_AGREEMENT, AGENT\_STATEMENT

**Relationship types**: SUPPORTS, EVIDENCE\_FOR, ATTACHED\_TO, SOURCE\_OF

**Orphan mitigation**: Application-layer existence check on link creation; scheduled consistency-check job compares entity\_ids against target tables.

## Context 8: Tax & Self-Assessment (rental-tax module)

**Aggregate roots**: TaxYear, TaxYearSummary, SelfAssessmentPack

TaxYear TaxYearSummary

├── id : UUID [PK] ├── id : UUID [PK]

├── tax\_year\_label : VARCHAR(7) [UQ] ├── property\_id → Property

│ e.g. '2025-26' ├── tax\_year\_id → TaxYear

├── start\_date : DATE (6 April) ├── owner\_id → AppUser

├── end\_date : DATE (5 April) ├── gross\_income : NUMERIC(12,2)

├── status : OPEN/CLOSED/FILED ├── allowable\_expenses : NUMERIC(12,2)

├── locked\_at, locked\_by\_id ├── finance\_costs : NUMERIC(12,2)

├── unlock\_reason ├── capital\_expenses : NUMERIC(12,2)

└── version, audit columns ├── net\_profit : NUMERIC(12,2)

├── owner\_share\_pct : NUMERIC(5,2)

SelfAssessmentPack ├── owner\_net\_profit : NUMERIC(12,2)

├── id : UUID [PK] ├── personal\_allowance\_used : NUMERIC(12,2)

├── tax\_year\_id → TaxYear ├── tax\_due : NUMERIC(12,2)

├── owner\_id → AppUser ├── is\_draft : BOOLEAN

├── generated\_at ├── UNIQUE(property\_id, tax\_year\_id, owner\_id)

├── status : DRAFT/READY/SUBMITTED └── version, audit columns

├── submission\_reference

├── generated\_by\_id → AppUser

├── UNIQUE(tax\_year\_id, owner\_id)

└── version, audit columns

**Business rules**:

* Tax year locking: OPEN → CLOSED requires explicit user action and audit event; CLOSED → OPEN requires unlock\_reason, user identity, and audit event
* Summary rows always is\_draft = TRUE until explicitly reviewed
* Recalculation triggered on any approved income/expense change within the tax year
* Only approval\_status = 'APPROVED' income and expenses are included
* UNKNOWN-classified expenses appear as exceptions in the report, not in totals

## Context 9: Reminders

**Aggregate root**: ReminderRule (with child ReminderInstance)

ReminderRule ReminderInstance

├── id : UUID [PK] ├── id : UUID [PK]

├── target\_type : VARCHAR(50) ├── reminder\_rule\_id → ReminderRule

├── target\_id : UUID ├── due\_date : DATE

├── reminder\_type : VARCHAR(50) ├── status : PENDING/SENT/SNOOZED/

├── days\_before : INT │ COMPLETED/FAILED

├── recurrence : VARCHAR(30) ├── sent\_at, snoozed\_until, completed\_at

├── channel : VARCHAR(30) └── UNIQUE(reminder\_rule\_id, due\_date)

├── enabled : BOOLEAN

├── recipient : VARCHAR(320)

└── created\_at, created\_by

**Channels**: IN\_APP, EMAIL, SMS, NTFY
**Recurrence**: ONCE, DAILY, WEEKLY, MONTHLY, ANNUALLY
**Multi-channel**: Create one rule per channel. E.g., gas safety expiry → one EMAIL rule + one NTFY rule.

# Design — Full Database Schema

## V1 Schema Extensions (Migration V2)

### app\_user — ADD columns

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| idp\_issuer | VARCHAR(500) | NULL |  |  | Keycloak realm issuer URL |
| version | BIGINT | NOT NULL | 0 |  | Optimistic lock |

* **DROP**: UNIQUE(idp\_subject) → **ADD**: UNIQUE(idp\_issuer, idp\_subject)
* **Backfill**: UPDATE app\_user SET idp\_issuer = 'https://auth.homelab.internal/realms/rental' WHERE idp\_subject IS NOT NULL

### property — ADD column

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| version | BIGINT | NOT NULL | 0 |  | Optimistic lock |

Note: ownership\_percentage retained but deprecated. Application reads from property\_owner.

### tenancy — ADD column + constraint

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| version | BIGINT | NOT NULL | 0 |  | Optimistic lock |

* **ADD extension**: CREATE EXTENSION IF NOT EXISTS btree\_gist
* **ADD exclusion constraint**:

EXCLUDE USING gist (

property\_id WITH =,

daterange(start\_date, COALESCE(end\_date, '9999-12-31'::date), '[)') WITH &&

) WHERE (status NOT IN ('ENDED','CANCELLED'))

### tenant — ADD column

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| version | BIGINT | NOT NULL | 0 |  | Optimistic lock |

### audit\_event — ADD columns

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| entity\_type | VARCHAR(50) | NULL |  |  | Alias for aggregate\_type; backfill |
| entity\_id | UUID | NULL |  |  | Alias for aggregate\_id; backfill |

## New Table: property\_owner

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| owner\_id | UUID | NOT NULL |  | FK → app\_user(id) |  |
| ownership\_pct | NUMERIC(5,2) | NOT NULL |  | CHECK (> 0 AND <= 100) | Owner's share percentage |
| effective\_from | DATE | NOT NULL |  |  | Start of this ownership record |
| effective\_to | DATE | NULL |  | CHECK (NULL OR > effective\_from) | NULL = current |
| version | BIGINT | NOT NULL | 0 |  | Optimistic lock |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

**Unique**: (property\_id, owner\_id, effective\_from)

## New Table: agency\_agreement

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| agency\_name | VARCHAR(200) | NOT NULL |  |  | Letting agency name |
| company\_name | VARCHAR(200) | NULL |  |  | Registered company name |
| contact\_name | VARCHAR(200) | NULL |  |  | Account manager |
| email | VARCHAR(320) | NULL |  |  |  |
| phone | VARCHAR(50) | NULL |  |  |  |
| management\_type | VARCHAR(30) | NOT NULL |  | CHECK IN ('FULL\_MANAGEMENT',​'RENT\_COLLECTION',​'TENANT\_FIND',​'NONE') |  |
| fee\_percentage | NUMERIC(7,4) | NULL |  |  | Management fee % |
| fee\_fixed | NUMERIC(12,2) | NULL |  |  | Fixed fee amount |
| agreement\_start | DATE | NULL |  |  |  |
| agreement\_end | DATE | NULL |  |  |  |
| notice\_period\_days | INTEGER | NULL |  |  |  |
| notes | TEXT | NULL |  |  |  |
| active | BOOLEAN | NOT NULL | TRUE |  | Soft-delete |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: agent\_fee\_schedule

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| fee\_type | VARCHAR(50) | NOT NULL |  | CHECK IN ('MANAGEMENT\_MONTHLY\_PCT',​'LETTING\_FLAT',​'RENEWAL\_FLAT',​'LETTING\_PCT',​'RENEWAL\_PCT') |  |
| value | NUMERIC(7,4) | NOT NULL |  |  | Percentage or £ depending on type |
| effective\_from | DATE | NOT NULL |  |  |  |
| effective\_to | DATE | NULL |  |  | NULL = current |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

**Unique**: (property\_id, fee\_type, effective\_from)

## New Table: rent\_schedule

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| tenancy\_id | UUID | NOT NULL |  | FK → tenancy(id) |  |
| monthly\_rent | NUMERIC(12,2) | NOT NULL |  | CHECK (>= 0) | Agreed rent for this period |
| effective\_from | DATE | NOT NULL |  |  |  |
| effective\_to | DATE | NULL |  |  | NULL = current rate |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

**Unique**: (tenancy\_id, effective\_from)

## New Table: rent\_payment

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| tenancy\_id | UUID | NOT NULL |  | FK → tenancy(id) |  |
| due\_date | DATE | NOT NULL |  |  |  |
| amount\_due | NUMERIC(12,2) | NOT NULL |  | CHECK (>= 0) |  |
| amount\_paid | NUMERIC(12,2) | NULL |  | CHECK (NULL OR >= 0) |  |
| paid\_date | DATE | NULL |  |  |  |
| payment\_method | VARCHAR(50) | NULL |  |  | Free text |
| status | VARCHAR(20) | NOT NULL | 'PENDING' | CHECK IN ('PENDING',​'PAID',​'PARTIAL',​'LATE',​'WAIVED') |  |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: income\_line

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| tenancy\_id | UUID | NULL |  | FK → tenancy(id) | Nullable for non-tenancy income |
| category | VARCHAR(50) | NOT NULL |  | CHECK IN ('RENT',​'HOLDING\_DEPOSIT',​'DEPOSIT',​'RENT\_GUARANTEE',​'INSURANCE\_CLAIM',​'OTHER') |  |
| amount | NUMERIC(12,2) | NOT NULL |  | CHECK (>= 0) |  |
| received\_date | DATE | NOT NULL |  |  |  |
| description | TEXT | NULL |  |  |  |
| tax\_year | VARCHAR(7) | NULL |  |  | e.g. '2025-26' |
| active | BOOLEAN | NOT NULL | TRUE |  | Soft-delete |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: expense

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| category | VARCHAR(50) | NOT NULL |  | CHECK IN ('AGENT\_MANAGEMENT\_FEE',​'AGENT\_LETTING\_FEE',​'AGENT\_RENEWAL\_FEE',​'ADMIN\_FEE',​'PAT\_TEST',​'GAS\_SAFETY\_CERT',​'EICR',​'EPC',​'FIRE\_ALARM\_TEST',​'EMERGENCY\_LIGHTING\_TEST',​'LEGIONELLA\_RISK',​'REPAIR',​'MAINTENANCE',​'PROFESSIONAL\_CLEANING',​'LEGAL\_FEES',​'INSURANCE',​'MORTGAGE\_INTEREST',​'ACCOUNTANCY\_FEES',​'ADVERTISING',​'COUNCIL\_TAX',​'UTILITIES',​'GROUND\_RENT',​'SERVICE\_CHARGE',​'TRAVEL',​'OTHER') |  |
| amount | NUMERIC(12,2) | NOT NULL |  | CHECK (>= 0) |  |
| expense\_date | DATE | NOT NULL |  |  |  |
| payee | VARCHAR(200) | NULL |  |  |  |
| description | TEXT | NULL |  |  |  |
| tax\_classification | VARCHAR(20) | NOT NULL | 'UNKNOWN' | CHECK IN ('REVENUE',​'CAPITAL',​'PRIVATE',​'FINANCE',​'UNKNOWN') | SA105 classification |
| tax\_deductible | BOOLEAN | NOT NULL | TRUE |  |  |
| tax\_year | VARCHAR(7) | NULL |  |  | e.g. '2025-26' |
| vat\_amount | NUMERIC(12,2) | NULL |  |  |  |
| owner\_id | UUID | NULL |  | FK → app\_user(id) | NULL = joint expense |
| work\_order\_id | UUID | NULL |  | FK → work\_order(id) | Links to generating work order |
| approval\_status | VARCHAR(20) | NOT NULL | 'PENDING' | CHECK IN ('PENDING',​'APPROVED',​'REJECTED',​'VOIDED') |  |
| active | BOOLEAN | NOT NULL | TRUE |  | Soft-delete |
| deactivated\_at | TIMESTAMPTZ | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: expense\_allocation

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| expense\_id | UUID | NOT NULL |  | FK → expense(id) |  |
| owner\_id | UUID | NOT NULL |  | FK → app\_user(id) |  |
| allocated\_amount | NUMERIC(12,2) | NOT NULL |  | CHECK (>= 0) |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |

**Unique**: (expense\_id, owner\_id)
**Rule**: If no rows exist for an expense, default split follows property\_owner current percentages. If rows exist, they override and must sum to expense.amount (application-enforced).

## New Table: contractor

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| name | VARCHAR(200) | NOT NULL |  |  |  |
| company\_name | VARCHAR(200) | NULL |  |  |  |
| trade | VARCHAR(50) | NOT NULL |  | CHECK IN ('ELECTRICIAN',​'GAS\_ENGINEER',​'PLUMBER',​'GENERAL\_BUILDER',​'CLEANER',​'LOCKSMITH',​'GLAZIER',​'ROOFER',​'PAINTER',​'CARPET\_FITTER',​'GARDENER',​'OTHER') |  |
| phone | VARCHAR(50) | NULL |  |  |  |
| email | VARCHAR(320) | NULL |  |  |  |
| notes | TEXT | NULL |  |  |  |
| active | BOOLEAN | NOT NULL | TRUE |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: work\_order

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| contractor\_id | UUID | NULL |  | FK → contractor(id) | Unassigned initially |
| title | VARCHAR(300) | NOT NULL |  |  |  |
| description | TEXT | NULL |  |  |  |
| category | VARCHAR(30) | NOT NULL |  | CHECK IN ('REPAIR',​'MAINTENANCE',​'COMPLIANCE',​'INSPECTION',​'EMERGENCY',​'IMPROVEMENT') |  |
| priority | VARCHAR(20) | NULL |  | CHECK IN ('EMERGENCY',​'URGENT',​'ROUTINE',​'COSMETIC') |  |
| raised\_date | DATE | NOT NULL | CURRENT\_DATE |  |  |
| scheduled\_date | DATE | NULL |  |  |  |
| completed\_date | DATE | NULL |  |  |  |
| labour\_cost | NUMERIC(12,2) | NULL |  |  |  |
| materials\_cost | NUMERIC(12,2) | NULL |  |  |  |
| total\_cost | NUMERIC(12,2) | NULL |  |  |  |
| status | VARCHAR(20) | NOT NULL | 'OPEN' | CHECK IN ('OPEN',​'SCHEDULED',​'IN\_PROGRESS',​'COMPLETED',​'CANCELLED') |  |
| raised\_by\_id | UUID | NULL |  | FK → app\_user(id) |  |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: compliance\_certificate

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| cert\_type | VARCHAR(50) | NOT NULL |  | CHECK IN ('GAS\_SAFETY',​'EICR',​'EPC',​'PAT\_TEST',​'FIRE\_ALARM',​'EMERGENCY\_LIGHTING',​'LEGIONELLA\_RISK',​'HMO\_LICENCE',​'SELECTIVE\_LICENCE',​'SMOKE\_ALARM',​'CO\_ALARM',​'BOILER\_SERVICE',​'INSURANCE',​'PROPERTY\_INSPECTION',​'OTHER') |  |
| issue\_date | DATE | NULL |  |  |  |
| expiry\_date | DATE | NULL |  |  |  |
| issued\_by | VARCHAR(200) | NULL |  |  |  |
| certificate\_reference | VARCHAR(200) | NULL |  |  |  |
| is\_current | BOOLEAN | NOT NULL | TRUE |  |  |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: document

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| display\_name | VARCHAR(500) | NOT NULL |  |  | User-facing name |
| original\_filename | VARCHAR(500) | NULL |  |  | As uploaded |
| s3\_bucket | VARCHAR(200) | NOT NULL |  |  |  |
| s3\_key | VARCHAR(1000) | NOT NULL |  |  |  |
| content\_type | VARCHAR(200) | NULL |  |  | MIME type |
| size\_bytes | BIGINT | NULL |  |  |  |
| sha256\_hash | VARCHAR(64) | NULL |  |  | Duplicate detection |
| uploaded\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| uploaded\_by\_id | UUID | NULL |  | FK → app\_user(id) |  |
| description | TEXT | NULL |  |  |  |
| document\_type | VARCHAR(50) | NOT NULL |  | CHECK IN ('RECEIPT',​'INVOICE',​'LEASE\_AGREEMENT',​'GAS\_CERTIFICATE',​'EICR',​'EPC',​'PAT\_REPORT',​'FIRE\_ALARM\_REPORT',​'EMERGENCY\_LIGHTING\_REPORT',​'INSPECTION\_REPORT',​'CORRESPONDENCE',​'LEGAL',​'BANK\_STATEMENT',​'TAX\_DOCUMENT',​'CONTRACTOR\_QUOTE',​'CONTRACTOR\_INVOICE',​'PHOTO',​'AGENT\_STATEMENT',​'INSURANCE\_POLICY',​'MORTGAGE\_DOCUMENT',​'OTHER') |  |
| supplier\_name | VARCHAR(200) | NULL |  |  | OCR-suggested or manual |
| extracted\_text | TEXT | NULL |  |  | OCR output |
| upload\_status | VARCHAR(30) | NOT NULL | 'UPLOADING' | CHECK IN ('UPLOADING',​'AVAILABLE',​'OCR\_PENDING',​'OCR\_PROCESSING',​'SEARCHABLE',​'UPLOAD\_FAILED',​'OCR\_FAILED') |  |
| search\_vector | TSVECTOR | NOT NULL |  | GENERATED ALWAYS AS (to\_tsvector('english', coalesce(display\_name,​'') || ' ' || coalesce(original\_filename,​'') || ' ' || coalesce(document\_type,​'') || ' ' || coalesce(supplier\_name,​'') || ' ' || coalesce(extracted\_text,​''))) STORED | Full-text search |
| active | BOOLEAN | NOT NULL | TRUE |  | Soft-delete |
| deactivated\_at | TIMESTAMPTZ | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: document\_version

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| document\_id | UUID | NOT NULL |  | FK → document(id) |  |
| version\_number | INTEGER | NOT NULL |  |  | 1, 2, 3... |
| s3\_key | VARCHAR(1000) | NOT NULL |  |  |  |
| size\_bytes | BIGINT | NULL |  |  |  |
| sha256\_hash | VARCHAR(64) | NULL |  |  |  |
| uploaded\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| uploaded\_by\_id | UUID | NULL |  | FK → app\_user(id) |  |

**Unique**: (document\_id, version\_number)

## New Table: document\_link

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| document\_id | UUID | NOT NULL |  | FK → document(id) ON DELETE CASCADE |  |
| entity\_type | VARCHAR(50) | NOT NULL |  | CHECK IN ('PROPERTY',​'EXPENSE',​'WORK\_ORDER',​'COMPLIANCE\_CERT',​'TENANCY',​'INCOME\_LINE',​'CONTRACTOR',​'TAX\_PACK',​'CORRESPONDENCE',​'INSPECTION',​'LEGAL\_NOTICE',​'RENT\_PAYMENT',​'AGENCY\_AGREEMENT',​'AGENT\_STATEMENT') | Target entity type |
| entity\_id | UUID | NOT NULL |  |  | Target entity PK (no FK — polymorphic) |
| relationship | VARCHAR(50) | NOT NULL | 'ATTACHED\_TO' | CHECK IN ('SUPPORTS',​'EVIDENCE\_FOR',​'ATTACHED\_TO',​'SOURCE\_OF') |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |

**Unique**: (document\_id, entity\_type, entity\_id) — prevent duplicate links

## New Table: correspondence

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| tenancy\_id | UUID | NULL |  | FK → tenancy(id) |  |
| direction | VARCHAR(10) | NOT NULL |  | CHECK IN ('INBOUND',​'OUTBOUND') |  |
| channel | VARCHAR(20) | NOT NULL |  | CHECK IN ('EMAIL',​'LETTER',​'SMS',​'PORTAL',​'PHONE') |  |
| subject | VARCHAR(500) | NULL |  |  |  |
| summary | TEXT | NULL |  |  |  |
| correspondence\_date | DATE | NOT NULL |  |  |  |
| from\_party | VARCHAR(200) | NULL |  |  |  |
| to\_party | VARCHAR(200) | NULL |  |  |  |
| is\_legal | BOOLEAN | NOT NULL | FALSE |  |  |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: legal\_notice

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| tenancy\_id | UUID | NULL |  | FK → tenancy(id) |  |
| notice\_type | VARCHAR(50) | NOT NULL |  | CHECK IN ('SECTION\_21',​'SECTION\_8',​'DEPOSIT\_PRESCRIBED\_INFO',​'RENT\_INCREASE',​'INSPECTION\_NOTICE',​'NOTICE\_TO\_QUIT',​'OTHER') |  |
| served\_date | DATE | NULL |  |  |  |
| effective\_date | DATE | NULL |  |  |  |
| response\_due\_date | DATE | NULL |  |  |  |
| status | VARCHAR(30) | NOT NULL | 'DRAFT' | CHECK IN ('DRAFT',​'SERVED',​'ACKNOWLEDGED',​'EXPIRED',​'WITHDRAWN',​'DISPUTED') |  |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: inspection

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| tenancy\_id | UUID | NULL |  | FK → tenancy(id) |  |
| inspection\_type | VARCHAR(30) | NOT NULL |  | CHECK IN ('MOVE\_IN',​'PERIODIC',​'MOVE\_OUT',​'EMERGENCY',​'PRE\_LETTING') |  |
| scheduled\_date | DATE | NULL |  |  |  |
| conducted\_date | DATE | NULL |  |  |  |
| conducted\_by | VARCHAR(200) | NULL |  |  | Agent name or owner |
| overall\_condition | VARCHAR(20) | NULL |  | CHECK IN ('EXCELLENT',​'GOOD',​'FAIR',​'POOR') |  |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: inspection\_item

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| inspection\_id | UUID | NOT NULL |  | FK → inspection(id) ON DELETE CASCADE |  |
| room\_or\_area | VARCHAR(200) | NOT NULL |  |  |  |
| description | TEXT | NULL |  |  |  |
| condition | VARCHAR(20) | NULL |  | CHECK IN ('EXCELLENT',​'GOOD',​'FAIR',​'POOR',​'DAMAGED',​'MISSING') |  |
| action\_required | BOOLEAN | NOT NULL | FALSE |  |  |
| action\_description | TEXT | NULL |  |  |  |
| photo\_document\_id | UUID | NULL |  | FK → document(id) |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |

## New Table: tenancy\_deposit

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| tenancy\_id | UUID | NOT NULL |  | FK → tenancy(id), UNIQUE | One deposit per tenancy |
| amount | NUMERIC(12,2) | NOT NULL |  | CHECK (>= 0) |  |
| scheme | VARCHAR(30) | NOT NULL |  | CHECK IN ('DPS',​'TDS',​'MYDEPOSITS',​'NONE') |  |
| scheme\_reference | VARCHAR(200) | NULL |  |  |  |
| registered\_date | DATE | NULL |  |  |  |
| returned\_date | DATE | NULL |  |  |  |
| returned\_amount | NUMERIC(12,2) | NULL |  |  |  |
| deductions | NUMERIC(12,2) | NULL |  |  |  |
| deduction\_reason | TEXT | NULL |  |  |  |
| status | VARCHAR(20) | NOT NULL | 'PENDING\_REGISTRATION' | CHECK IN ('PENDING\_REGISTRATION',​'HELD',​'RETURNED',​'DISPUTED') |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: agent\_statement

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| agency\_agreement\_id | UUID | NOT NULL |  | FK → agency\_agreement(id) |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) | Denormalized for query convenience |
| statement\_period\_start | DATE | NOT NULL |  |  |  |
| statement\_period\_end | DATE | NOT NULL |  | CHECK (> statement\_period\_start) |  |
| gross\_rent | NUMERIC(12,2) | NULL |  |  |  |
| management\_fee | NUMERIC(12,2) | NULL |  |  |  |
| other\_deductions | NUMERIC(12,2) | NULL |  |  |  |
| net\_amount | NUMERIC(12,2) | NULL |  |  |  |
| status | VARCHAR(30) | NOT NULL | 'UPLOADED' | CHECK IN ('UPLOADED',​'RECONCILED',​'PARTIALLY\_RECONCILED',​'DISPUTED') |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: agent\_statement\_line

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| agent\_statement\_id | UUID | NOT NULL |  | FK → agent\_statement(id) ON DELETE CASCADE |  |
| transaction\_date | DATE | NOT NULL |  |  |  |
| description | TEXT | NULL |  |  |  |
| amount | NUMERIC(12,2) | NOT NULL |  |  | Signed: positive=income, negative=deduction |
| line\_type | VARCHAR(30) | NOT NULL |  | CHECK IN ('RENT',​'MANAGEMENT\_FEE',​'REPAIR',​'INSURANCE',​'OTHER\_DEDUCTION',​'TRANSFER') |  |
| matched\_income\_id | UUID | NULL |  | FK → income\_line(id) |  |
| matched\_expense\_id | UUID | NULL |  | FK → expense(id) |  |
| reconciliation\_status | VARCHAR(30) | NOT NULL | 'UNMATCHED' | CHECK IN ('UNMATCHED',​'MATCHED',​'IGNORED',​'REVIEW\_REQUIRED') |  |
| match\_confidence | NUMERIC(3,2) | NULL |  | CHECK (NULL OR BETWEEN 0 AND 1) | System suggestion score (0.00–1.00) |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |

## New Table: tax\_year

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| tax\_year\_label | VARCHAR(7) | NOT NULL |  | UNIQUE | e.g. '2025-26' |
| start\_date | DATE | NOT NULL |  |  | 6 April |
| end\_date | DATE | NOT NULL |  | CHECK (> start\_date) | 5 April next year |
| status | VARCHAR(20) | NOT NULL | 'OPEN' | CHECK IN ('OPEN',​'CLOSED',​'FILED') |  |
| locked\_at | TIMESTAMPTZ | NULL |  |  | When status changed to CLOSED |
| locked\_by\_id | UUID | NULL |  | FK → app\_user(id) | Who locked |
| unlock\_reason | TEXT | NULL |  |  | Required if reopened after lock |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

## New Table: tax\_year\_summary

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| property\_id | UUID | NOT NULL |  | FK → property(id) |  |
| tax\_year\_id | UUID | NOT NULL |  | FK → tax\_year(id) |  |
| owner\_id | UUID | NOT NULL |  | FK → app\_user(id) |  |
| gross\_income | NUMERIC(12,2) | NOT NULL | 0 |  | Sum of APPROVED income\_line |
| allowable\_expenses | NUMERIC(12,2) | NOT NULL | 0 |  | Sum of APPROVED REVENUE expenses |
| finance\_costs | NUMERIC(12,2) | NOT NULL | 0 |  | FINANCE classification |
| capital\_expenses | NUMERIC(12,2) | NOT NULL | 0 |  | CAPITAL classification |
| net\_profit | NUMERIC(12,2) | NOT NULL | 0 |  | gross\_income − allowable\_expenses |
| owner\_share\_pct | NUMERIC(5,2) | NOT NULL |  |  | Snapshot of ownership % at tax year end |
| owner\_net\_profit | NUMERIC(12,2) | NOT NULL | 0 |  | net\_profit × owner\_share\_pct / 100 |
| personal\_allowance\_used | NUMERIC(12,2) | NULL | 0 |  | User-entered |
| tax\_due | NUMERIC(12,2) | NULL | 0 |  | Calculated or user-entered |
| is\_draft | BOOLEAN | NOT NULL | TRUE |  |  |
| notes | TEXT | NULL |  |  |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

**Unique**: (property\_id, tax\_year\_id, owner\_id)

## New Table: self\_assessment\_pack

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| tax\_year\_id | UUID | NOT NULL |  | FK → tax\_year(id) |  |
| owner\_id | UUID | NOT NULL |  | FK → app\_user(id) |  |
| generated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| status | VARCHAR(20) | NOT NULL | 'DRAFT' | CHECK IN ('DRAFT',​'READY',​'SUBMITTED') |  |
| submission\_reference | VARCHAR(200) | NULL |  |  | HMRC ref if submitted externally |
| notes | TEXT | NULL |  |  |  |
| generated\_by\_id | UUID | NULL |  | FK → app\_user(id) |  |
| version | BIGINT | NOT NULL | 0 |  |  |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| updated\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |
| updated\_by | UUID | NULL |  |  |  |

**Unique**: (tax\_year\_id, owner\_id)

## New Table: reminder\_rule

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| target\_type | VARCHAR(50) | NOT NULL |  |  | Entity type being reminded about |
| target\_id | UUID | NOT NULL |  |  | Entity PK |
| reminder\_type | VARCHAR(50) | NOT NULL |  |  | e.g. 'CERT\_EXPIRY', 'RENT\_OVERDUE' |
| days\_before | INTEGER | NOT NULL |  |  | Days before due/expiry |
| recurrence | VARCHAR(30) | NOT NULL |  | CHECK IN ('ONCE',​'DAILY',​'WEEKLY',​'MONTHLY',​'ANNUALLY') |  |
| channel | VARCHAR(30) | NOT NULL |  | CHECK IN ('IN\_APP',​'EMAIL',​'SMS',​'NTFY') | One channel per rule |
| enabled | BOOLEAN | NOT NULL | TRUE |  |  |
| recipient | VARCHAR(320) | NULL |  |  | Email address / phone / ntfy topic |
| created\_at | TIMESTAMPTZ | NOT NULL | now() |  |  |
| created\_by | UUID | NULL |  |  |  |

## New Table: reminder\_instance

| **Column** | **Type** | **Nullable** | **Default** | **Constraints** | **Description** |
| --- | --- | --- | --- | --- | --- |
| id | UUID | NOT NULL | gen\_random\_uuid() | PK |  |
| reminder\_rule\_id | UUID | NOT NULL |  | FK → reminder\_rule(id) |  |
| due\_date | DATE | NOT NULL |  |  |  |
| status | VARCHAR(30) | NOT NULL | 'PENDING' | CHECK IN ('PENDING',​'SENT',​'SNOOZED',​'COMPLETED',​'FAILED') |  |
| sent\_at | TIMESTAMPTZ | NULL |  |  |  |
| snoozed\_until | DATE | NULL |  |  |  |
| completed\_at | TIMESTAMPTZ | NULL |  |  |  |

**Unique**: (reminder\_rule\_id, due\_date)

# Index Strategy

| **Table** | **Index Name** | **Type** | **Columns** | **Condition** | **Purpose** |
| --- | --- | --- | --- | --- | --- |
| property\_owner | ix\_propowner\_current | B-tree | (property\_id) | WHERE effective\_to IS NULL | Fast current-owner lookup |
| property\_owner | ix\_propowner\_owner | B-tree | (owner\_id) |  | Find all properties for an owner |
| agency\_agreement | ix\_agency\_property | B-tree | (property\_id) | WHERE active = TRUE | Active agreement per property |
| agent\_fee\_schedule | ix\_agentfee\_property | B-tree | (property\_id, fee\_type) | WHERE effective\_to IS NULL | Current fee lookup |
| rent\_schedule | ix\_rentsched\_tenancy | B-tree | (tenancy\_id, effective\_from DESC) |  | Rent history |
| rent\_payment | ix\_rentpay\_tenancy\_due | B-tree | (tenancy\_id, due\_date DESC) |  | Rent payment history |
| rent\_payment | ix\_rentpay\_status | B-tree | (status) | WHERE status NOT IN ('PAID',​'WAIVED') | Outstanding payments |
| income\_line | ix\_income\_prop\_taxyear | B-tree | (property\_id, tax\_year) | WHERE active = TRUE | Tax aggregation |
| income\_line | ix\_income\_received | B-tree | (received\_date DESC) |  | Recent income |
| expense | ix\_expense\_prop\_taxyear | B-tree | (property\_id, tax\_year) | WHERE active = TRUE | Tax aggregation |
| expense | ix\_expense\_category | B-tree | (category) |  | Category filtering |
| expense | ix\_expense\_date | B-tree | (expense\_date DESC) |  | Recent expenses |
| expense | ix\_expense\_approval | B-tree | (approval\_status) | WHERE approval\_status = 'PENDING' | Pending approvals dashboard |
| expense | ix\_expense\_workorder | B-tree | (work\_order\_id) | WHERE work\_order\_id IS NOT NULL | Work order → expense lookup |
| compliance\_certificate | ix\_compliance\_expiry | B-tree | (property\_id, cert\_type, expiry\_date) | WHERE is\_current = TRUE | Expiry alerting (60-day window) |
| document | ix\_document\_search | GIN | (search\_vector) |  | Full-text search |
| document | ix\_document\_type | B-tree | (document\_type) | WHERE active = TRUE | Type filtering |
| document | ix\_document\_sha256 | B-tree | (sha256\_hash) | WHERE sha256\_hash IS NOT NULL | Duplicate detection |
| document | ix\_document\_supplier\_trgm | GIN | (supplier\_name gin\_trgm\_ops) |  | Fuzzy supplier name search |
| document\_link | ix\_doclink\_entity | B-tree | (entity\_type, entity\_id) |  | Find documents for any entity |
| document\_link | ix\_doclink\_document | B-tree | (document\_id) |  | Find all links for a document |
| work\_order | ix\_wo\_property\_status | B-tree | (property\_id, status) |  | Active work orders per property |
| work\_order | ix\_wo\_contractor | B-tree | (contractor\_id) | WHERE contractor\_id IS NOT NULL | Contractor's work history |
| correspondence | ix\_corr\_prop\_date | B-tree | (property\_id, correspondence\_date DESC) |  | Recent correspondence |
| legal\_notice | ix\_legal\_prop | B-tree | (property\_id, tenancy\_id) |  | Legal notices per property/tenancy |
| inspection | ix\_insp\_prop\_date | B-tree | (property\_id, conducted\_date DESC) |  | Inspection history |
| agent\_statement | ix\_agstmt\_prop\_period | B-tree | (property\_id, statement\_period\_start DESC) |  | Statement history |
| agent\_statement\_line | ix\_agstmtline\_recon | B-tree | (reconciliation\_status) | WHERE reconciliation\_status IN ('UNMATCHED',​'REVIEW\_REQUIRED') | Unreconciled lines |
| tax\_year\_summary | ix\_taxsum\_taxyear | B-tree | (tax\_year\_id, property\_id) |  | Tax reporting |
| reminder\_instance | ix\_reminder\_pending | B-tree | (due\_date) | WHERE status = 'PENDING' | Scheduled job pickup |
| tenancy | ix\_tenancy\_overlap (GiST) | GiST exclusion | (property\_id, daterange(...)) | WHERE status NOT IN ('ENDED',​'CANCELLED') | Overlap prevention |

# Cross-Cutting Conventions

## Audit Columns

Every mutable table includes:

* created\_at TIMESTAMPTZ NOT NULL DEFAULT now() — set once at creation
* updated\_at TIMESTAMPTZ NOT NULL DEFAULT now() — updated on every mutation
* created\_by UUID — app\_user.id, set by Spring Data JPA @CreatedBy
* updated\_by UUID — app\_user.id, set by @LastModifiedBy

Child/immutable tables (expense\_allocation, document\_version, document\_link, inspection\_item, agent\_statement\_line) have only created\_at and created\_by.

## Optimistic Locking

* Every aggregate root: version BIGINT NOT NULL DEFAULT 0
* JPA @Version annotation; Hibernate auto-increments
* API returns version in response; PUT/DELETE require matching version → 409 Conflict on mismatch

## Soft-Delete

* Pattern: active BOOLEAN NOT NULL DEFAULT TRUE (consistent with V1 property/app\_user)
* Optional deactivated\_at TIMESTAMPTZ for audit trail
* Applied to: property, app\_user, agency\_agreement, income\_line, expense, document, contractor
* Entities where soft-delete is NOT needed (historical records by nature): rent\_payment, rent\_schedule, audit\_event, compliance\_certificate, correspondence, legal\_notice, inspection, tax\_year, tax\_year\_summary, agent\_statement

## Money

* All monetary amounts: NUMERIC(12,2) — never FLOAT/DOUBLE
* Fee percentages: NUMERIC(7,4) — e.g. 10.5000%
* Ownership percentages: NUMERIC(5,2) — e.g. 50.00%
* Match confidence: NUMERIC(3,2) — 0.00 to 1.00
* Java: BigDecimal; API: decimal string

## Enum Strategy

* **Existing V1**: PostgreSQL CREATE TYPE enums (user\_role, property\_type, tenancy\_status) — kept as-is
* **All new columns**: VARCHAR(n) + CHECK constraint — avoids ALTER TYPE migration issues
* **Java**: Java enums with @Enumerated(EnumType.STRING) + @Column(columnDefinition = "VARCHAR(50)")

# Reporting Anchors

## Self-Assessment (SA105)

* **Income source**: income\_line WHERE tax\_year = X AND active = TRUE
* **Expense source**: expense WHERE tax\_year = X AND active = TRUE AND approval\_status = 'APPROVED', grouped by tax\_classification (REVENUE → allowable, CAPITAL → capital allowances, FINANCE → finance costs, PRIVATE → excluded, UNKNOWN → exceptions)
* **Owner split**: property\_owner WHERE effective\_to IS NULL → ownership\_pct applied to property totals
* **Aggregation**: tax\_year\_summary per (property × owner × tax\_year)
* **Output**: self\_assessment\_pack → linked via document\_link to generated PDF/CSV
* **Locking**: tax\_year.status = 'CLOSED' prevents further income/expense modifications for that year

## Agent Fee Reconciliation

* **Expected management fees**: agent\_fee\_schedule (MANAGEMENT\_MONTHLY\_PCT) × rent\_payment.amount\_paid for each month
* **Actual fees charged**: agent\_statement\_line WHERE line\_type = 'MANAGEMENT\_FEE'
* **Reconciliation flow**: Semi-automated matching by amount (± tolerance) and date proximity → match\_confidence score → user confirms/overrides → reconciliation\_status updated
* **Discrepancy detection**: Unmatched lines, fee differences, missing statements surfaced in dashboard

## Compliance Alerts

* **Query**: compliance\_certificate WHERE is\_current = TRUE AND expiry\_date <= (CURRENT\_DATE + INTERVAL '60 days')
* **Feed**: Results feed reminder\_rule / reminder\_instance pipeline
* **Report**: Compliance status dashboard per property with certificate type, expiry countdown, renewal action

# Flyway Migration Plan

| **Migration** | **Scope** | **Description** |
| --- | --- | --- |
| V2 | V1 extensions | Add version to app\_user/property/tenancy/tenant; add idp\_issuer; btree\_gist + GiST exclusion; audit\_event entity\_type/entity\_id |
| V3 | Property & Ownership | property\_owner, agency\_agreement, agent\_fee\_schedule; seed property\_owner from existing ownership\_percentage |
| V4 | Tenancy & Rent | rent\_schedule, rent\_payment, tenancy\_deposit; seed rent\_schedule from tenancy.monthly\_rent |
| V5 | Finance | income\_line, expense, expense\_allocation |
| V6 | Maintenance & Compliance | contractor, work\_order, compliance\_certificate, inspection, inspection\_item |
| V7 | Documents | document, document\_version, document\_link; GIN search index |
| V8 | Communication & Legal | correspondence, legal\_notice |
| V9 | Agency Reconciliation | agent\_statement, agent\_statement\_line |
| V10 | Tax & Reporting | tax\_year, tax\_year\_summary, self\_assessment\_pack |
| V11 | Reminders | reminder\_rule, reminder\_instance |

Each migration is independently deployable. Tables without dependent application code are inert until services are implemented.

# Risks & Mitigations

| **Risk** | **Mitigation** |
| --- | --- |
| Orphaned document\_link rows (no FK on entity\_id) | Application-layer existence check on create; scheduled consistency-check job; CASCADE delete from document side |
| Property.ownershipPercentage deprecation breaks existing API | Keep column; application reads from property\_owner; PropertyResponse computes from property\_owner during migration window |
| GiST exclusion constraint conflicts with app-layer overlap check | Remove app-layer check; rely solely on DB constraint; catch exclusion-violation exception → 409 Conflict |
| 22 new tables in one design iteration | Split into 10 separate Flyway migrations by bounded context; implement incrementally; inert until application code written |
| tax\_year\_summary aggregation accuracy | Summary rows always is\_draft=TRUE until reviewed; recalculation on approved income/expense change; never auto-used for tax filing |
| Expense allocation sum validation | Application-layer check: expense\_allocation rows must sum to expense.amount; validation in service layer with clear error message |

# Open Design Decisions

None remaining — all questions resolved.