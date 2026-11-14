package com.spb.api_gateway;

import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.regex.Pattern;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.ReactiveJwtAuthenticationConverterAdapter;
import org.springframework.security.web.server.SecurityWebFilterChain;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.reactive.CorsConfigurationSource;
import org.springframework.web.cors.reactive.UrlBasedCorsConfigurationSource;

@Configuration
public class Security {

    // Solo acepta permisos con formato manage:xxx, read:xxx o write:xxx
    private static final Pattern PERMISSION_PATTERN =
            Pattern.compile("^(manage|read|write):[a-zA-Z0-9_-]+$");

    @Bean
    SecurityWebFilterChain securityFilterChain(ServerHttpSecurity http) {

        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();

        converter.setJwtGrantedAuthoritiesConverter(jwt -> {

            Collection<GrantedAuthority> authorities = new LinkedHashSet<>();

            //auth envia los rbac por claims
            List<String> permissions = jwt.getClaimAsStringList("permissions");

            if (permissions != null) {
                for (String permission : permissions) {
                    if (permission != null
                            && PERMISSION_PATTERN.matcher(permission).matches()) {
                        authorities.add(new SimpleGrantedAuthority(permission));
                    }
                }
            }

            return authorities;
        });

        return http
            .csrf(csrf -> csrf.disable())
            .cors(cors -> cors.configurationSource(corsConfigurationSource()))
            .authorizeExchange(auth -> auth
                // preflight CORS del navegador (no lleva token)
                .pathMatchers(HttpMethod.OPTIONS, "/**").permitAll()

                // productos: ver es público
                .pathMatchers(HttpMethod.GET, "/api/products/**").permitAll()
                // cualquier otro método (POST, PUT, PATCH, DELETE) sobre productos exige permiso
                .pathMatchers("/api/products/**").hasAuthority("manage:products")

                // funciones admin
                .pathMatchers("/api/admin/**").hasAuthority("manage:users")
                .pathMatchers("/api/crud/products/**").hasAuthority("manage:products")

                // pagos para contratistas
                .pathMatchers("/api/payments/contractor/**").hasAuthority("write:contractor_payments")

                // pagos para clientes normales
                .pathMatchers("/api/payments/user/**").hasAuthority("write:payments")

                // funciones para vendedores
                .pathMatchers("/api/vendor/**").hasAuthority("read:sells")

                // funciones para usuarios normales
                .pathMatchers("/api/users/**").hasAuthority("read:profile")

                // funciones para contratistas
                .pathMatchers("/api/contractor/**").hasAuthority("read:contractor")

                .anyExchange().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2.jwt(jwt ->
                jwt.jwtAuthenticationConverter(
                    new ReactiveJwtAuthenticationConverterAdapter(converter)
                )
            ))
            .build();
    }

    // permite solicitudes desde cualquier lugar de la peticion, el token viaja en el header
    // authorization (no en cookies), por eso no se necesitan credenciales!
    @Bean
    CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOriginPatterns(List.of("*"));
        config.setAllowedMethods(List.of("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"));
        config.setAllowedHeaders(List.of("*"));
        config.setAllowCredentials(false);
        config.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }
}