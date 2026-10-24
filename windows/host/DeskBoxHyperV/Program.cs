// Desk Box Windows host adapter（M2-4a skeleton）。
//
// 本文件仅验证 wire protocol 与命令流的可编译性；UNVERIFIED（真机 Hyper-V outsample 未执行）。
// 正真验证要求在 Windows host 上：dotnet build + powershell Run as Administrator。
using System.Buffers.Binary;
using System.Text;
using System.Text.Json;

namespace DeskBox.HyperV;

public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: deskbox-hyperv <ping|create|start|connect|destroy> [args]");
            return 2;
        }
        // M2-4a 只验证编解码环节；真实 HCS/HVSock 调用将在 Windows 宿主真机阶段接入。
        var ok = WireContractSelfCheck.RunAll();
        Console.WriteLine(ok ? "DESKBOX-HV skeleton ok" : "DESKBOX-HV skeleton FAILED");
        return ok ? 0 : 1;
    }
}

/// 与 macos/Sources/DeskBoxCore/ControlProtocol.swift 一致的 wire frame。
public static class WireContractSelfCheck
{
    private const ushort ProtocolMajor = 1;
    private const uint Magic = 0x44425831; // 'DBX1'
    private const int HeaderSize = 4 + 2 + 2 + 8 + 16 + 4;

    public static bool RunAll()
    {
        try
        {
            var payload = Encoding.UTF8.GetBytes("{\"x\":1}");
            var buffer = new byte[HeaderSize + payload.Length];
            BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(0), Magic);
            BinaryPrimitives.WriteUInt16BigEndian(buffer.AsSpan(4), ProtocolMajor);
            BinaryPrimitives.WriteUInt16BigEndian(buffer.AsSpan(6), 4); // .request
            BinaryPrimitives.WriteUInt64BigEndian(buffer.AsSpan(8), 42);
            var id = new Guid(0x01234567, 0x89AB, 0xCDEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF);
            id.TryWriteBytes(buffer.AsSpan(16));
            BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(32), (uint)payload.Length);
            payload.CopyTo(buffer, 36);
            if (buffer[0] != 0x44 || buffer[1] != 0x42 || buffer[6] != 0 || buffer[7] != 4 || buffer[15] != 42 || buffer[35] != 7)
                return false;
            // broker shape lock（与 WireContractLockTests 一致）
            var req = new Dictionary<string, object> { ["reqId"] = 7, ["url"] = "https://example.com", ["savePath"] = "/workspace/inbound/x" };
            var json = JsonSerializer.Serialize(req);
            if (!json.Contains("\"reqId\":7")) return false;
            return true;
        }
        catch { return false; }
    }
}
