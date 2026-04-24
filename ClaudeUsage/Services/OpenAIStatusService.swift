//
//  OpenAIStatusService.swift
//  ClaudeUsage
//
//  OpenAI Statuspage에서 Codex 관련 컴포넌트 상태만 추려냅니다.
//

import Foundation

actor OpenAIStatusService {
    static let shared = OpenAIStatusService()

    private let statusURL = "https://status.openai.com/api/v2/summary.json"
    private let codexComponentNames: Set<String> = [
        "Codex Web",
        "Codex API",
        "CLI",
        "Responses",
    ]

    func fetchCodexStatus() async -> ProviderSystemStatus? {
        guard let url = URL(string: statusURL) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                Logger.warning("OpenAI 상태 API 응답 오류")
                return nil
            }

            return StatusPageInterpreter.parseStatus(
                data: data,
                relevantComponentNames: codexComponentNames,
                fallbackDescription: "Codex 상태"
            )
        } catch {
            Logger.warning("OpenAI 상태 확인 실패: \(error.localizedDescription)")
            return nil
        }
    }
}
