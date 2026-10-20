package org.skaria.rentalmanagement.tenancy;

import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import lombok.*;
import org.skaria.rentalmanagement.shared.Auditable;
import org.skaria.rentalmanagement.shared.TenancyStatus;
import org.hibernate.annotations.UuidGenerator;
import org.skaria.rentalmanagement.property.Property;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * A tenancy agreement linked to a {@link Property}.
 *
 * <p><b>Status machine</b> (validated in service layer, every transition audited):
 * <pre>
 *   DRAFT → ACTIVE | CANCELLED
 *   ACTIVE → NOTICE | ENDED
 *   NOTICE → ENDED
 *   ENDED, CANCELLED — terminal
 * </pre>
 *
 * <p>The service layer additionally rejects overlapping non-ended tenancies for the same property.
 *
 * <p>Maps to table {@code tenancy}.
 */
@Entity
@Table(name = "tenancy")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
@ToString(onlyExplicitlyIncluded = true)
@EqualsAndHashCode(onlyExplicitlyIncluded = true, callSuper = false)
public class Tenancy extends Auditable {

    @Id
    @UuidGenerator
    @Column(name = "id", updatable = false, nullable = false)
    @ToString.Include
    @EqualsAndHashCode.Include
    private UUID id;

    @NotNull
    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "property_id", nullable = false,
                foreignKey = @ForeignKey(name = "fk_tenancy_property"))
    private Property property;

    @NotNull
    @Column(name = "start_date", nullable = false)
    private LocalDate startDate;

    /**
     * Null until the tenancy ends. Must be set when transitioning to {@code ENDED}.
     */
    @Column(name = "end_date")
    private LocalDate endDate;

    /**
     * Monthly rent. {@code NUMERIC(12,2)} — never floating point.
     */
    @NotNull
    @DecimalMin("0.00")
    @Digits(integer = 10, fraction = 2)
    @Column(name = "monthly_rent", nullable = false, precision = 12, scale = 2)
    private BigDecimal monthlyRent;

    /**
     * Day of month the rent is due (1–31). Null if not specified.
     */
    @Min(1) @Max(31)
    @Column(name = "payment_day")
    private Integer paymentDay;

    @DecimalMin("0.00")
    @Digits(integer = 10, fraction = 2)
    @Column(name = "deposit_amount", precision = 12, scale = 2)
    private BigDecimal depositAmount;

    /** UK Tenancy Deposit Protection scheme name (e.g. DPS, TDS, mydeposits). */
    @Size(max = 150)
    @Column(name = "deposit_scheme", length = 150)
    private String depositScheme;

    @Size(max = 150)
    @Column(name = "deposit_reference", length = 150)
    private String depositReference;

    @NotNull
    @Enumerated(EnumType.STRING)
    @Column(name = "status", nullable = false,
            columnDefinition = "tenancy_status")
    @Builder.Default
    private TenancyStatus status = TenancyStatus.DRAFT;

    /**
     * Phase 2 document module reference. Null until the document module is wired.
     */
    @Column(name = "agreement_document_id")
    private UUID agreementDocumentId;

    @Column(name = "notes", columnDefinition = "TEXT")
    private String notes;

    // -------------------------------------------------------------------------
    // Relationships
    // -------------------------------------------------------------------------

    @OneToMany(mappedBy = "tenancy", cascade = CascadeType.ALL, orphanRemoval = true,
               fetch = FetchType.LAZY)
    @Builder.Default
    private List<Tenant> tenants = new ArrayList<>();
}
