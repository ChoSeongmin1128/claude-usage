import Foundation

extension FileManager {
    /// App Sandbox 환경에서도 실제 사용자 홈 디렉토리를 반환합니다.
    /// Sandbox에서 `homeDirectoryForCurrentUser`는 컨테이너 경로를 반환하므로
    /// `~/.gemini/` 등 사용자 설정 파일에 접근할 때 이 프로퍼티를 사용합니다.
    nonisolated var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return homeDirectoryForCurrentUser
    }
}
