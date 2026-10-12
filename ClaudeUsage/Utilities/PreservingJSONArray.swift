import Foundation

/// 배열을 항목 단위로 읽는다. 새 버전이 저장한 항목처럼 지금 읽지 못하는 항목은 버리지 않고 남겨,
/// 다시 저장할 때 원래 모양대로 뒤에 붙인다. 이전 버전으로 되돌려도 새 버전의 자료가 지워지지 않는다.
nonisolated enum PreservingJSONArray {
    struct Decoded<Element> {
        var elements: [Element]
        /// 읽지 못한 항목의 원래 JSON
        var unreadable: [Any]
    }

    static func decode<Element: Decodable>(
        _ type: Element.Type, from data: Data, accepting: (Element) -> Bool = { _ in true }
    ) -> Decoded<Element>? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var result = Decoded<Element>(elements: [], unreadable: [])
        let decoder = JSONDecoder()
        for item in raw {
            if let itemData = try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed]),
                let element = try? decoder.decode(Element.self, from: itemData), accepting(element)
            {
                result.elements.append(element)
            } else {
                result.unreadable.append(item)
            }
        }
        return result
    }

    static func encode<Element: Encodable>(_ elements: [Element], preserving unreadable: [Any]) -> Data? {
        let encoder = JSONEncoder()
        var raw: [Any] = []
        for element in elements {
            guard let data = try? encoder.encode(element),
                let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return nil }
            raw.append(object)
        }
        return try? JSONSerialization.data(withJSONObject: raw + unreadable)
    }
}
