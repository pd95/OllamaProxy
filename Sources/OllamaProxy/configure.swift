import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // Allow port configuration via environment
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "127.0.0.1"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // Register ProxyService lifecycle handler
    app.lifecycle.use(app.proxyService)

    // Compression
    app.http.server.configuration.responseCompression = .enabled
    app.http.server.configuration.requestDecompression = .enabled

    // register routes
    try routes(app)

    // Configure upper limit for body
    app.routes.defaultMaxBodySize = "1mb"
}
