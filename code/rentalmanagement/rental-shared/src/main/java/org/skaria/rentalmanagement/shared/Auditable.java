package org.skaria.rentalmanagement.shared;

import jakarta.persistence.Column;
import jakarta.persistence.EntityListeners;
import jakarta.persistence.MappedSuperclass;
import lombok.Getter;
import lombok.Setter;
import org.springframework.data.annotation.CreatedBy;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.LastModifiedBy;
import org.springframework.data.annotation.LastModifiedDate;
import org.springframework.data.jpa.domain.support.AuditingEntityListener;

import java.time.Instant;
import java.util.UUID;

/**
 * Shared auditing base class.
 *
 * <p>Every entity extends this class so that Spring Data JPA's
 * {@code @EnableJpaAuditing} populates the four audit columns automatically.
 *
 * <p>Wire {@code AuditorAware<UUID>} bean in your security config to supply
 * the current authenticated {@code app_user.id} (resolved from the Keycloak
 * JWT {@code sub} claim via the JIT-synced app_user row).
 *
 * <pre>{@code
 * @Bean
 * AuditorAware<UUID> auditorProvider(AppUserRepository repo) {
 *     return () -> Optional.ofNullable(SecurityContextHolder.getContext().getAuthentication())
 *         .filter(Authentication::isAuthenticated)
 *         .map(auth -> repo.findByIdpSubject(auth.getName()).map(AppUser::getId).orElse(null));
 * }
 * }</pre>
 */
@Getter
@Setter
@MappedSuperclass
@EntityListeners(AuditingEntityListener.class)
public abstract class Auditable {

    @CreatedDate
    @Column(name = "created_at", nullable = false, updatable = false,
            columnDefinition = "TIMESTAMPTZ")
    private Instant createdAt;

    @LastModifiedDate
    @Column(name = "updated_at", nullable = false,
            columnDefinition = "TIMESTAMPTZ")
    private Instant updatedAt;

    /** ID of the app_user who created this row. */
    @CreatedBy
    @Column(name = "created_by", updatable = false)
    private UUID createdBy;

    /** ID of the app_user who last modified this row. */
    @LastModifiedBy
    @Column(name = "updated_by")
    private UUID updatedBy;
}
