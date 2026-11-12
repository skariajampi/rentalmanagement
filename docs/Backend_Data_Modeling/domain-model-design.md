# Domain Model & Database Design — Rental Management System

Comprehensive domain model and PostgreSQL database design for a family-use rental property management system. Extends the existing V1 foundation (app_user, property, tenancy, tenant, audit_event) to cover property ownership (SCD Type 2), agency agreements, rent schedules/payments, income, expenses with owner allocation, agent fee schedules and statement reconciliation, contractors and work orders, compliance certificates, documents (S3 metadata), inspections, correspondence, legal notices, tenancy deposits, tax year reporting, reminders, and self-assessment packs. **31 tables** (5 foundation + 26 domain) across 6 Spring modules. Authentication, usernames, passwords, MFA and roles are owned by Keycloak (OIDC / OAuth2 JWT resource server); the database stores only a local identity anchor (`app_user`).

## Confirmed Technology Decisions

| Decision | Value |
|----------|-------|
| Language / Framework | Java 25, Spring Boot 4.1.0, Maven |
| Database | PostgreSQL 16 with `btree_gist`, `pgcrypto`, `pg_trgm` extensions |
| Persistence | JPA / Hibernate, Flyway migrations |
| File Storage | AWS S3 (binaries); PostgreSQL holds metadata only |
| Deployment | K3s homelab; no Spring Cloud, no microservices |
| Module layout | `rental-shared` → `rental-identity` → `rental-core` → `rental-document` → `rental-tax` → `rental-app` |
| Money | `NUMERIC(12,2)` everywhere; no floating point |
| Percentages | `NUMERIC(5,2)` for ownership; `NUMERIC(7,4)` for fee rates |
| Audit | Append-only `audit_event` table; no enforcing triggers yet |
| Identity / AuthN | Keycloak (OIDC); app is a Spring Security OAuth2 resource server validating JWT access tokens. No usernames or passwords in the DB |
| Roles | ADMIN > LANDLORD > ACCOUNTANT > FAMILY_VIEWER — supplied by Keycloak as JWT claims (realm/client roles), mapped to Spring Security authorities; **not stored in the DB** |
| Optimistic locking | `version BIGINT NOT NULL DEFAULT 0` on every mutable aggregate |
| New enums | `VARCHAR(n) + CHECK` constraint (not PostgreSQL CREATE TYPE) |
| Existing enums | Keep V1 PostgreSQL CREATE TYPE enums (property_type, tenancy_status); `user_role` dropped (roles come from Keycloak) |
| Soft-delete | `active BOOLEAN NOT NULL DEFAULT TRUE` + optional `deactivated_at TIMESTAMPTZ` (consistent with V1 pattern) |
| PKs | UUID with `gen_random_uuid()` |
| Timestamps | `TIMESTAMPTZ` (UTC) |
| Tax year | UK fiscal year: 6 April – 5 April |

### Resolved Design Questions

1. **Agent statement reconciliation**: Semi-automated with suggestions — system proposes matches by amount/date; user confirms or overrides.
2. **Reminder channels**: One channel per rule; users create multiple rules for multiple channels (EMAIL, SMS, NTFY, IN_APP).
3. **Expense category extensibility**: CHECK constraint (25 categories); migrate to reference table only if >30 categories or non-developer users need to add categories.
4. **Identity model**: Keycloak owns authentication; `app_user` is a JIT-provisioned identity anchor keyed by `(idp_issuer, idp_subject)`. No `username` column, no password data, no role column/table/enum.
5. **Roles**: Come from Keycloak JWT claims (`realm_access.roles` / `resource_access.<client>.roles`) and are mapped to authorities in Spring Security; role precedence is resolved in the application, not the DB.

---

## Goals

- Define bounded contexts and map every aggregate root to its Spring module
- Specify every new table with columns, PostgreSQL types, constraints, defaults, nullability, and descriptions
- Extend V1 tables (app_user, property, tenancy, tenant, audit_event) with identified gaps (version, idp_issuer, GiST overlap constraint)
- Model joint property ownership with percentage history (SCD Type 2)
- Design a complete financial ledger (income, expenses, agent fees, rent payments) suitable for UK self-assessment
- Design polymorphic document linking with S3 metadata storage
- Define index strategy for all query patterns (free-text search, date range, FK lookups, compliance alerts)
- Establish cross-cutting conventions: audit columns, optimistic locking, soft-delete, money types
- Identify reporting anchors for self-assessment, HMRC queries, and agent fee reconciliation
- Ensure extensibility to multi-property portfolio without schema rewrites

---

## Bounded Contexts & Module Placement

| Module | Aggregate Roots | Justification |
|--------|----------------|---------------|
| **rental-shared** | AuditEvent, Auditable base | Cross-cutting: audit, enums, money utils, error types, `CurrentActorProvider` SPI (actor UUID for auditing/FKs) |
| **rental-identity** | AppUser | Keycloak JIT provisioning (upsert on issuer+subject), profile-snapshot refresh, JWT → authority mapping, `CurrentActorProvider` implementation |
| **rental-core** | Property, PropertyOwner, AgencyAgreement, AgentFeeSchedule, Tenancy (w/ Tenant, TenancyDeposit), RentSchedule, RentPayment, IncomeLine, Expense (w/ ExpenseAllocation), Contractor, WorkOrder, ComplianceCertificate, Inspection (w/ InspectionItem), Correspondence, LegalNotice, AgentStatement (w/ AgentStatementLine), ReminderRule (w/ ReminderInstance) | Core domain — property, tenancy, finance, maintenance, compliance, agency, reminders |
| **rental-document** | Document (w/ DocumentVersion, DocumentLink) | Document lifecycle, S3 interaction, OCR status, search vectors |
| **rental-tax** | TaxYear, TaxYearSummary, SelfAssessmentPack | Tax reporting, SA105 mapping, year locking |
| **rental-app** | — | Boot main, Flyway migrations, config, composition root |

### Module Dependency Graph

```
rental-shared  (base — no upward dependencies)
     ↑
rental-identity  (depends on shared)
     ↑
rental-core  (depends on shared only — actor via CurrentActorProvider SPI)
     ↑
rental-document  (depends on shared, identity)
     ↑
rental-tax  (depends on shared, identity, core)
     ↑
rental-app  (composition root — depends on all)
```

New Maven modules to add to parent POM: `rental-document`, `rental-tax`.

`rental-core` must not depend on `rental-identity`. It obtains the current actor's `app_user.id` through the `CurrentActorProvider` SPI declared in `rental-shared` (also backing Spring Data `AuditorAware` for `created_by`/`updated_by`). `rental-identity` implements the SPI by resolving the JWT `iss` + `sub` to `app_user.id`, provisioning the row just-in-time if absent. User FK columns in core (`owner_id`, `raised_by_id`, …) are plain `UUID` attributes, not JPA associations to `AppUser`.

---

## Domain Model by Bounded Context

### Context 1: Identity & Users

**Aggregate root**: `AppUser`

```
AppUser (rental-identity)
├── id : UUID [PK]                      — internal actor id; target of all user FKs
├── idp_issuer : TEXT [NOT NULL]        — JWT iss (Keycloak realm issuer URL)
├── idp_subject : TEXT [NOT NULL]       — JWT sub (immutable Keycloak user id)
├── display_name : VARCHAR(200) [NULL]  — snapshot of name claim, display only
├── email : VARCHAR(320) [NULL]         — snapshot of email claim, notifications only
├── active : BOOLEAN                    — app-level soft-disable
├── first_seen_at : TIMESTAMPTZ         — JIT provisioning time
├── last_seen_at : TIMESTAMPTZ          — last authenticated request/login
├── version : BIGINT
└── audit columns (created_at, updated_at, created_by, updated_by)
```

`app_user` is a **local identity anchor**, not a user directory. It exists so that FKs (`created_by`/`updated_by`, `audit_event.actor_id`, `property_owner.owner_id`, `document.uploaded_by_id`, `tax_year.locked_by_id`, approvals, etc.) and per-user application data have a stable target.

**Business rules enforced at DB level**:
- `UNIQUE(idp_issuer, idp_subject)` — the only authentication key (multi-realm safe)
- `idp_issuer`, `idp_subject` are `NOT NULL` — rows exist only after a successful authentication
- `CHECK(last_seen_at >= first_seen_at)`
- No `username`, no password/credential columns, no `role` column, no `user_role` enum, no `role`/`user_role` tables
- `email` is **not** unique and never used as a key (it can change in Keycloak or be shared/absent)

