import Foundation

/// OCI Runtime Spec `config.json` 的 Desk Box 允许子集（docs/design/m2-2-oci-workload.md）。
///
/// 仅 model；违表与拒收策略在 DeskBoxVZ `OciPolicyValidator`。
public struct OciRuntimeSpec: Sendable, Codable, Equatable {
    public struct Root: Sendable, Codable, Equatable {
        public let path: String
        public let readonly: Bool?
        public init(path: String, readonly: Bool? = nil) {
            self.path = path
            self.readonly = readonly
        }
    }

    public struct Process: Sendable, Codable, Equatable {
        public let args: [String]
        public let cwd: String
        public let env: [String]?
        public let user: User?

        public init(args: [String], cwd: String, env: [String]? = nil, user: User? = nil) {
            self.args = args
            self.cwd = cwd
            self.env = env
            self.user = user
        }
    }

    public struct User: Sendable, Codable, Equatable {
        public let uid: Int
        public let gid: Int
        public init(uid: Int, gid: Int) {
            self.uid = uid
            self.gid = gid
        }
    }

    public struct Mount: Sendable, Codable, Equatable {
        public let destination: String
        public let source: String?
        public let type: String?
        public let options: [String]?

        public init(destination: String, source: String? = nil, type: String? = nil, options: [String]? = nil) {
            self.destination = destination
            self.source = source
            self.type = type
            self.options = options
        }
    }

    public struct Linux: Sendable, Codable, Equatable {
        public let namespaces: [Namespace]?
        public let privileged: Bool?

        public init(namespaces: [Namespace]? = nil, privileged: Bool? = nil) {
            self.namespaces = namespaces
            self.privileged = privileged
        }
    }

    public struct Namespace: Sendable, Codable, Equatable {
        public let type: String
        public let path: String?
        public init(type: String, path: String? = nil) {
            self.type = type
            self.path = path
        }
    }

    public let ociVersion: String
    public let root: Root?
    public let process: Process
    public let mounts: [Mount]?
    public let linux: Linux?

    public init(ociVersion: String, root: Root?, process: Process, mounts: [Mount]? = nil, linux: Linux? = nil) {
        self.ociVersion = ociVersion
        self.root = root
        self.process = process
        self.mounts = mounts
        self.linux = linux
    }
}
