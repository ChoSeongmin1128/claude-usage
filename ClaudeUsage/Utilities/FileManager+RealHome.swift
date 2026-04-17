import Foundation

extension FileManager {
    /// 실제 사용자 홈 디렉토리를 반환합니다.
    /// App Sandbox가 비활성화된 환경에서는 `homeDirectoryForCurrentUser`가
    /// 실제 홈 경로를 반환하므로 별도의 우회 로직이 불필요합니다.
    nonisolated var realHomeDirectory: URL {
        homeDirectoryForCurrentUser
    }
}
