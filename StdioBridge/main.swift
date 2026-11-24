import Foundation
import MCPBridge

// xpaste-mcp-stdio：给只支持 stdio 的 AI 工具用，按行把 JSON-RPC 转发到 XPaste 的本机 MCP 服务。
let bridge: MCPStdioBridge
do {
    bridge = try MCPStdioBridge(environment: ProcessInfo.processInfo.environment)
} catch {
    FileHandle.standardError.write(Data("xpaste-mcp-stdio: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// 按到达顺序逐条处理，响应顺序与请求一致。
for try await line in FileHandle.standardInput.bytes.lines {
    if let response = await bridge.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
await bridge.close()