**Provisioning (JIT)**: on the first authenticated request, `rental-identity` upserts on `(idp_issuer, idp_subject)`:
```sql
INSERT INTO app_user (idp_issuer, idp_subject, display_name, email)
VALUES (:iss, :sub, :name, :email)
ON CONFLICT (idp_issuer, idp_subject) DO UPDATE
   SET display_name = EXCLUDED.display_name,
       email        = EXCLUDED.email,
       last_seen_at = now(),
       updated_at   = now(),
       version      = app_user.version + 1;
```
Refresh the snapshot at most once per session/login (or when claims differ) rather than on every request, to avoid write amplification. The resolved `app_user.id` is cached per request in the security context.

**Roles & authorities**: roles are not persisted. Keycloak issues them as realm roles (`realm_access.roles`) and/or client roles (`resource_access.<client-id>.roles`). A custom `JwtAuthenticationConverter` (with a `Converter<Jwt, Collection<GrantedAuthority>>`) maps them to `ROLE_ADMIN`, `ROLE_LANDLORD`, `ROLE_ACCOUNTANT`, `ROLE_FAMILY_VIEWER`. Precedence ADMIN > LANDLORD > ACCOUNTANT > FAMILY_VIEWER is expressed with a Spring Security `RoleHierarchy` bean, so `@PreAuthorize("hasRole('ACCOUNTANT')")` is satisfied by LANDLORD and ADMIN. Role changes take effect when a new access token is issued (token lifetime bounds staleness).

**ID token vs access token**: the backend is a resource server and only sees the **access token**. Configure Keycloak client scopes / protocol mappers so the access token carries `realm_access`/`resource_access` roles (default) and the profile claims needed for the snapshot (`name` or `preferred_username`, `email`). ID-token-only claims are not visible to the API; the SPA uses the ID token purely for its own UI. `preferred_username` may be used as a fallback for `display_name` but is never stored as a username or used as a key.

#### Responsibility boundary: Keycloak vs application

| Concern | Keycloak | Application (Spring / PostgreSQL) |
|---------|----------|-----------------------------------|
| Login, passwords, MFA, password reset, account lockout | ✅ Owns | — |
| Usernames, identity-provider accounts, federation | ✅ Owns | — (not stored) |
| User profile source of truth (name, email) | ✅ Owns | Read-only snapshot in `app_user.display_name` / `email` |
| Role assignment (ADMIN, LANDLORD, ACCOUNTANT, FAMILY_VIEWER) | ✅ Owns (realm/client roles) | — (not stored) |
| Token issuance, signing, expiry, refresh | ✅ Owns | Validates JWT signature, `iss`, `exp`, audience |
| Claim → authority mapping, role precedence | — | ✅ `JwtAuthenticationConverter` + `RoleHierarchy` |
| Authorization rules (who may do what, tax-year lock, approvals) | — | ✅ `@PreAuthorize` / service-layer checks |
| Stable internal actor id for FKs and audit | — | ✅ `app_user.id`, JIT-provisioned from (`iss`, `sub`) |
| Account enable/disable | ✅ Primary (disable user / revoke sessions) | Optional app-level block via `app_user.active = FALSE` |
| Audit trail of domain changes | — | ✅ `audit_event` (actor id + display-name snapshot) |

The big picture
The app uses Keycloak to log people in. The database never stores passwords or roles. But your tables still need to say "who did this?" (who raised a work order, who owns a property, who last edited a record). So the app keeps a small local row per person, app_user, whose only job is to give each person a stable UUID that other tables can reference.

Step by step
1. The CurrentActorProvider SPI (in rental-shared)

An SPI (service provider interface) is just a Java interface, roughly:

java

Copy
public interface CurrentActorProvider {
UUID currentActorId();   // app_user.id of whoever is making this request
}
Try:
|
It lives in rental-shared because every module can depend on that one without depending on each other. Core modules (properties, expenses, work orders) call it without knowing how identity works. They only know "I can ask for the current actor's id."

2. Spring Data auditing (AuditorAware)

Spring Data JPA can fill created_by and updated_by automatically through AuditorAware<UUID>. The same SPI backs it, roughly:

java

Copy
@Bean
AuditorAware<UUID> auditorAware(CurrentActorProvider p) {
return () -> Optional.of(p.currentActorId());
}
Try:
|
So one source of truth gives you both explicit uses (raised_by_id = provider.currentActorId()) and automatic audit columns.

3. rental-identity implements the SPI

This module is the only one that knows about JWTs and app_user. On each call it does the following:

