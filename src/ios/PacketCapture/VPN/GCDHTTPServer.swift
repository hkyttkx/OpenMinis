import Foundation

/// 极简 HTTP 服务器，用于向 Safari 提供 CA 证书 (.cer) 文件
final class GCDHTTPServer {
    private var listenSocket: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.openminis.app.httpserver")
    private let certDataProvider: () -> Data?
    private var port: UInt16 = 0
    
    init(port: UInt16, certDataProvider: @escaping () -> Data?) {
        self.port = port
        self.certDataProvider = certDataProvider
    }
    
    func start() -> UInt16? {
        listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard listenSocket >= 0 else { return nil }
        
        var reuse: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian // 0 = 系统分配
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult == 0 else {
            close(listenSocket)
            listenSocket = -1
            return nil
        }
        
        // 获取实际端口
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(listenSocket, sockPtr, &addrLen)
            }
        }
        let actualPort = UInt16(bigEndian: boundAddr.sin_port)
        
        guard listen(listenSocket, 5) == 0 else {
            close(listenSocket)
            listenSocket = -1
            return nil
        }
        
        let src = DispatchSource.makeReadSource(fileDescriptor: listenSocket, queue: queue)
        src.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.listenSocket, fd >= 0 {
                close(fd)
                self?.listenSocket = -1
            }
        }
        src.resume()
        source = src
        
        return actualPort
    }
    
    func stop() {
        source?.cancel()
        source = nil
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }
    
    private func acceptConnection() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(listenSocket, sockPtr, &addrLen)
            }
        }
        
        guard clientFd >= 0 else { return }
        
        queue.async { [weak self] in
            self?.handleClient(fd: clientFd)
        }
    }
    
    private func handleClient(fd: Int32) {
        defer { close(fd) }
        
        // 读取请求
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }
        
        let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
        
        // 解析请求路径
        let path: String
        if let firstLine = request.components(separatedBy: "\r\n").first,
           let pathPart = firstLine.components(separatedBy: " ").dropFirst().first {
            path = pathPart
        } else {
            path = "/"
        }
        
        if path == "/ca.cer" {
            // 直接提供 DER 证书
            guard let certData = certDataProvider() else {
                sendResponse(fd: fd, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
                return
            }
            sendResponse(fd: fd, status: "200 OK", contentType: "application/x-x509-ca-cert",
                         body: certData, filename: "ca.cer")
        } else {
            // 首页：显示下载链接
            let html = """
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>安装 CA 证书</title>
            <style>body{font-family:-apple-system;text-align:center;padding:60px 20px;background:#f5f5f7}
            a{display:inline-block;margin-top:30px;padding:14px 28px;background:#007aff;color:#fff;
            border-radius:12px;text-decoration:none;font-size:17px}</style></head>
            <body><h2>VPN 抓包 CA 证书</h2><p>点击下方按钮下载并安装 CA 证书</p>
            <a href="/ca.cer">下载证书</a>
            <p style="margin-top:30px;color:#888;font-size:13px">安装后请前往 设置 → 通用 → 关于本机 → 证书信任设置 启用信任</p>
            </body></html>
            """
            sendResponse(fd: fd, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        }
    }
    
    private func sendResponse(fd: Int32, status: String, contentType: String, body: Data, filename: String? = nil) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let filename = filename {
            header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        }
        header += "\r\n"
        
        _ = header.withCString { send(fd, $0, strlen($0), 0) }
        body.withUnsafeBytes { rawBuffer in
            if let ptr = rawBuffer.baseAddress {
                _ = send(fd, ptr, body.count, 0)
            }
        }
    }
}
