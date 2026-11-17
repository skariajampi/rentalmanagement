package org.skaria.rentalmanagement.identity;

import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.client.oidc.userinfo.OidcUserRequest;
import org.springframework.security.oauth2.client.oidc.userinfo.OidcUserService;
import org.springframework.security.oauth2.core.OAuth2AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.stereotype.Service;

import java.util.Collection;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

@Service
public class RentalOidcUserService extends OidcUserService {

    private static final Set<String> APPLICATION_ROLES =
            Set.of("ADMIN", "LANDLORD", "FAMILY_VIEWER");

    private final AppUserProvisioningService provisioningService;

    public RentalOidcUserService(
            AppUserProvisioningService provisioningService
    ) {
        this.provisioningService = provisioningService;
    }

    @Override
    public OidcUser loadUser(OidcUserRequest request) {
        OidcUser user = super.loadUser(request);

        Set<GrantedAuthority> applicationAuthorities =
                applicationAuthorities(user);

        if (applicationAuthorities.isEmpty()) {
            throw new OAuth2AuthenticationException(
                    new OAuth2Error("access_denied"),
                    "No application role has been assigned."
            );
        }

        String displayName = user.getFullName();
        String email = user.getEmail();

        if ((displayName != null && displayName.length() > 200)
                || (email != null && email.length() > 320)) {
            throw new OAuth2AuthenticationException(
                    new OAuth2Error("invalid_user_info"),
                    "Identity claims exceed supported lengths."
            );
        }

        provisioningService.provision(
                user.getIdToken().getIssuer().toString(),
                user.getSubject(),
                displayName,
                email
        );

        Set<GrantedAuthority> authorities =
                new HashSet<>(user.getAuthorities());

        authorities.addAll(applicationAuthorities);

        if (user.getUserInfo() == null) {
            return new DefaultOidcUser(
                    authorities,
                    user.getIdToken()
            );
        }

        return new DefaultOidcUser(
                authorities,
                user.getIdToken(),
                user.getUserInfo()
        );
    }

    private static Set<GrantedAuthority> applicationAuthorities(
            OidcUser user
    ) {
        Set<GrantedAuthority> result = new HashSet<>();

        Object realmAccess =
                user.getIdToken().getClaims().get("realm_access");

        if (realmAccess instanceof Map<?, ?> access
                && access.get("roles") instanceof Collection<?> roles) {
            for (Object candidate : roles) {
                if (candidate instanceof String role
                        && APPLICATION_ROLES.contains(role)) {
                    result.add(
                            new SimpleGrantedAuthority("ROLE_" + role)
                    );
                }
            }
        }

        return result;
    }
}