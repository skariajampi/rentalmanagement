package org.skaria.rentalmanagement.identity;

import jakarta.persistence.*;
import lombok.*;
import org.skaria.rentalmanagement.shared.Auditable;
import org.skaria.rentalmanagement.shared.UserRole;
import org.hibernate.annotations.UuidGenerator;

import java.util.UUID;

/**
 * JIT snapshot of a Keycloak user, keyed by {@code idpSubject} (Keycloak {@code sub} claim).
 *
 * <p>This record is <em>read-only</em> through the API. Creating, disabling and role changes
 * happen in Keycloak; the row is upserted here on the user's next login via the
 * {@code /me} endpoint.
 *
 * <p>Maps to table {@code app_user}.
 */
@Entity
@Table(
    name = "app_user",
    uniqueConstraints = {
        @UniqueConstraint(name = "uq_app_user_username",    columnNames = "username"),
        @UniqueConstraint(name = "uq_app_user_idp_subject", columnNames = "idp_subject")
    }
)
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
@ToString(onlyExplicitlyIncluded = true)
@EqualsAndHashCode(onlyExplicitlyIncluded = true, callSuper = false)
public class AppUser extends Auditable {

    @Id
    @UuidGenerator
    @Column(name = "id", updatable = false, nullable = false)
    @ToString.Include
    @EqualsAndHashCode.Include
    private UUID id;

    /**
     * Keycloak {@code preferred_username}.
     */
    @Column(name = "username", nullable = false, length = 100)
    @ToString.Include
    private String username;

    /**
     * Keycloak {@code name} claim (given_name + family_name or display name).
     */
    @Column(name = "display_name", nullable = false, length = 200)
    private String displayName;

    @Column(name = "email", length = 320)
    private String email;

    /**
     * Mapped from Keycloak {@code realm_access.roles}.
     * ADMIN and LANDLORD have write access; FAMILY_VIEWER and ACCOUNTANT are read-only.
     */
    @Enumerated(EnumType.STRING)
    @Column(name = "role", nullable = false,
            columnDefinition = "user_role")
    private UserRole role;

    /**
     * Soft-active flag. Keycloak controls the source of truth; this mirrors it.
     */
    @Column(name = "active", nullable = false)
    @Builder.Default
    private boolean active = true;

    /**
     * Keycloak {@code sub} claim. Populated on first login; immutable thereafter.
     */
    @Column(name = "idp_subject", updatable = false, length = 255)
    private String idpSubject;
}
