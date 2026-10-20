package org.skaria.rentalmanagement.shared;

import jakarta.persistence.*;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.annotations.UuidGenerator;
import org.hibernate.type.SqlTypes;

import java.net.InetAddress;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Append-only audit trail entry.
 *
 * <p>Written by every mutating API operation via the shared auditing module.
 * The table has no {@code UPDATE} or {@code DELETE} grants in production.
 *
 * <p>Maps to table {@code audit_event}.
 *
 * <p><b>Usage example</b> (in a service):
 * <pre>{@code
 * auditEventRepository.save(AuditEvent.builder()
 *     .actorId(currentUser.getId())
 *     .actorUsername(currentUser.getUsername())
 *     .eventType("PROPERTY_CREATED")
 *     .aggregateType("PROPERTY")
 *     .aggregateId(property.getId())
 *     .afterState(Map.of("id", property.getId(), "reference", property.getPropertyReference()))
 *     .build());
 * }</pre>
 */
@Entity
@Table(
    name = "audit_event",
    indexes = {
        @Index(name = "ix_audit_aggregate", columnList = "aggregate_type, aggregate_id, occurred_at DESC"),
        @Index(name = "ix_audit_actor",     columnList = "actor_id, occurred_at DESC"),
        @Index(name = "ix_audit_occurred",  columnList = "occurred_at DESC")
    }
)
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
@ToString(onlyExplicitlyIncluded = true)
@EqualsAndHashCode(onlyExplicitlyIncluded = true)
public class AuditEvent {

    @Id
    @UuidGenerator
    @Column(name = "id", updatable = false, nullable = false)
    @ToString.Include
    @EqualsAndHashCode.Include
    private UUID id;

    @Column(name = "occurred_at", nullable = false, updatable = false,
            columnDefinition = "TIMESTAMPTZ")
    @Builder.Default
    private Instant occurredAt = Instant.now();

    /** {@code app_user.id} of the authenticated actor. Null for system/service events. */
    @Column(name = "actor_id", updatable = false)
    private UUID actorId;

    /** Denormalised username for query convenience; avoids joins on the audit trail. */
    @Column(name = "actor_username", updatable = false, length = 100)
    private String actorUsername;

    /**
     * Domain event name, e.g. {@code PROPERTY_CREATED}, {@code TENANCY_STATUS_CHANGED}.
     * Convention: {@code AGGREGATE_VERB} in UPPER_SNAKE_CASE.
     */
    @NotBlank
    @Column(name = "event_type", nullable = false, updatable = false, length = 100)
    @ToString.Include
    private String eventType;

    /**
     * Aggregate root type, e.g. {@code PROPERTY}, {@code TENANCY}, {@code TENANT}.
     */
    @NotBlank
    @Column(name = "aggregate_type", nullable = false, updatable = false, length = 50)
    private String aggregateType;

    @NotNull
    @Column(name = "aggregate_id", nullable = false, updatable = false)
    private UUID aggregateId;

    /** JSONB snapshot of the row state before the mutation. Null for CREATE events. */
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "before_state", columnDefinition = "JSONB", updatable = false)
    private Map<String, Object> beforeState;

    /** JSONB snapshot of the row state after the mutation. Null for DELETE events. */
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "after_state", columnDefinition = "JSONB", updatable = false)
    private Map<String, Object> afterState;

    @Column(name = "ip_address", updatable = false,
            columnDefinition = "INET")
    private InetAddress ipAddress;

    /** OpenTelemetry / MDC trace ID for log correlation. */
    @Column(name = "trace_id", updatable = false, length = 64)
    private String traceId;
}
