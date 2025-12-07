import Vapor

func routes(_ app: Application) throws {
    // Capture and forward requests to the specified target host and port.
    let proxyService = app.proxyService
    app.on(.HEAD, "", use: proxyService.forwardRequest)
    app.on(.GET, .catchall, use: proxyService.forwardRequest)
    app.on(.POST, .catchall, use: proxyService.forwardRequest)
    app.on(.PUT, .catchall, use: proxyService.forwardRequest)
    app.on(.DELETE, .catchall, use: proxyService.forwardRequest)
    app.on(.PATCH, .catchall, use: proxyService.forwardRequest)
}
