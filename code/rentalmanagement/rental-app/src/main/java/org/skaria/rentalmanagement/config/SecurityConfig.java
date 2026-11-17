package org.skaria.rentalmanagement.config;

import org.skaria.rentalmanagement.identity.RentalOidcUserService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.access.hierarchicalroles.RoleHierarchy;
import org.springframework.security.access.hierarchicalroles.RoleHierarchyImpl;
import org.springframework.security.authorization.AuthorityAuthorizationManager;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.web.HttpSessionOAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizationRequestCustomizers;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.access.intercept.RequestAuthorizationContext;
import org.springframework.security.web.authentication.logout.HttpStatusReturningLogoutSuccessHandler;
import org.springframework.security.web.csrf.CookieCsrfTokenRepository;
import org.springframework.security.web.csrf.CsrfTokenRequestAttributeHandler;
import org.springframework.security.web.savedrequest.NullRequestCache;

import java.time.Clock;

@Configuration(proxyBeanMethods = false)
public class SecurityConfig {

    @Bean
    Clock clock() {
        return Clock.systemUTC();
    }

    @Bean
    RoleHierarchy roleHierarchy() {
        return RoleHierarchyImpl.fromHierarchy("""
                ROLE_ADMIN > ROLE_LANDLORD
                ROLE_LANDLORD > ROLE_FAMILY_VIEWER
                """);
    }

    @Bean
    SecurityFilterChain securityFilterChain(
            HttpSecurity http,
            ClientRegistrationRepository registrations,
            RentalOidcUserService oidcUserService,
            RoleHierarchy roleHierarchy,
            @Value("${app.security.cookie-secure:true}")
            boolean cookieSecure
    ) throws Exception {

        var authorizationRequests =
                new DefaultOAuth2AuthorizationRequestResolver(
                        registrations,
                        "/oauth2/authorization"
                );

        authorizationRequests.setAuthorizationRequestCustomizer(
                OAuth2AuthorizationRequestCustomizers.withPkce()
        );

        var authorizedClients =
                new HttpSessionOAuth2AuthorizedClientRepository();

        var csrfRepository =
                CookieCsrfTokenRepository.withHttpOnlyFalse();

        csrfRepository.setCookieCustomizer(cookie -> cookie
                .path("/")
                .sameSite("Lax")
                .secure(cookieSecure)
        );

        var csrfHandler = new CsrfTokenRequestAttributeHandler();

        AuthorityAuthorizationManager<RequestAuthorizationContext>
                applicationUser =
                AuthorityAuthorizationManager.hasRole("FAMILY_VIEWER");

        applicationUser.setRoleHierarchy(roleHierarchy);

        http
                .authorizeHttpRequests(authorize -> authorize
                        .requestMatchers(
                                "/oauth2/authorization/**",
                                "/login/oauth2/code/**",
                                "/api/csrf",
                                "/error"
                        ).permitAll()
                        .requestMatchers("/api/**")
                        .access(applicationUser)
                        .anyRequest().denyAll()
                )
                .sessionManagement(session -> session
                        .sessionCreationPolicy(
                                SessionCreationPolicy.IF_REQUIRED
                        )
                )
                .requestCache(cache -> cache
                        .requestCache(new NullRequestCache())
                )
                .csrf(csrf -> csrf
                        .csrfTokenRepository(csrfRepository)
                        .csrfTokenRequestHandler(csrfHandler)
                )
                .exceptionHandling(exceptions -> exceptions
                        .authenticationEntryPoint(
                                (request, response, exception) -> {
                                    response.setStatus(401);
                                    response.setContentType(
                                            MediaType.APPLICATION_PROBLEM_JSON_VALUE
                                    );
                                    response.getWriter().write("""
                                            {
                                              "type": "about:blank",
                                              "title": "Unauthorized",
                                              "status": 401,
                                              "detail": "Authentication is required."
                                            }
                                            """);
                                }
                        )
                        .accessDeniedHandler(
                                (request, response, exception) -> {
                                    response.setStatus(403);
                                    response.setContentType(
                                            MediaType.APPLICATION_PROBLEM_JSON_VALUE
                                    );
                                    response.getWriter().write("""
                                            {
                                              "type": "about:blank",
                                              "title": "Forbidden",
                                              "status": 403,
                                              "detail": "Access denied or CSRF token missing or invalid."
                                            }
                                            """);
                                }
                        )
                )
                .oauth2Login(login -> login
                        .authorizationEndpoint(endpoint -> endpoint
                                .authorizationRequestResolver(
                                        authorizationRequests
                                )
                        )
                        .authorizedClientRepository(authorizedClients)
                        .userInfoEndpoint(info -> info
                                .oidcUserService(oidcUserService)
                        )
                        .defaultSuccessUrl("/api/me", true)
                        .failureHandler(
                                (request, response, exception) -> {
                                    boolean denied =
                                            exception instanceof
                                            org.springframework.security.oauth2.core.OAuth2AuthenticationException oauth
                                            && "access_denied".equals(
                                                    oauth.getError().getErrorCode()
                                            );

                                    int status = denied ? 403 : 401;

                                    response.setStatus(status);
                                    response.setContentType(
                                            MediaType.APPLICATION_PROBLEM_JSON_VALUE
                                    );

                                    response.getWriter().write(
                                            denied
                                                    ? """
                                                      {
                                                        "type": "about:blank",
                                                        "title": "Forbidden",
                                                        "status": 403,
                                                        "detail": "No application access has been granted."
                                                      }
                                                      """
                                                    : """
                                                      {
                                                        "type": "about:blank",
                                                        "title": "Unauthorized",
                                                        "status": 401,
                                                        "detail": "Sign-in could not be completed."
                                                      }
                                                      """
                                    );
                                }
                        )
                )
                .logout(logout -> logout
                        .logoutUrl("/logout")
                        .invalidateHttpSession(true)
                        .clearAuthentication(true)
                        .deleteCookies("JSESSIONID", "XSRF-TOKEN")
                        .logoutSuccessHandler(
                                new HttpStatusReturningLogoutSuccessHandler(
                                        HttpStatus.NO_CONTENT
                                )
                        )
                );

        return http.build();
    }
}