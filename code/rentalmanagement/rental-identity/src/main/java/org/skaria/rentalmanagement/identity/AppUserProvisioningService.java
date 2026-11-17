package org.skaria.rentalmanagement.identity;

import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.OffsetDateTime;

@Service
public class AppUserProvisioningService {

    private final EntityManager entityManager;
    private final Clock clock;

    public AppUserProvisioningService(
            EntityManager entityManager,
            Clock clock
    ) {
        this.entityManager = entityManager;
        this.clock = clock;
    }

    @Transactional
    public void provision(
            String issuer,
            String subject,
            String displayName,
            String email
    ) {
        var now = OffsetDateTime.now(clock);

        entityManager.createNativeQuery("""
                INSERT INTO app_user (
                    idp_issuer,
                    idp_subject,
                    display_name,
                    email,
                    first_seen_at,
                    last_seen_at,
                    version
                )
                VALUES (
                    :issuer,
                    :subject,
                    :displayName,
                    :email,
                    :now,
                    :now,
                    0
                )
                ON CONFLICT (idp_issuer, idp_subject)
                DO UPDATE SET
                    display_name = EXCLUDED.display_name,
                    email = EXCLUDED.email,
                    last_seen_at = GREATEST(
                        app_user.last_seen_at,
                        EXCLUDED.last_seen_at
                    ),
                    version = app_user.version + 1
                """)
                .setParameter("issuer", issuer)
                .setParameter("subject", subject)
                .setParameter("displayName", displayName)
                .setParameter("email", email)
                .setParameter("now", now)
                .executeUpdate();
    }
}