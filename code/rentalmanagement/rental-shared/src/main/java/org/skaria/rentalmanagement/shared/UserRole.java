package org.skaria.rentalmanagement.shared;

/**
 * Maps to the {@code user_role} PostgreSQL enum and Keycloak realm roles.
 * Roles ADMIN and LANDLORD have write access; FAMILY_VIEWER and ACCOUNTANT are read-only.
 */
public enum UserRole {
    ADMIN,
    LANDLORD,
    FAMILY_VIEWER,
    ACCOUNTANT
}