Reads the authenticated JWT from the Spring Security context.
Takes the iss (issuer, i.e. your Keycloak realm URL) and sub (the user's unique id in that realm).
Looks up app_user by UNIQUE(idp_issuer, idp_subject).
If a row exists, it returns its id.
If not, it inserts one. This is the just-in-time step. It also stores display_name and email as snapshots from the token claims.
Implement the insert as an upsert (INSERT ... ON CONFLICT (idp_issuer, idp_subject) DO NOTHING, then select). Two simultaneous first requests from a new user would otherwise race and one would fail on the unique constraint. You can also cache issuer+subject → id in memory, so the database is not hit on every request.

4. Why issuer + subject, not email or username

sub is stable and unique only within one issuer. Pairing it with iss stays correct if you ever change realms or add another identity provider. Emails and usernames can change, so they are kept only as nullable display snapshots.

5. Plain UUID columns, not JPA associations

In core entities, you map the user reference like this:

java

Copy
@Column(name = "raised_by_id")
private UUID raisedById;
Try:
|
and not like this:

java

Copy
@ManyToOne private AppUser raisedBy;   // avoid
Try:
|
Reasons:

Module boundaries: AppUser lives in rental-identity. A JPA association would force core to depend on identity, which breaks the "core only depends on shared" rule and risks cycles.
No accidental loading: no lazy-loading surprises or N+1 queries when you only need an id.
Simpler entities and tests: you can create a work order in a test with any UUID, without building an AppUser.
Integrity is still enforced by the database foreign key in the Flyway schema. JPA just doesn't model the relationship.
If you need the person's name for a screen, ask rental-identity through a small query service (e.g. UserDirectory.displayNames(Set<UUID>)) rather than joining across modules.

Flow at a glance
Request + JWT → Spring Security → core service
→ CurrentActorProvider.currentActorId()
→ (rental-identity) iss+sub → app_user.id (insert if missing)
→ save entity with created_by / raised_by_id = that UUID
Things to watch
Provision before any audited write (the auditor is called at flush time, so a missing row must be created in a transaction that is visible to the FK).
Background jobs (reminders, imports) have no JWT. Give them a fixed "system" actor row, or have the provider return it when there is no authentication.
audit_event keeps an actor_display_name snapshot, so history stays readable even if a user's name later changes.
---

### Context 2: Property & Ownership

**Aggregate roots**: `Property`, `PropertyOwner`, `AgencyAgreement`, `AgentFeeSchedule`

```
Property (rental-core)                    PropertyOwner (SCD Type 2)
├── id : UUID [PK]                        ├── id : UUID [PK]
├── property_reference [UNIQUE]           ├── property_id → Property
├── address fields                        ├── owner_id → AppUser
├── property_type : PG ENUM              ├── ownership_pct : NUMERIC(5,2)
├── purchase_date / purchase_price        ├── effective_from : DATE
├── ownership_percentage [DEPRECATED]     ├── effective_to : DATE (NULL=current)
├── active : BOOLEAN                      └── version, audit columns
├── version : BIGINT [NEW]
├── audit columns                        AgencyAgreement
└── tenancies[]                          ├── id : UUID [PK]
                                         ├── property_id → Property
AgentFeeSchedule                         ├── agency_name, contact, email, phone
├── id : UUID [PK]                       ├── management_type : VARCHAR(30)
├── property_id → Property               ├── fee_percentage, fee_fixed
├── fee_type : VARCHAR(50)               ├── agreement_start / agreement_end
├── value : NUMERIC(7,4)                 ├── notice_period_days
├── effective_from / effective_to        ├── active : BOOLEAN
└── version, audit columns               └── version, audit columns
```

**Business rules**:
- Sum of `ownership_pct` for current owners (effective_to IS NULL) of a property must equal 100 — enforced in application layer
- `property.ownership_percentage` is deprecated; application reads from `property_owner` but column retained during migration window
- `UNIQUE(property_id, owner_id, effective_from)` on property_owner
- `UNIQUE(property_id, fee_type, effective_from)` on agent_fee_schedule

---

### Context 3: Tenancy & Rent

**Aggregate roots**: `Tenancy` (with child entities Tenant, TenancyDeposit), `RentSchedule`, `RentPayment`

```
Tenancy (rental-core)                     Tenant
├── id : UUID [PK]                        ├── id : UUID [PK]
├── property_id → Property                ├── tenancy_id → Tenancy
├── start_date / end_date                 ├── full_name, email, phone
├── monthly_rent : NUMERIC(12,2)          ├── move_in_date / move_out_date
├── payment_day : SMALLINT                ├── emergency contact fields
├── status : tenancy_status [PG ENUM]     ├── version : BIGINT [NEW]
├── deposit fields [DEPRECATED]           └── audit columns
├── version : BIGINT [NEW]
├── audit columns                        TenancyDeposit (1:1 with Tenancy)
└── tenants[]                            ├── id : UUID [PK]
                                         ├── tenancy_id → Tenancy [UNIQUE]
RentSchedule                             ├── amount : NUMERIC(12,2)
├── id : UUID [PK]                       ├── scheme : VARCHAR(30)
├── tenancy_id → Tenancy                 ├── scheme_reference
├── monthly_rent : NUMERIC(12,2)         ├── registered_date / returned_date
├── effective_from / effective_to        ├── returned_amount / deductions
└── version, audit columns               ├── deduction_reason
                                         ├── status : VARCHAR(20)
RentPayment                              └── version, audit columns
├── id : UUID [PK]
├── tenancy_id → Tenancy
├── due_date, amount_due, amount_paid
├── paid_date, payment_method
├── status : VARCHAR(20)
└── version, audit columns
```

**Business rules at DB level**:
- GiST exclusion constraint on tenancy: no overlapping non-ended tenancies per property
  ```sql
  EXCLUDE USING gist (
    property_id WITH =,
    daterange(start_date, COALESCE(end_date, '9999-12-31'::date), '[)') WITH &&
  ) WHERE (status NOT IN ('ENDED','CANCELLED'))
  ```
- `CHECK (end_date IS NULL OR end_date > start_date)` on tenancy
- `UNIQUE(tenancy_id)` on tenancy_deposit — one deposit per tenancy
- `UNIQUE(tenancy_id, effective_from)` on rent_schedule
- Status machines enforced in application layer, transitions audited
- `tenancy.monthly_rent` and `tenancy.deposit_*` columns retained; `rent_schedule` and `tenancy_deposit` provide the full-fidelity records. Application keeps `tenancy.monthly_rent` in sync with the latest `rent_schedule` entry.

---

### Context 4: Finance (Income, Expenses, Agent Reconciliation)

**Aggregate roots**: `IncomeLine`, `Expense` (with child ExpenseAllocation), `AgentStatement` (with child AgentStatementLine)

```
IncomeLine                               Expense
├── id : UUID [PK]                       ├── id : UUID [PK]
├── property_id → Property               ├── property_id → Property
├── tenancy_id → Tenancy (nullable)      ├── category : VARCHAR(50) [25 categories]
├── category : VARCHAR(50)               ├── amount : NUMERIC(12,2)
├── amount : NUMERIC(12,2)               ├── expense_date : DATE
├── received_date : DATE                 ├── payee, description
├── description, tax_year                ├── tax_classification : VARCHAR(20)
├── active : BOOLEAN                     ├── tax_deductible : BOOLEAN
└── version, audit columns               ├── tax_year : VARCHAR(7)
                                         ├── vat_amount : NUMERIC(12,2)
ExpenseAllocation                        ├── owner_id → AppUser (nullable=joint)
├── id : UUID [PK]                       ├── work_order_id → WorkOrder (nullable)
├── expense_id → Expense                 ├── approval_status : VARCHAR(20)
├── owner_id → AppUser                   ├── active : BOOLEAN
├── allocated_amount : NUMERIC(12,2)     ├── deactivated_at : TIMESTAMPTZ
└── created_at, created_by               └── version, audit columns

AgentStatement                           AgentStatementLine
├── id : UUID [PK]                       ├── id : UUID [PK]
├── agency_agreement_id → AgencyAgr.     ├── agent_statement_id → AgentStatement
├── property_id → Property               ├── transaction_date, description
├── statement_period_start/end           ├── amount : NUMERIC(12,2) [signed]
├── gross_rent, management_fee           ├── line_type : VARCHAR(30)
├── other_deductions, net_amount         ├── matched_income_id → IncomeLine
├── status : VARCHAR(30)                 ├── matched_expense_id → Expense
└── version, audit columns               ├── reconciliation_status : VARCHAR(30)
                                         │   (UNMATCHED/MATCHED/IGNORED/REVIEW_REQUIRED)
                                         ├── match_confidence : NUMERIC(3,2) [NEW]
                                         │   (0.00-1.00, system suggestion score)
                                         └── created_at, created_by
```

**Business rules**:
- Expense categories (25): AGENT_MANAGEMENT_FEE, AGENT_LETTING_FEE, AGENT_RENEWAL_FEE, ADMIN_FEE, PAT_TEST, GAS_SAFETY_CERT, EICR, EPC, FIRE_ALARM_TEST, EMERGENCY_LIGHTING_TEST, LEGIONELLA_RISK, REPAIR, MAINTENANCE, PROFESSIONAL_CLEANING, LEGAL_FEES, INSURANCE, MORTGAGE_INTEREST, ACCOUNTANCY_FEES, ADVERTISING, COUNCIL_TAX, UTILITIES, GROUND_RENT, SERVICE_CHARGE, TRAVEL, OTHER
- Tax classifications: REVENUE, CAPITAL, PRIVATE, FINANCE, UNKNOWN — kept distinct, never silently inferred
- Only `approval_status = 'APPROVED'` expenses feed tax calculations
- `expense_allocation`: If no rows exist for an expense, default split is per `property_owner` current percentages. If rows exist, they must sum to `expense.amount`.
- `UNIQUE(expense_id, owner_id)` on expense_allocation
- Agent reconciliation is **semi-automated**: system suggests matches by amount ± tolerance and date proximity, populates `match_confidence`; user confirms or overrides

---

### Context 5: Maintenance, Compliance & Inspections

**Aggregate roots**: `Contractor`, `WorkOrder`, `ComplianceCertificate`, `Inspection` (with child InspectionItem)

```
Contractor                               WorkOrder
├── id : UUID [PK]                       ├── id : UUID [PK]
├── name, company_name                   ├── property_id → Property
├── trade : VARCHAR(50)                  ├── contractor_id → Contractor (nullable)
├── phone, email                         ├── title, description
├── notes                                ├── category, priority
├── active : BOOLEAN                     ├── raised_date, scheduled_date, completed_date
└── version, audit columns               ├── labour_cost, materials_cost, total_cost
                                         ├── status : VARCHAR(20)
ComplianceCertificate                    ├── raised_by_id → AppUser
├── id : UUID [PK]                       └── version, audit columns
├── property_id → Property
├── cert_type : VARCHAR(50)             Inspection
├── issue_date, expiry_date             ├── id : UUID [PK]
├── issued_by, certificate_reference    ├── property_id → Property
├── is_current : BOOLEAN                ├── tenancy_id → Tenancy (nullable)
└── version, audit columns               ├── inspection_type : VARCHAR(30)
                                         ├── scheduled_date, conducted_date
InspectionItem                           ├── conducted_by : VARCHAR(200)
├── id : UUID [PK]                       ├── overall_condition : VARCHAR(20)
├── inspection_id → Inspection           └── version, audit columns
├── room_or_area, description
├── condition, action_required
├── action_description
├── photo_document_id → Document
└── created_at, created_by
```

**Business rules**:
- Completed work orders can generate an expense record (linked via `expense.work_order_id`)
- Compliance certificates expiring within 60 days surface in reports and feed reminder rules
- Contractor trades (12): ELECTRICIAN, GAS_ENGINEER, PLUMBER, GENERAL_BUILDER, CLEANER, LOCKSMITH, GLAZIER, ROOFER, PAINTER, CARPET_FITTER, GARDENER, OTHER
- Work order statuses: OPEN → SCHEDULED → IN_PROGRESS → COMPLETED | CANCELLED

---

### Context 6: Communication & Legal

**Aggregate roots**: `Correspondence`, `LegalNotice`

```
Correspondence                           LegalNotice
├── id : UUID [PK]                       ├── id : UUID [PK]
├── property_id → Property               ├── property_id → Property
├── tenancy_id → Tenancy (nullable)      ├── tenancy_id → Tenancy (nullable)
├── direction : INBOUND/OUTBOUND         ├── notice_type : VARCHAR(50)
├── channel : EMAIL/LETTER/SMS/          ├── served_date, effective_date
│   PORTAL/PHONE                         ├── response_due_date
├── subject, summary                     ├── status : VARCHAR(30)
├── correspondence_date                  └── version, audit columns
├── from_party, to_party
├── is_legal : BOOLEAN
└── version, audit columns
```

**Business rules**:
- Correspondence and legal notices link to documents via `document_link`
- Legal notice statuses: DRAFT → SERVED → ACKNOWLEDGED | EXPIRED | WITHDRAWN | DISPUTED

---

### Context 7: Documents (rental-document module)

**Aggregate root**: `Document` (with children DocumentVersion, DocumentLink)

```
Document                                 DocumentVersion
├── id : UUID [PK]                       ├── id : UUID [PK]
├── display_name                         ├── document_id → Document
├── original_filename                    ├── version_number : INT
├── s3_bucket, s3_key                    ├── s3_key
├── content_type, size_bytes             ├── size_bytes, sha256_hash
├── sha256_hash                          ├── uploaded_at, uploaded_by_id
├── uploaded_at, uploaded_by_id          └── UNIQUE(document_id, version_number)
├── description
├── document_type : VARCHAR(50)         DocumentLink (polymorphic join)
├── supplier_name                        ├── id : UUID [PK]
├── extracted_text                       ├── document_id → Document [FK CASCADE]
├── upload_status : VARCHAR(30)          ├── entity_type : VARCHAR(50)
├── search_vector : TSVECTOR [GEN]       ├── entity_id : UUID (no FK)
├── active : BOOLEAN                     ├── relationship : VARCHAR(50)
├── deactivated_at                       ├── created_at, created_by
└── version, audit columns               └── UNIQUE(document_id, entity_type, entity_id)
```

**Upload status state machine**:
```
UPLOADING → AVAILABLE → OCR_PENDING → OCR_PROCESSING → SEARCHABLE
                                    ↘ OCR_FAILED
UPLOADING → UPLOAD_FAILED
```

**Document types** (21): RECEIPT, INVOICE, LEASE_AGREEMENT, GAS_CERTIFICATE, EICR, EPC, PAT_REPORT, FIRE_ALARM_REPORT, EMERGENCY_LIGHTING_REPORT, INSPECTION_REPORT, CORRESPONDENCE, LEGAL, BANK_STATEMENT, TAX_DOCUMENT, CONTRACTOR_QUOTE, CONTRACTOR_INVOICE, PHOTO, AGENT_STATEMENT, INSURANCE_POLICY, MORTGAGE_DOCUMENT, OTHER

**Linkable entity types** (14): PROPERTY, EXPENSE, WORK_ORDER, COMPLIANCE_CERT, TENANCY, INCOME_LINE, CONTRACTOR, TAX_PACK, CORRESPONDENCE, INSPECTION, LEGAL_NOTICE, RENT_PAYMENT, AGENCY_AGREEMENT, AGENT_STATEMENT

**Relationship types**: SUPPORTS, EVIDENCE_FOR, ATTACHED_TO, SOURCE_OF

**Orphan mitigation**: Application-layer existence check on link creation; scheduled consistency-check job compares entity_ids against target tables.

---

### Context 8: Tax & Self-Assessment (rental-tax module)

**Aggregate roots**: `TaxYear`, `TaxYearSummary`, `SelfAssessmentPack`

```
TaxYear                                  TaxYearSummary
├── id : UUID [PK]                       ├── id : UUID [PK]
├── tax_year_label : VARCHAR(7) [UQ]     ├── property_id → Property
│   e.g. '2025-26'                       ├── tax_year_id → TaxYear
├── start_date : DATE (6 April)          ├── owner_id → AppUser
├── end_date : DATE (5 April)            ├── gross_income : NUMERIC(12,2)
├── status : OPEN/CLOSED/FILED           ├── allowable_expenses : NUMERIC(12,2)
├── locked_at, locked_by_id              ├── finance_costs : NUMERIC(12,2)
├── unlock_reason                        ├── capital_expenses : NUMERIC(12,2)
└── version, audit columns               ├── net_profit : NUMERIC(12,2)
                                         ├── owner_share_pct : NUMERIC(5,2)
SelfAssessmentPack                       ├── owner_net_profit : NUMERIC(12,2)
├── id : UUID [PK]                       ├── personal_allowance_used : NUMERIC(12,2)
├── tax_year_id → TaxYear                ├── tax_due : NUMERIC(12,2)
├── owner_id → AppUser                   ├── is_draft : BOOLEAN
├── generated_at                         ├── UNIQUE(property_id, tax_year_id, owner_id)
├── status : DRAFT/READY/SUBMITTED       └── version, audit columns
├── submission_reference
├── generated_by_id → AppUser
├── UNIQUE(tax_year_id, owner_id)
└── version, audit columns
```

**Business rules**:
- Tax year locking: OPEN → CLOSED requires explicit user action and audit event; CLOSED → OPEN requires unlock_reason, user identity, and audit event
- Summary rows always `is_draft = TRUE` until explicitly reviewed
- Recalculation triggered on any approved income/expense change within the tax year
- Only `approval_status = 'APPROVED'` income and expenses are included
- UNKNOWN-classified expenses appear as exceptions in the report, not in totals

---

### Context 9: Reminders

**Aggregate root**: `ReminderRule` (with child ReminderInstance)

```
ReminderRule                             ReminderInstance
├── id : UUID [PK]                       ├── id : UUID [PK]
├── target_type : VARCHAR(50)            ├── reminder_rule_id → ReminderRule
├── target_id : UUID                     ├── due_date : DATE
├── reminder_type : VARCHAR(50)          ├── status : PENDING/SENT/SNOOZED/
├── days_before : INT                    │   COMPLETED/FAILED
├── recurrence : VARCHAR(30)             ├── sent_at, snoozed_until, completed_at
├── channel : VARCHAR(30)               └── UNIQUE(reminder_rule_id, due_date)
├── enabled : BOOLEAN
├── recipient : VARCHAR(320)
└── created_at, created_by
```

**Channels**: IN_APP, EMAIL, SMS, NTFY  
**Recurrence**: ONCE, DAILY, WEEKLY, MONTHLY, ANNUALLY  
**Multi-channel**: Create one rule per channel. E.g., gas safety expiry → one EMAIL rule + one NTFY rule.

---

## Design — Full Database Schema

### V1 Schema Extensions (Migration V2)

#### app_user — identity anchor (replaces V1 definition)

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | Internal actor id; resolved from JWT (iss, sub) by `CurrentActorProvider` |
| idp_issuer | TEXT | NOT NULL | | UNIQUE(idp_issuer, idp_subject) | JWT `iss` — Keycloak realm issuer URL |
| idp_subject | TEXT | NOT NULL | | UNIQUE(idp_issuer, idp_subject) | JWT `sub` — immutable Keycloak user id |
| display_name | VARCHAR(200) | NULL | | | Profile snapshot (name claim), refreshed on login; display only |
| email | VARCHAR(320) | NULL | | (not unique) | Profile snapshot (email claim), refreshed on login; notifications only |
| active | BOOLEAN | NOT NULL | TRUE | | App-level soft-disable; Keycloak remains primary for account disable |
| first_seen_at | TIMESTAMPTZ | NOT NULL | now() | CHECK(last_seen_at >= first_seen_at) | JIT provisioning time |
| last_seen_at | TIMESTAMPTZ | NOT NULL | now() | | Last authenticated request/login |
| version | BIGINT | NOT NULL | 0 | | Optimistic lock |
| created_at / updated_at / created_by / updated_by | | | | | Standard audit columns |

- **Removed vs earlier draft**: `username` + `UNIQUE(username)`, `role` (`user_role` enum) and the `user_role` type itself. `idp_issuer`/`idp_subject` are now `NOT NULL` (rows are created only on authentication) and `display_name` is nullable (claim may be absent).
- No backfill needed: V1 is a clean baseline.
- Table and column `COMMENT ON` statements document the Keycloak ownership boundary.

#### property — ADD column

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| version | BIGINT | NOT NULL | 0 | | Optimistic lock |

Note: `ownership_percentage` retained but deprecated. Application reads from `property_owner`.

#### tenancy — ADD column + constraint

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| version | BIGINT | NOT NULL | 0 | | Optimistic lock |

- **ADD extension**: `CREATE EXTENSION IF NOT EXISTS btree_gist`
- **ADD exclusion constraint**:
  ```
  EXCLUDE USING gist (
    property_id WITH =,
    daterange(start_date, COALESCE(end_date, '9999-12-31'::date), '[)') WITH &&
  ) WHERE (status NOT IN ('ENDED','CANCELLED'))
  ```

#### tenant — ADD column

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| version | BIGINT | NOT NULL | 0 | | Optimistic lock |

#### audit_event — ADD columns

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| entity_type | VARCHAR(50) | NULL | | | Alias for aggregate_type; backfill |
| entity_id | UUID | NULL | | | Alias for aggregate_id; backfill |

- `actor_id` → app_user.id, resolved from the JWT (iss, sub) via `CurrentActorProvider`.
- `actor_username` replaced by `actor_display_name VARCHAR(200)` — a point-in-time copy of `app_user.display_name` when the event was written (no usernames are stored).

---

### New Table: property_owner

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| owner_id | UUID | NOT NULL | | FK → app_user(id) | |
| ownership_pct | NUMERIC(5,2) | NOT NULL | | CHECK (> 0 AND <= 100) | Owner's share percentage |
| effective_from | DATE | NOT NULL | | | Start of this ownership record |
| effective_to | DATE | NULL | | CHECK (NULL OR > effective_from) | NULL = current |
| version | BIGINT | NOT NULL | 0 | | Optimistic lock |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

**Unique**: `(property_id, owner_id, effective_from)`

---

### New Table: agency_agreement

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| agency_name | VARCHAR(200) | NOT NULL | | | Letting agency name |
| company_name | VARCHAR(200) | NULL | | | Registered company name |
| contact_name | VARCHAR(200) | NULL | | | Account manager |
| email | VARCHAR(320) | NULL | | | |
| phone | VARCHAR(50) | NULL | | | |
| management_type | VARCHAR(30) | NOT NULL | | CHECK IN ('FULL_MANAGEMENT','RENT_COLLECTION','TENANT_FIND','NONE') | |
| fee_percentage | NUMERIC(7,4) | NULL | | | Management fee % |
| fee_fixed | NUMERIC(12,2) | NULL | | | Fixed fee amount |
| agreement_start | DATE | NULL | | | |
| agreement_end | DATE | NULL | | | |
| notice_period_days | INTEGER | NULL | | | |
| notes | TEXT | NULL | | | |
| active | BOOLEAN | NOT NULL | TRUE | | Soft-delete |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: agent_fee_schedule

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| fee_type | VARCHAR(50) | NOT NULL | | CHECK IN ('MANAGEMENT_MONTHLY_PCT','LETTING_FLAT','RENEWAL_FLAT','LETTING_PCT','RENEWAL_PCT') | |
| value | NUMERIC(7,4) | NOT NULL | | | Percentage or £ depending on type |
| effective_from | DATE | NOT NULL | | | |
| effective_to | DATE | NULL | | | NULL = current |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

**Unique**: `(property_id, fee_type, effective_from)`

---

### New Table: rent_schedule

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| tenancy_id | UUID | NOT NULL | | FK → tenancy(id) | |
| monthly_rent | NUMERIC(12,2) | NOT NULL | | CHECK (>= 0) | Agreed rent for this period |
| effective_from | DATE | NOT NULL | | | |
| effective_to | DATE | NULL | | | NULL = current rate |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

**Unique**: `(tenancy_id, effective_from)`

---

### New Table: rent_payment

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| tenancy_id | UUID | NOT NULL | | FK → tenancy(id) | |
| due_date | DATE | NOT NULL | | | |
| amount_due | NUMERIC(12,2) | NOT NULL | | CHECK (>= 0) | |
| amount_paid | NUMERIC(12,2) | NULL | | CHECK (NULL OR >= 0) | |
| paid_date | DATE | NULL | | | |
| payment_method | VARCHAR(50) | NULL | | | Free text |
| status | VARCHAR(20) | NOT NULL | 'PENDING' | CHECK IN ('PENDING','PAID','PARTIAL','LATE','WAIVED') | |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: income_line

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| tenancy_id | UUID | NULL | | FK → tenancy(id) | Nullable for non-tenancy income |
| category | VARCHAR(50) | NOT NULL | | CHECK IN ('RENT','HOLDING_DEPOSIT','DEPOSIT','RENT_GUARANTEE','INSURANCE_CLAIM','OTHER') | |
| amount | NUMERIC(12,2) | NOT NULL | | CHECK (>= 0) | |
| received_date | DATE | NOT NULL | | | |
| description | TEXT | NULL | | | |
| tax_year | VARCHAR(7) | NULL | | | e.g. '2025-26' |
| active | BOOLEAN | NOT NULL | TRUE | | Soft-delete |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: expense

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| category | VARCHAR(50) | NOT NULL | | CHECK IN ('AGENT_MANAGEMENT_FEE','AGENT_LETTING_FEE','AGENT_RENEWAL_FEE','ADMIN_FEE','PAT_TEST','GAS_SAFETY_CERT','EICR','EPC','FIRE_ALARM_TEST','EMERGENCY_LIGHTING_TEST','LEGIONELLA_RISK','REPAIR','MAINTENANCE','PROFESSIONAL_CLEANING','LEGAL_FEES','INSURANCE','MORTGAGE_INTEREST','ACCOUNTANCY_FEES','ADVERTISING','COUNCIL_TAX','UTILITIES','GROUND_RENT','SERVICE_CHARGE','TRAVEL','OTHER') | |
| amount | NUMERIC(12,2) | NOT NULL | | CHECK (>= 0) | |
| expense_date | DATE | NOT NULL | | | |
| payee | VARCHAR(200) | NULL | | | |
| description | TEXT | NULL | | | |
| tax_classification | VARCHAR(20) | NOT NULL | 'UNKNOWN' | CHECK IN ('REVENUE','CAPITAL','PRIVATE','FINANCE','UNKNOWN') | SA105 classification |
| tax_deductible | BOOLEAN | NOT NULL | TRUE | | |
| tax_year | VARCHAR(7) | NULL | | | e.g. '2025-26' |
| vat_amount | NUMERIC(12,2) | NULL | | | |
| owner_id | UUID | NULL | | FK → app_user(id) | NULL = joint expense |
| work_order_id | UUID | NULL | | FK → work_order(id) | Links to generating work order |
| approval_status | VARCHAR(20) | NOT NULL | 'PENDING' | CHECK IN ('PENDING','APPROVED','REJECTED','VOIDED') | |
| active | BOOLEAN | NOT NULL | TRUE | | Soft-delete |
| deactivated_at | TIMESTAMPTZ | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: expense_allocation

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| expense_id | UUID | NOT NULL | | FK → expense(id) | |
| owner_id | UUID | NOT NULL | | FK → app_user(id) | |
| allocated_amount | NUMERIC(12,2) | NOT NULL | | CHECK (>= 0) | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |

**Unique**: `(expense_id, owner_id)`  
**Rule**: If no rows exist for an expense, default split follows `property_owner` current percentages. If rows exist, they override and must sum to `expense.amount` (application-enforced).

---

### New Table: contractor

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| name | VARCHAR(200) | NOT NULL | | | |
| company_name | VARCHAR(200) | NULL | | | |
| trade | VARCHAR(50) | NOT NULL | | CHECK IN ('ELECTRICIAN','GAS_ENGINEER','PLUMBER','GENERAL_BUILDER','CLEANER','LOCKSMITH','GLAZIER','ROOFER','PAINTER','CARPET_FITTER','GARDENER','OTHER') | |
| phone | VARCHAR(50) | NULL | | | |
| email | VARCHAR(320) | NULL | | | |
| notes | TEXT | NULL | | | |
| active | BOOLEAN | NOT NULL | TRUE | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: work_order

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| contractor_id | UUID | NULL | | FK → contractor(id) | Unassigned initially |
| title | VARCHAR(300) | NOT NULL | | | |
| description | TEXT | NULL | | | |
| category | VARCHAR(30) | NOT NULL | | CHECK IN ('REPAIR','MAINTENANCE','COMPLIANCE','INSPECTION','EMERGENCY','IMPROVEMENT') | |
| priority | VARCHAR(20) | NULL | | CHECK IN ('EMERGENCY','URGENT','ROUTINE','COSMETIC') | |
| raised_date | DATE | NOT NULL | CURRENT_DATE | | |
| scheduled_date | DATE | NULL | | | |
| completed_date | DATE | NULL | | | |
| labour_cost | NUMERIC(12,2) | NULL | | | |
| materials_cost | NUMERIC(12,2) | NULL | | | |
| total_cost | NUMERIC(12,2) | NULL | | | |
| status | VARCHAR(20) | NOT NULL | 'OPEN' | CHECK IN ('OPEN','SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED') | |
| raised_by_id | UUID | NULL | | FK → app_user(id) | |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: compliance_certificate

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| cert_type | VARCHAR(50) | NOT NULL | | CHECK IN ('GAS_SAFETY','EICR','EPC','PAT_TEST','FIRE_ALARM','EMERGENCY_LIGHTING','LEGIONELLA_RISK','HMO_LICENCE','SELECTIVE_LICENCE','SMOKE_ALARM','CO_ALARM','BOILER_SERVICE','INSURANCE','PROPERTY_INSPECTION','OTHER') | |
| issue_date | DATE | NULL | | | |
| expiry_date | DATE | NULL | | | |
| issued_by | VARCHAR(200) | NULL | | | |
| certificate_reference | VARCHAR(200) | NULL | | | |
| is_current | BOOLEAN | NOT NULL | TRUE | | |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: document

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| display_name | VARCHAR(500) | NOT NULL | | | User-facing name |
| original_filename | VARCHAR(500) | NULL | | | As uploaded |
| s3_bucket | VARCHAR(200) | NOT NULL | | | |
| s3_key | VARCHAR(1000) | NOT NULL | | | |
| content_type | VARCHAR(200) | NULL | | | MIME type |
| size_bytes | BIGINT | NULL | | | |
| sha256_hash | VARCHAR(64) | NULL | | | Duplicate detection |
| uploaded_at | TIMESTAMPTZ | NOT NULL | now() | | |
| uploaded_by_id | UUID | NULL | | FK → app_user(id) | |
| description | TEXT | NULL | | | |
| document_type | VARCHAR(50) | NOT NULL | | CHECK IN ('RECEIPT','INVOICE','LEASE_AGREEMENT','GAS_CERTIFICATE','EICR','EPC','PAT_REPORT','FIRE_ALARM_REPORT','EMERGENCY_LIGHTING_REPORT','INSPECTION_REPORT','CORRESPONDENCE','LEGAL','BANK_STATEMENT','TAX_DOCUMENT','CONTRACTOR_QUOTE','CONTRACTOR_INVOICE','PHOTO','AGENT_STATEMENT','INSURANCE_POLICY','MORTGAGE_DOCUMENT','OTHER') | |
| supplier_name | VARCHAR(200) | NULL | | | OCR-suggested or manual |
| extracted_text | TEXT | NULL | | | OCR output |
| upload_status | VARCHAR(30) | NOT NULL | 'UPLOADING' | CHECK IN ('UPLOADING','AVAILABLE','OCR_PENDING','OCR_PROCESSING','SEARCHABLE','UPLOAD_FAILED','OCR_FAILED') | |
| search_vector | TSVECTOR | NOT NULL | | GENERATED ALWAYS AS (to_tsvector('english', coalesce(display_name,'') \|\| ' ' \|\| coalesce(original_filename,'') \|\| ' ' \|\| coalesce(document_type,'') \|\| ' ' \|\| coalesce(supplier_name,'') \|\| ' ' \|\| coalesce(extracted_text,''))) STORED | Full-text search |
| active | BOOLEAN | NOT NULL | TRUE | | Soft-delete |
| deactivated_at | TIMESTAMPTZ | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: document_version

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| document_id | UUID | NOT NULL | | FK → document(id) | |
| version_number | INTEGER | NOT NULL | | | 1, 2, 3... |
| s3_key | VARCHAR(1000) | NOT NULL | | | |
| size_bytes | BIGINT | NULL | | | |
| sha256_hash | VARCHAR(64) | NULL | | | |
| uploaded_at | TIMESTAMPTZ | NOT NULL | now() | | |
| uploaded_by_id | UUID | NULL | | FK → app_user(id) | |

**Unique**: `(document_id, version_number)`

---

### New Table: document_link

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| document_id | UUID | NOT NULL | | FK → document(id) ON DELETE CASCADE | |
| entity_type | VARCHAR(50) | NOT NULL | | CHECK IN ('PROPERTY','EXPENSE','WORK_ORDER','COMPLIANCE_CERT','TENANCY','INCOME_LINE','CONTRACTOR','TAX_PACK','CORRESPONDENCE','INSPECTION','LEGAL_NOTICE','RENT_PAYMENT','AGENCY_AGREEMENT','AGENT_STATEMENT') | Target entity type |
| entity_id | UUID | NOT NULL | | | Target entity PK (no FK — polymorphic) |
| relationship | VARCHAR(50) | NOT NULL | 'ATTACHED_TO' | CHECK IN ('SUPPORTS','EVIDENCE_FOR','ATTACHED_TO','SOURCE_OF') | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |

**Unique**: `(document_id, entity_type, entity_id)` — prevent duplicate links

---

### New Table: correspondence

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| tenancy_id | UUID | NULL | | FK → tenancy(id) | |
| direction | VARCHAR(10) | NOT NULL | | CHECK IN ('INBOUND','OUTBOUND') | |
| channel | VARCHAR(20) | NOT NULL | | CHECK IN ('EMAIL','LETTER','SMS','PORTAL','PHONE') | |
| subject | VARCHAR(500) | NULL | | | |
| summary | TEXT | NULL | | | |
| correspondence_date | DATE | NOT NULL | | | |
| from_party | VARCHAR(200) | NULL | | | |
| to_party | VARCHAR(200) | NULL | | | |
| is_legal | BOOLEAN | NOT NULL | FALSE | | |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: legal_notice

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| tenancy_id | UUID | NULL | | FK → tenancy(id) | |
| notice_type | VARCHAR(50) | NOT NULL | | CHECK IN ('SECTION_21','SECTION_8','DEPOSIT_PRESCRIBED_INFO','RENT_INCREASE','INSPECTION_NOTICE','NOTICE_TO_QUIT','OTHER') | |
| served_date | DATE | NULL | | | |
| effective_date | DATE | NULL | | | |
| response_due_date | DATE | NULL | | | |
| status | VARCHAR(30) | NOT NULL | 'DRAFT' | CHECK IN ('DRAFT','SERVED','ACKNOWLEDGED','EXPIRED','WITHDRAWN','DISPUTED') | |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: inspection

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| tenancy_id | UUID | NULL | | FK → tenancy(id) | |
| inspection_type | VARCHAR(30) | NOT NULL | | CHECK IN ('MOVE_IN','PERIODIC','MOVE_OUT','EMERGENCY','PRE_LETTING') | |
| scheduled_date | DATE | NULL | | | |
| conducted_date | DATE | NULL | | | |
| conducted_by | VARCHAR(200) | NULL | | | Agent name or owner |
| overall_condition | VARCHAR(20) | NULL | | CHECK IN ('EXCELLENT','GOOD','FAIR','POOR') | |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: inspection_item

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| inspection_id | UUID | NOT NULL | | FK → inspection(id) ON DELETE CASCADE | |
| room_or_area | VARCHAR(200) | NOT NULL | | | |
| description | TEXT | NULL | | | |
| condition | VARCHAR(20) | NULL | | CHECK IN ('EXCELLENT','GOOD','FAIR','POOR','DAMAGED','MISSING') | |
| action_required | BOOLEAN | NOT NULL | FALSE | | |
| action_description | TEXT | NULL | | | |
| photo_document_id | UUID | NULL | | FK → document(id) | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |

---

### New Table: tenancy_deposit

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| tenancy_id | UUID | NOT NULL | | FK → tenancy(id), UNIQUE | One deposit per tenancy |
| amount | NUMERIC(12,2) | NOT NULL | | CHECK (>= 0) | |
| scheme | VARCHAR(30) | NOT NULL | | CHECK IN ('DPS','TDS','MYDEPOSITS','NONE') | |
| scheme_reference | VARCHAR(200) | NULL | | | |
| registered_date | DATE | NULL | | | |
| returned_date | DATE | NULL | | | |
| returned_amount | NUMERIC(12,2) | NULL | | | |
| deductions | NUMERIC(12,2) | NULL | | | |
| deduction_reason | TEXT | NULL | | | |
| status | VARCHAR(20) | NOT NULL | 'PENDING_REGISTRATION' | CHECK IN ('PENDING_REGISTRATION','HELD','RETURNED','DISPUTED') | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: agent_statement

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| agency_agreement_id | UUID | NOT NULL | | FK → agency_agreement(id) | |
| property_id | UUID | NOT NULL | | FK → property(id) | Denormalized for query convenience |
| statement_period_start | DATE | NOT NULL | | | |
| statement_period_end | DATE | NOT NULL | | CHECK (> statement_period_start) | |
| gross_rent | NUMERIC(12,2) | NULL | | | |
| management_fee | NUMERIC(12,2) | NULL | | | |
| other_deductions | NUMERIC(12,2) | NULL | | | |
| net_amount | NUMERIC(12,2) | NULL | | | |
| status | VARCHAR(30) | NOT NULL | 'UPLOADED' | CHECK IN ('UPLOADED','RECONCILED','PARTIALLY_RECONCILED','DISPUTED') | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: agent_statement_line

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| agent_statement_id | UUID | NOT NULL | | FK → agent_statement(id) ON DELETE CASCADE | |
| transaction_date | DATE | NOT NULL | | | |
| description | TEXT | NULL | | | |
| amount | NUMERIC(12,2) | NOT NULL | | | Signed: positive=income, negative=deduction |
| line_type | VARCHAR(30) | NOT NULL | | CHECK IN ('RENT','MANAGEMENT_FEE','REPAIR','INSURANCE','OTHER_DEDUCTION','TRANSFER') | |
| matched_income_id | UUID | NULL | | FK → income_line(id) | |
| matched_expense_id | UUID | NULL | | FK → expense(id) | |
| reconciliation_status | VARCHAR(30) | NOT NULL | 'UNMATCHED' | CHECK IN ('UNMATCHED','MATCHED','IGNORED','REVIEW_REQUIRED') | |
| match_confidence | NUMERIC(3,2) | NULL | | CHECK (NULL OR BETWEEN 0 AND 1) | System suggestion score (0.00–1.00) |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |

---

### New Table: tax_year

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| tax_year_label | VARCHAR(7) | NOT NULL | | UNIQUE | e.g. '2025-26' |
| start_date | DATE | NOT NULL | | | 6 April |
| end_date | DATE | NOT NULL | | CHECK (> start_date) | 5 April next year |
| status | VARCHAR(20) | NOT NULL | 'OPEN' | CHECK IN ('OPEN','CLOSED','FILED') | |
| locked_at | TIMESTAMPTZ | NULL | | | When status changed to CLOSED |
| locked_by_id | UUID | NULL | | FK → app_user(id) | Who locked |
| unlock_reason | TEXT | NULL | | | Required if reopened after lock |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

---

### New Table: tax_year_summary

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| property_id | UUID | NOT NULL | | FK → property(id) | |
| tax_year_id | UUID | NOT NULL | | FK → tax_year(id) | |
| owner_id | UUID | NOT NULL | | FK → app_user(id) | |
| gross_income | NUMERIC(12,2) | NOT NULL | 0 | | Sum of APPROVED income_line |
| allowable_expenses | NUMERIC(12,2) | NOT NULL | 0 | | Sum of APPROVED REVENUE expenses |
| finance_costs | NUMERIC(12,2) | NOT NULL | 0 | | FINANCE classification |
| capital_expenses | NUMERIC(12,2) | NOT NULL | 0 | | CAPITAL classification |
| net_profit | NUMERIC(12,2) | NOT NULL | 0 | | gross_income − allowable_expenses |
| owner_share_pct | NUMERIC(5,2) | NOT NULL | | | Snapshot of ownership % at tax year end |
| owner_net_profit | NUMERIC(12,2) | NOT NULL | 0 | | net_profit × owner_share_pct / 100 |
| personal_allowance_used | NUMERIC(12,2) | NULL | 0 | | User-entered |
| tax_due | NUMERIC(12,2) | NULL | 0 | | Calculated or user-entered |
| is_draft | BOOLEAN | NOT NULL | TRUE | | |
| notes | TEXT | NULL | | | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

**Unique**: `(property_id, tax_year_id, owner_id)`

---

### New Table: self_assessment_pack

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| tax_year_id | UUID | NOT NULL | | FK → tax_year(id) | |
| owner_id | UUID | NOT NULL | | FK → app_user(id) | |
| generated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| status | VARCHAR(20) | NOT NULL | 'DRAFT' | CHECK IN ('DRAFT','READY','SUBMITTED') | |
| submission_reference | VARCHAR(200) | NULL | | | HMRC ref if submitted externally |
| notes | TEXT | NULL | | | |
| generated_by_id | UUID | NULL | | FK → app_user(id) | |
| version | BIGINT | NOT NULL | 0 | | |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| updated_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |
| updated_by | UUID | NULL | | | |

**Unique**: `(tax_year_id, owner_id)`

---

### New Table: reminder_rule

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| target_type | VARCHAR(50) | NOT NULL | | | Entity type being reminded about |
| target_id | UUID | NOT NULL | | | Entity PK |
| reminder_type | VARCHAR(50) | NOT NULL | | | e.g. 'CERT_EXPIRY', 'RENT_OVERDUE' |
| days_before | INTEGER | NOT NULL | | | Days before due/expiry |
| recurrence | VARCHAR(30) | NOT NULL | | CHECK IN ('ONCE','DAILY','WEEKLY','MONTHLY','ANNUALLY') | |
| channel | VARCHAR(30) | NOT NULL | | CHECK IN ('IN_APP','EMAIL','SMS','NTFY') | One channel per rule |
| enabled | BOOLEAN | NOT NULL | TRUE | | |
| recipient | VARCHAR(320) | NULL | | | Email address / phone / ntfy topic |
| created_at | TIMESTAMPTZ | NOT NULL | now() | | |
| created_by | UUID | NULL | | | |

---

### New Table: reminder_instance

| Column | Type | Nullable | Default | Constraints | Description |
|--------|------|----------|---------|-------------|-------------|
| id | UUID | NOT NULL | gen_random_uuid() | PK | |
| reminder_rule_id | UUID | NOT NULL | | FK → reminder_rule(id) | |
| due_date | DATE | NOT NULL | | | |
| status | VARCHAR(30) | NOT NULL | 'PENDING' | CHECK IN ('PENDING','SENT','SNOOZED','COMPLETED','FAILED') | |
| sent_at | TIMESTAMPTZ | NULL | | | |
| snoozed_until | DATE | NULL | | | |
| completed_at | TIMESTAMPTZ | NULL | | | |

**Unique**: `(reminder_rule_id, due_date)`

---

## Index Strategy

| Table | Index Name | Type | Columns | Condition | Purpose |
|-------|-----------|------|---------|-----------|---------|
| property_owner | ix_propowner_current | B-tree | (property_id) | WHERE effective_to IS NULL | Fast current-owner lookup |
| property_owner | ix_propowner_owner | B-tree | (owner_id) | | Find all properties for an owner |
| agency_agreement | ix_agency_property | B-tree | (property_id) | WHERE active = TRUE | Active agreement per property |
| agent_fee_schedule | ix_agentfee_property | B-tree | (property_id, fee_type) | WHERE effective_to IS NULL | Current fee lookup |
| rent_schedule | ix_rentsched_tenancy | B-tree | (tenancy_id, effective_from DESC) | | Rent history |
| rent_payment | ix_rentpay_tenancy_due | B-tree | (tenancy_id, due_date DESC) | | Rent payment history |
| rent_payment | ix_rentpay_status | B-tree | (status) | WHERE status NOT IN ('PAID','WAIVED') | Outstanding payments |
| income_line | ix_income_prop_taxyear | B-tree | (property_id, tax_year) | WHERE active = TRUE | Tax aggregation |
| income_line | ix_income_received | B-tree | (received_date DESC) | | Recent income |
| expense | ix_expense_prop_taxyear | B-tree | (property_id, tax_year) | WHERE active = TRUE | Tax aggregation |
| expense | ix_expense_category | B-tree | (category) | | Category filtering |
| expense | ix_expense_date | B-tree | (expense_date DESC) | | Recent expenses |
| expense | ix_expense_approval | B-tree | (approval_status) | WHERE approval_status = 'PENDING' | Pending approvals dashboard |
| expense | ix_expense_workorder | B-tree | (work_order_id) | WHERE work_order_id IS NOT NULL | Work order → expense lookup |
| compliance_certificate | ix_compliance_expiry | B-tree | (property_id, cert_type, expiry_date) | WHERE is_current = TRUE | Expiry alerting (60-day window) |
| document | ix_document_search | GIN | (search_vector) | | Full-text search |
| document | ix_document_type | B-tree | (document_type) | WHERE active = TRUE | Type filtering |
| document | ix_document_sha256 | B-tree | (sha256_hash) | WHERE sha256_hash IS NOT NULL | Duplicate detection |
| document | ix_document_supplier_trgm | GIN | (supplier_name gin_trgm_ops) | | Fuzzy supplier name search |
| document_link | ix_doclink_entity | B-tree | (entity_type, entity_id) | | Find documents for any entity |
| document_link | ix_doclink_document | B-tree | (document_id) | | Find all links for a document |
| work_order | ix_wo_property_status | B-tree | (property_id, status) | | Active work orders per property |
| work_order | ix_wo_contractor | B-tree | (contractor_id) | WHERE contractor_id IS NOT NULL | Contractor's work history |
| correspondence | ix_corr_prop_date | B-tree | (property_id, correspondence_date DESC) | | Recent correspondence |
| legal_notice | ix_legal_prop | B-tree | (property_id, tenancy_id) | | Legal notices per property/tenancy |
| inspection | ix_insp_prop_date | B-tree | (property_id, conducted_date DESC) | | Inspection history |
| agent_statement | ix_agstmt_prop_period | B-tree | (property_id, statement_period_start DESC) | | Statement history |
| agent_statement_line | ix_agstmtline_recon | B-tree | (reconciliation_status) | WHERE reconciliation_status IN ('UNMATCHED','REVIEW_REQUIRED') | Unreconciled lines |
| tax_year_summary | ix_taxsum_taxyear | B-tree | (tax_year_id, property_id) | | Tax reporting |
| reminder_instance | ix_reminder_pending | B-tree | (due_date) | WHERE status = 'PENDING' | Scheduled job pickup |
| tenancy | ix_tenancy_overlap (GiST) | GiST exclusion | (property_id, daterange(...)) | WHERE status NOT IN ('ENDED','CANCELLED') | Overlap prevention |

---

## Cross-Cutting Conventions

### Audit Columns
Every mutable table includes:
- `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` — set once at creation
- `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()` — updated on every mutation
- `created_by UUID` — app_user.id, set by Spring Data JPA `@CreatedBy`
- `updated_by UUID` — app_user.id, set by `@LastModifiedBy`
- Auditor resolution: `AuditorAware<UUID>` delegates to the `CurrentActorProvider` SPI (rental-shared), implemented in rental-identity by mapping JWT `iss` + `sub` → `app_user.id` (JIT-provisioning if needed). Columns are plain UUIDs (no DB FK) so core tables stay decoupled from identity.

### Security & Identity
- Spring Security OAuth2 resource server (`spring-boot-starter-oauth2-resource-server`), `issuer-uri` = Keycloak realm; JWT signature, `iss`, `exp` and audience are validated on every request.
- Authorities come from Keycloak JWT claims (`realm_access.roles`, `resource_access.<client>.roles`) via a custom `JwtAuthenticationConverter`; precedence ADMIN > LANDLORD > ACCOUNTANT > FAMILY_VIEWER via `RoleHierarchy`. Nothing role-related is persisted.
- The database never stores usernames, passwords, credentials or roles. See *Responsibility boundary: Keycloak vs application* (Context 1).

Child/immutable tables (expense_allocation, document_version, document_link, inspection_item, agent_statement_line) have only `created_at` and `created_by`.

### Optimistic Locking
- Every aggregate root: `version BIGINT NOT NULL DEFAULT 0`
- JPA `@Version` annotation; Hibernate auto-increments
- API returns version in response; PUT/DELETE require matching version → 409 Conflict on mismatch

### Soft-Delete
- Pattern: `active BOOLEAN NOT NULL DEFAULT TRUE` (consistent with V1 property/app_user)
- Optional `deactivated_at TIMESTAMPTZ` for audit trail
- Applied to: property, app_user, agency_agreement, income_line, expense, document, contractor
- Entities where soft-delete is NOT needed (historical records by nature): rent_payment, rent_schedule, audit_event, compliance_certificate, correspondence, legal_notice, inspection, tax_year, tax_year_summary, agent_statement

### Money
- All monetary amounts: `NUMERIC(12,2)` — never FLOAT/DOUBLE
- Fee percentages: `NUMERIC(7,4)` — e.g. 10.5000%
- Ownership percentages: `NUMERIC(5,2)` — e.g. 50.00%
- Match confidence: `NUMERIC(3,2)` — 0.00 to 1.00
- Java: `BigDecimal`; API: decimal string

### Enum Strategy
- **Existing V1**: PostgreSQL CREATE TYPE enums (property_type, tenancy_status) — kept as-is; `user_role` removed (roles come from Keycloak JWT claims)
- **All new columns**: `VARCHAR(n) + CHECK` constraint — avoids ALTER TYPE migration issues
- **Java**: Java enums with `@Enumerated(EnumType.STRING)` + `@Column(columnDefinition = "VARCHAR(50)")`

---

## Reporting Anchors

### Self-Assessment (SA105)
- **Income source**: `income_line` WHERE `tax_year = X AND active = TRUE`
- **Expense source**: `expense` WHERE `tax_year = X AND active = TRUE AND approval_status = 'APPROVED'`, grouped by `tax_classification` (REVENUE → allowable, CAPITAL → capital allowances, FINANCE → finance costs, PRIVATE → excluded, UNKNOWN → exceptions)
- **Owner split**: `property_owner` WHERE `effective_to IS NULL` → `ownership_pct` applied to property totals
- **Aggregation**: `tax_year_summary` per (property × owner × tax_year)
- **Output**: `self_assessment_pack` → linked via `document_link` to generated PDF/CSV
- **Locking**: `tax_year.status = 'CLOSED'` prevents further income/expense modifications for that year

### Agent Fee Reconciliation
- **Expected management fees**: `agent_fee_schedule` (MANAGEMENT_MONTHLY_PCT) × `rent_payment.amount_paid` for each month
- **Actual fees charged**: `agent_statement_line` WHERE `line_type = 'MANAGEMENT_FEE'`
- **Reconciliation flow**: Semi-automated matching by amount (± tolerance) and date proximity → `match_confidence` score → user confirms/overrides → `reconciliation_status` updated
- **Discrepancy detection**: Unmatched lines, fee differences, missing statements surfaced in dashboard

### Compliance Alerts
- **Query**: `compliance_certificate WHERE is_current = TRUE AND expiry_date <= (CURRENT_DATE + INTERVAL '60 days')`
- **Feed**: Results feed `reminder_rule` / `reminder_instance` pipeline
- **Report**: Compliance status dashboard per property with certificate type, expiry countdown, renewal action

---

## Flyway Migration Plan

| Migration | Scope | Description |
|-----------|-------|-------------|
| V2 | V1 extensions | Add version to app_user/property/tenancy/tenant; app_user identity-anchor shape (idp_issuer, no username/role); btree_gist + GiST exclusion; audit_event entity_type/entity_id |
| V3 | Property & Ownership | property_owner, agency_agreement, agent_fee_schedule; seed property_owner from existing ownership_percentage |
| V4 | Tenancy & Rent | rent_schedule, rent_payment, tenancy_deposit; seed rent_schedule from tenancy.monthly_rent |
| V5 | Finance | income_line, expense, expense_allocation |
| V6 | Maintenance & Compliance | contractor, work_order, compliance_certificate, inspection, inspection_item |
| V7 | Documents | document, document_version, document_link; GIN search index |
| V8 | Communication & Legal | correspondence, legal_notice |
| V9 | Agency Reconciliation | agent_statement, agent_statement_line |
| V10 | Tax & Reporting | tax_year, tax_year_summary, self_assessment_pack |
| V11 | Reminders | reminder_rule, reminder_instance |

Each migration is independently deployable. Tables without dependent application code are inert until services are implemented.

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Orphaned document_link rows (no FK on entity_id) | Application-layer existence check on create; scheduled consistency-check job; CASCADE delete from document side |
| Property.ownershipPercentage deprecation breaks existing API | Keep column; application reads from property_owner; PropertyResponse computes from property_owner during migration window |
| GiST exclusion constraint conflicts with app-layer overlap check | Remove app-layer check; rely solely on DB constraint; catch exclusion-violation exception → 409 Conflict |
| 22 new tables in one design iteration | Split into 10 separate Flyway migrations by bounded context; implement incrementally; inert until application code written |
| tax_year_summary aggregation accuracy | Summary rows always is_draft=TRUE until reviewed; recalculation on approved income/expense change; never auto-used for tax filing |
| Historical audit display uses cached names | `audit_event.actor_display_name` and `app_user.display_name` are snapshots; a user renamed in Keycloak shows the old name on past events (by design: point-in-time record) and the new name on `app_user` after next login. `actor_id` remains the authoritative link |
| Stale roles after change in Keycloak | Roles live only in the token; keep access-token lifetime short (e.g. 5–15 min) so changes propagate on refresh |
| Expense allocation sum validation | Application-layer check: expense_allocation rows must sum to expense.amount; validation in service layer with clear error message |

---

## Open Design Decisions

None remaining — all questions resolved.

### Decision Log — Identity (Keycloak / OAuth2)

| # | Decision | Rationale |
|---|----------|-----------|
| D-ID-1 | Keycloak owns authentication (login, passwords, MFA, IdP accounts); **`username` is not stored** | Single source of truth; no credential data in the app DB; usernames can change in Keycloak |
| D-ID-2 | **Roles come from Keycloak JWT claims**; no role column, `user_role` enum or role tables | App uses the JWT / OAuth2 token workflow; authorities mapped by `JwtAuthenticationConverter`, precedence by `RoleHierarchy` |
| D-ID-3 | `app_user` = identity anchor keyed by `UNIQUE(idp_issuer, idp_subject)`, JIT upsert on first authenticated request | Stable UUID target for FKs and audit; multi-realm safe |
| D-ID-4 | `display_name` / `email` cached as nullable, non-unique snapshots refreshed from token claims | Show "edited by John" without calling Keycloak. Trade-off: historical audit display uses the cached snapshot, not the live Keycloak name |
| D-ID-5 | Claims are read from the **access token** (resource server never sees the ID token) | Keycloak mappers must add profile claims to the access token |
| D-ID-6 | `rental-core` does not depend on `rental-identity`; actor id via `CurrentActorProvider` SPI in `rental-shared` | Keeps the domain core independent of the identity mechanism |
