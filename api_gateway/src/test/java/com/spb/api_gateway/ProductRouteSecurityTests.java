package com.spb.api_gateway;

import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.mockJwt;
import static org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers.springSecurity;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.ApplicationContext;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;

import reactor.core.publisher.Mono;
import reactor.netty.DisposableServer;
import reactor.netty.http.server.HttpServer;

/**
 * Verifica las reglas de seguridad de las rutas de product-service.
 * Un servidor HTTP local hace de product-service y responde con el path que recibió,
 * así también se comprueba el StripPrefix.
 */
@SpringBootTest
class ProductRouteSecurityTests {

    private static final DisposableServer productService = HttpServer.create()
            .port(0)
            .handle((req, res) -> res.sendString(Mono.just("product-service:" + req.method() + " " + req.uri())))
            .bindNow();

    @DynamicPropertySource
    static void productServiceLocation(DynamicPropertyRegistry registry) {
        registry.add("PRODUCT_SERVICE_HOST", () -> "localhost");
        registry.add("PRODUCT_SERVICE_PORT", productService::port);
    }

    @AfterAll
    static void stopProductService() {
        productService.disposeNow();
    }

    @Autowired
    ApplicationContext context;

    WebTestClient client;

    @BeforeEach
    void setUp() {
        client = WebTestClient.bindToApplicationContext(context)
                .apply(springSecurity())
                .configureClient()
                .build();
    }

    @Test
    void getProductsIsPublic() {
        client.get().uri("/api/products/15")
                .exchange()
                .expectStatus().isOk()
                .expectBody(String.class).isEqualTo("product-service:GET /products/15");
    }

    @Test
    void postProductsWithoutTokenIsRejected() {
        client.post().uri("/api/products")
                .exchange()
                .expectStatus().isUnauthorized();
    }

    @Test
    void writeOnProductsRequiresManagePermission() {
        // Usuario autenticado pero SIN manage:products
        client.post().uri("/api/products").exchange().expectStatus().isUnauthorized();
        client.mutateWith(mockJwt()).post().uri("/api/products")
                .exchange().expectStatus().isForbidden();
        client.mutateWith(mockJwt()).put().uri("/api/products/15")
                .exchange().expectStatus().isForbidden();
        client.mutateWith(mockJwt()).delete().uri("/api/products/15")
                .exchange().expectStatus().isForbidden();
        client.mutateWith(mockJwt()).patch().uri("/api/products/15")
                .exchange().expectStatus().isForbidden();
    }

    @Test
    void writeOnProductsAllowedWithManagePermission() {
        client.mutateWith(mockJwt().authorities(new SimpleGrantedAuthority("manage:products")))
                .post().uri("/api/products")
                .exchange()
                .expectStatus().isOk()
                .expectBody(String.class).isEqualTo("product-service:POST /products");
    }

    @Test
    void crudProductsRequiresManagePermission() {
        client.mutateWith(mockJwt()).post().uri("/api/crud/products")
                .exchange().expectStatus().isForbidden();
        client.mutateWith(mockJwt().authorities(new SimpleGrantedAuthority("manage:products")))
                .post().uri("/api/crud/products")
                .exchange()
                .expectStatus().isOk()
                .expectBody(String.class).isEqualTo("product-service:POST /crud/products");
    }
}
