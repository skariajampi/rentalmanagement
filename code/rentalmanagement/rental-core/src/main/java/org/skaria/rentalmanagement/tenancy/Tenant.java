package org.skaria.rentalmanagement.tenancy;

import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import lombok.*;
import org.skaria.rentalmanagement.shared.Auditable;
import org.hibernate.annotations.UuidGenerator;

import java.time.LocalDate;
import java.util.UUID;

/**
 * An individual tenant linked to a {@link Tenancy}.
 *
 * <p>Only what management and reporting require is stored here (privacy requirement, §3).
 * To record a tenant leaving, set {@code moveOutDate} via PUT rather than deleting the record.
 *
 * <p>Maps to table {@code tenant}.
 */
@Entity
@Table(name = "tenant")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
@ToString(onlyExplicitlyIncluded = true)
@EqualsAndHashCode(onlyExplicitlyIncluded = true, callSuper = false)
public class Tenant extends Auditable {

    @Id
    @UuidGenerator
    @Column(name = "id", updatable = false, nullable = false)
    @ToString.Include
    @EqualsAndHashCode.Include
    private UUID id;

    @NotNull
    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "tenancy_id", nullable = false,
                foreignKey = @ForeignKey(name = "fk_tenant_tenancy"))
    private Tenancy tenancy;

    @NotBlank
    @Size(max = 200)
    @Column(name = "full_name", nullable = false, length = 200)
    @ToString.Include
    private String fullName;

    @Email
    @Size(max = 320)
    @Column(name = "email", length = 320)
    private String email;

    @Size(max = 50)
    @Column(name = "phone", length = 50)
    private String phone;

    @Column(name = "move_in_date")
    private LocalDate moveInDate;

    /**
     * Null while the tenant is still active. Set via PUT to record departure; prefer over DELETE.
     */
    @Column(name = "move_out_date")
    private LocalDate moveOutDate;

    @Size(max = 200)
    @Column(name = "emergency_contact_name", length = 200)
    private String emergencyContactName;

    @Size(max = 50)
    @Column(name = "emergency_contact_phone", length = 50)
    private String emergencyContactPhone;

    @Column(name = "notes", columnDefinition = "TEXT")
    private String notes;
}
