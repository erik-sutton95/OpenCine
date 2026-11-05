import CoreMediaIO
import Foundation

let providerSource = try OpenCineCameraProvider(configured: true)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
