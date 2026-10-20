package org.skaria.rentalmanagement.shared;

/**
 * Maps to the {@code tenancy_status} PostgreSQL enum.
 *
 * <p>Allowed server-side transitions (validated in TenancyService, audited):</p>
 * <pre>
 *   DRAFT  → ACTIVE | CANCELLED
 *   ACTIVE → NOTICE | ENDED
 *   NOTICE → ENDED
 *   ENDED and CANCELLED are terminal.
 * </pre>
 */
public enum TenancyStatus {
    DRAFT,
    ACTIVE,
    NOTICE,
    ENDED,
    CANCELLED
}
