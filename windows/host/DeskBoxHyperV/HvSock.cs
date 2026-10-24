// HVSock 连接层骨架（M2-4a skeleton；UNVERIFIED 待真机复核）。
//
// 真实实现要点（M2-4b/c需要复检）：
// - AF_VSOCK（AddressFamily=34）";
// - 与 macOS VZ 的 VZVirtioSocketConnection 语义对等；
// - 客户端/服务端双端点生成与保活周期。
using System.Net.Sockets;

namespace DeskBox.HyperV;

public static class HvSock
{
    public static Task<Socket> ConnectAsync(Guid vmId, uint port, CancellationToken ct)
    {
        // 骨架只为交付路径：真机阶段将从 System.Net.Sockets.Socket AF_VSOCK
        // 版本中读入并填充，当面注记在这里（当前工作站不有 Hyper-V 环境）。
        throw new PlatformNotSupportedException("HVSock 验证在 Windows 宿主机进行（M2-4b）");
    }
}
