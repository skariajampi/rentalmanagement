package org.skaria.rentalmanagement.property;

import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import lombok.*;
import org.skaria.rentalmanagement.shared.Auditable;
import org.skaria.rentalmanagement.shared.PropertyType;
import org.hibernate.annotations.UuidGenerator;
import org.skaria.rentalmanagement.tenancy.Tenancy;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * Managed rental property.
 *
 * <p>Soft-deleted via {@code active = false}. The API rejects deactivation while the
 * property still has non-ended tenancies (enforced in the service layer).
 *
 * <p>Maps to table {@code property}.
 */
@Entity
@Table(
    name = "property",
    uniqueConstraints = {
        @UniqueConstraint(name = "uq_property_reference", columnNames = "property_reference")
    }
)
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
@ToString(onlyExplicitlyIncluded = true)
@EqualsAndHashCode(onlyExplicitlyIncluded = true, callSuper = false)
public class Property extends Auditable {

    @Id
    @UuidGenerator
    @Column(name = "id", updatable = false, nullable = false)
    @ToString.Include
    @EqualsAndHashCode.Include
    private UUID id;

    /**
     * Immutable business key assigned at creation (e.g. {@code PROP-001}).
     * Uniqueness enforced by DB constraint; never mutated after CREATE.
     */
    @NotBlank
    @Size(max = 50)
    @Column(name = "property_reference", nullable = false, length = 50, updatable = false)
    @ToString.Include
    private String propertyReference;

    @Size(max = 200)
    @Column(name = "property_name", length = 200)
    private String propertyName;

    @NotBlank
    @Size(max = 200)
    @Column(name = "address_line1", nullable = false, length = 200)
    private String addressLine1;

    @Size(max = 200)
    @Column(name = "address_line2", length = 200)
    private String addressLine2;

    @Size(max = 100)
    @Column(name = "town", length = 100)
    private String town;

    @Size(max = 100)
    @Column(name = "county", length = 100)
    private String county;

    @NotBlank
    @Size(max = 12)
    @Column(name = "postcode", nullable = false, length = 12)
    private String postcode;

    @Enumerated(EnumType.STRING)
    @Column(name = "property_type", columnDefinition = "property_type")
    private PropertyType propertyType;

    @Column(name = "purchase_date")
    private LocalDate purchaseDate;

    /**
     * Purchase price. Stored as {@code NUMERIC(12,2)} — never {@code FLOAT}.
     * Corresponds to the OpenAPI {@code Money} schema (decimal string mapped here to BigDecimal).
     */
    @DecimalMin(value = "0.00")
    @Digits(integer = 10, fraction = 2)
    @Column(name = "purchase_price", precision = 12, scale = 2)
    private BigDecimal purchasePrice;

    /**
     * Owner's share of this property in percent (0 < x ≤ 100). Defaults to 100.
     */
    @NotNull
    @DecimalMin(value = "0.01", inclusive = true)
    @DecimalMax(value = "100.00", inclusive = true)
    @Digits(integer = 3, fraction = 2)
    @Column(name = "ownership_percentage", nullable = false, precision = 5, scale = 2)
    @Builder.Default
    private BigDecimal ownershipPercentage = BigDecimal.valueOf(100, 0);

    @Column(name = "notes", columnDefinition = "TEXT")
    private String notes;

    /**
     * Soft-delete flag. {@code false} when deactivated via DELETE /properties/{id}.
     */
    @Column(name = "active", nullable = false)
    @Builder.Default
    private boolean active = true;

    // -------------------------------------------------------------------------
    // Relationships
    // -------------------------------------------------------------------------

    @OneToMany(mappedBy = "property", cascade = CascadeType.ALL, orphanRemoval = false,
               fetch = FetchType.LAZY)
    @Builder.Default
    private List<Tenancy> tenancies = new ArrayList<>();
}
