package org.skaria.rentalmanagement.identity;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface AppUserRepository extends JpaRepository<AppUser, UUID> {

    Optional<AppUser> findByIdpIssuerAndIdpSubject(
            String idpIssuer,
            String idpSubject
    );
}