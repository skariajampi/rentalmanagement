package org.skaria.rentalmanagement.identity;

import jakarta.persistence.*;
import lombok.*;
import org.hibernate.annotations.UuidGenerator;

import java.time.OffsetDateTime;
import java.util.UUID;

@Entity
@Table(
        name = "app_user",
        uniqueConstraints = @UniqueConstraint(
                name = "uq_app_user_idp", columnNames = {"idp_issuer", "idp_subject"})
)
@Getter
@Setter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@ToString(onlyExplicitlyIncluded = true)
@EqualsAndHashCode(onlyExplicitlyIncluded = true)
public class AppUser {

    @Id
    @UuidGenerator
    @Column(name = "id", updatable = false, nullable = false)
    @ToString.Include
    @EqualsAndHashCode.Include
    private UUID id;

    @Column(name = "idp_issuer", nullable = false, updatable = false)
    private String idpIssuer;

    @Column(name = "idp_subject", nullable = false, updatable = false)
    private String idpSubject;

    @Column(name = "display_name", length = 200)
    private String displayName;

    @Column(name = "email", length = 320)
    private String email;

    @Column(name = "first_seen_at", nullable = false, updatable = false)
    private OffsetDateTime firstSeenAt;

    @Column(name = "last_seen_at", nullable = false)
    private OffsetDateTime lastSeenAt;

    @Version
    @Column(name = "version", nullable = false)
    private long version;

    public static AppUser firstSeen(String issuer, String subject,
                                    String displayName, String email,
                                    OffsetDateTime now) {
        AppUser u = new AppUser();
        u.idpIssuer = issuer;
        u.idpSubject = subject;
        u.displayName = displayName;
        u.email = email;
        u.firstSeenAt = now;
        u.lastSeenAt = now;
        return u;
    }

    public void seen(String displayName, String email, OffsetDateTime now) {
        this.displayName = displayName;
        this.email = email;
        this.lastSeenAt = now;
    }
}