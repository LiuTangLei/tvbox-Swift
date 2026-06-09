import Foundation

actor XMLTVService {
    static let shared = XMLTVService()

    private static let cacheTTL: TimeInterval = 6 * 60 * 60
    private static let maxCacheEntries = 12
    private static let requestHeaders = [
        "User-Agent": "okhttp/4.12.0",
        "Accept": "*/*"
    ]

    private struct CacheEntry {
        let payload: String
        let fetchedAt: Date
    }

    private struct EPGCandidate {
        let url: String
        let cacheKey: String
    }

    private var payloadCache: [String: CacheEntry] = [:]

    func loadTodayPrograms(for channel: LiveChannelItem, date: Date = Date()) async throws -> [Epginfo] {
        let candidates = Self.epgCandidates(for: channel, date: date)
        guard !candidates.isEmpty else { return [] }

        var lastError: Error?
        for candidate in candidates {
            do {
                try Task.checkCancellation()
                let payload = try await cachedPayload(for: candidate)
                let programs = try Self.programs(from: payload, channel: channel, date: date)
                if !programs.isEmpty { return programs }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        return []
    }

    private func cachedPayload(for candidate: EPGCandidate) async throws -> String {
        let now = Date()
        if let entry = payloadCache[candidate.cacheKey] {
            if now.timeIntervalSince(entry.fetchedAt) <= Self.cacheTTL {
                return entry.payload
            }
            payloadCache.removeValue(forKey: candidate.cacheKey)
        }

        let payload = try await NetworkManager.shared.getString(
            from: candidate.url,
            headers: Self.requestHeaders
        )
        payloadCache[candidate.cacheKey] = CacheEntry(payload: payload, fetchedAt: now)
        trimCacheIfNeeded()
        return payload
    }

    private func trimCacheIfNeeded() {
        guard payloadCache.count > Self.maxCacheEntries else { return }
        let overflow = payloadCache.count - Self.maxCacheEntries
        let staleKeys = payloadCache
            .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(overflow)
            .map(\.key)
        staleKeys.forEach { payloadCache.removeValue(forKey: $0) }
    }

    private static func epgCandidates(for channel: LiveChannelItem, date: Date) -> [EPGCandidate] {
        let dateString = dayFormatter.string(from: date)
        let replacements: [String: String] = [
            "{date}": dateString,
            "{id}": urlEncoded(channel.tvgId.nilIfBlank ?? channel.channelName),
            "{name}": urlEncoded(channel.tvgName.nilIfBlank ?? channel.channelName),
            "{epg}": urlEncoded(channel.tvgId.nilIfBlank ?? channel.tvgName.nilIfBlank ?? channel.channelName)
        ]

        let rawURLs = channel.epgUrl
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen: Set<String> = []
        var candidates: [EPGCandidate] = []
        for rawURL in rawURLs {
            var expandedURL = rawURL
            for (token, value) in replacements {
                expandedURL = expandedURL.replacingOccurrences(of: token, with: value)
            }
            guard expandedURL.lowercased().hasPrefix("http") else { continue }
            let key = expandedURL.lowercased()
            guard seen.insert(key).inserted else { continue }
            candidates.append(EPGCandidate(url: expandedURL, cacheKey: key))
        }
        return candidates
    }

    private static func programs(from payload: String, channel: LiveChannelItem, date: Date) throws -> [Epginfo] {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("{") {
            return try jsonPrograms(from: trimmed, requestedDate: date)
        }
        return try xmlPrograms(from: trimmed, channel: channel, date: date)
    }

    private static func jsonPrograms(from payload: String, requestedDate: Date) throws -> [Epginfo] {
        guard let data = payload.data(using: .utf8) else { return [] }
        let response = try JSONDecoder().decode(JSONEPGResponse.self, from: data)
        let requestedDateString = dayFormatter.string(from: requestedDate)
        if let responseDate = response.date?.nilIfBlank, responseDate != requestedDateString {
            return []
        }

        return response.epgData.enumerated().compactMap { offset, item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let start = normalizeClockDisplay(item.start)
            let end = normalizeClockDisplay(item.end)
            let startDate = date(fromDay: response.date ?? requestedDateString, clock: item.start)
            var endDate = date(fromDay: response.date ?? requestedDateString, clock: item.end)
            if let startDate, let currentEndDate = endDate, currentEndDate < startDate {
                endDate = Calendar.current.date(byAdding: .day, value: 1, to: currentEndDate)
            }
            return Epginfo(
                title: title,
                startTime: start,
                endTime: end,
                index: offset,
                startTimestamp: startDate?.timeIntervalSince1970 ?? 0,
                endTimestamp: endDate?.timeIntervalSince1970 ?? 0
            )
        }
    }

    private static func xmlPrograms(from payload: String, channel: LiveChannelItem, date: Date) throws -> [Epginfo] {
        guard let data = payload.data(using: .utf8) else { return [] }
        let document = try XMLTVDocument.parse(data)
        let matchedChannelIds = document.matchedChannelIds(for: channel)
        guard !matchedChannelIds.isEmpty else { return [] }

        let calendar = Calendar.current
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else { return [] }
        let timeFormatter = clockFormatter

        let filteredPrograms = document.programs.compactMap { program -> (start: Date, end: Date, title: String)? in
            guard matchedChannelIds.contains(program.channel) else { return nil }
            let title = program.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  let startDate = parseXMLTVDate(program.start),
                  let endDate = parseXMLTVDate(program.stop) else { return nil }
            guard startDate < dayInterval.end, endDate > dayInterval.start else { return nil }
            return (startDate, endDate, title)
        }
        .sorted { $0.start < $1.start }

        var seen: Set<String> = []
        var result: [Epginfo] = []
        for program in filteredPrograms {
            let start = timeFormatter.string(from: program.start)
            let end = timeFormatter.string(from: program.end)
            let key = "\(start)|\(end)|\(program.title)"
            guard seen.insert(key).inserted else { continue }
            result.append(
                Epginfo(
                    title: program.title,
                    startTime: start,
                    endTime: end,
                    index: result.count,
                    startTimestamp: program.start.timeIntervalSince1970,
                    endTimestamp: program.end.timeIntervalSince1970
                )
            )
        }
        return result
    }

    private static func parseXMLTVDate(_ source: String) -> Date? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"^\s*(\d{14})(?:\s*([+-]\d{2}:?\d{2}|Z))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
              ),
              let digitsRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }

        let digits = String(trimmed[digitsRange])
        guard let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)),
              let hour = Int(digits.dropFirst(8).prefix(2)),
              let minute = Int(digits.dropFirst(10).prefix(2)),
              let second = Int(digits.dropFirst(12).prefix(2)) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        if match.range(at: 2).location != NSNotFound,
           let timezoneRange = Range(match.range(at: 2), in: trimmed),
           let timezone = timeZone(from: String(trimmed[timezoneRange])) {
            calendar.timeZone = timezone
        } else {
            calendar.timeZone = .current
        }

        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )
    }

    private static func timeZone(from source: String) -> TimeZone? {
        if source == "Z" { return TimeZone(secondsFromGMT: 0) }
        let normalized = source.replacingOccurrences(of: ":", with: "")
        guard normalized.count == 5 else { return nil }
        let sign = normalized.hasPrefix("-") ? -1 : 1
        let payload = normalized.dropFirst()
        guard let hours = Int(payload.prefix(2)),
              let minutes = Int(payload.dropFirst(2).prefix(2)) else {
            return nil
        }
        return TimeZone(secondsFromGMT: sign * ((hours * 60 + minutes) * 60))
    }

    private static func date(fromDay day: String, clock: String) -> Date? {
        let normalizedClock = normalizeClockDisplay(clock)
        guard !day.isEmpty, !normalizedClock.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(normalizedClock)")
    }

    private static func normalizeClockDisplay(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let date = parseXMLTVDate(trimmed) {
            return clockFormatter.string(from: date)
        }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard parts.count >= 2 else { return "" }
            return "\(parts[0].leftPaddedClockPart):\(parts[1].leftPaddedClockPart)"
        }
        let digits = trimmed.filter(\.isNumber)
        if digits.count >= 4 {
            let hour = digits.prefix(2)
            let minute = digits.dropFirst(2).prefix(2)
            return "\(hour):\(minute)"
        }
        return ""
    }

    private static func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static var clockFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }
}

private struct JSONEPGResponse: Decodable {
    var date: String?
    var epgData: [JSONEPGProgram]

    enum CodingKeys: String, CodingKey {
        case date
        case epgData = "epg_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        epgData = try container.decodeIfPresent([JSONEPGProgram].self, forKey: .epgData) ?? []
    }
}

private struct JSONEPGProgram: Decodable {
    var title: String
    var start: String
    var end: String

    enum CodingKeys: String, CodingKey {
        case title
        case start
        case end
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        start = try container.decodeIfPresent(String.self, forKey: .start) ?? ""
        end = try container.decodeIfPresent(String.self, forKey: .end) ?? ""
    }
}

private struct XMLTVDocument {
    struct Channel {
        let id: String
        let displayNames: [String]
    }

    struct Program {
        let channel: String
        let title: String
        let start: String
        let stop: String
    }

    let channels: [Channel]
    let programs: [Program]

    static func parse(_ data: Data) throws -> XMLTVDocument {
        let delegate = XMLTVParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? XMLTVServiceError.parseFailed
        }
        return XMLTVDocument(channels: delegate.channels, programs: delegate.programs)
    }

    func matchedChannelIds(for channel: LiveChannelItem) -> Set<String> {
        let keys = Self.matchKeys(for: channel)
        guard !keys.isEmpty else { return [] }

        var matchedIds: Set<String> = []
        for xmlChannel in channels {
            let xmlKeys = ([xmlChannel.id] + xmlChannel.displayNames)
                .map(Self.normalizedMatchKey)
                .filter { !$0.isEmpty }
            if xmlKeys.contains(where: { keys.contains($0) }) {
                matchedIds.insert(xmlChannel.id)
            }
        }

        for key in [channel.tvgId, channel.tvgName, channel.channelName] {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                matchedIds.insert(trimmed)
            }
        }

        return matchedIds
    }

    private static func matchKeys(for channel: LiveChannelItem) -> Set<String> {
        [channel.tvgId, channel.tvgName, channel.channelName, channel.number]
            .map(normalizedMatchKey)
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private static func normalizedMatchKey(_ source: String) -> String {
        source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private struct ChannelDraft {
        let id: String
        var displayNames: [String] = []
    }

    private struct ProgramDraft {
        let channel: String
        let start: String
        let stop: String
        var title: String = ""
    }

    private(set) var channels: [XMLTVDocument.Channel] = []
    private(set) var programs: [XMLTVDocument.Program] = []

    private var currentChannel: ChannelDraft?
    private var currentProgram: ProgramDraft?
    private var textElement: String?
    private var textBuffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "channel":
            if let id = attributeDict["id"]?.nilIfBlank {
                currentChannel = ChannelDraft(id: id)
            }
        case "display-name":
            guard currentChannel != nil else { return }
            textElement = elementName
            textBuffer = ""
        case "programme":
            guard let channel = attributeDict["channel"]?.nilIfBlank,
                  let start = attributeDict["start"]?.nilIfBlank,
                  let stop = attributeDict["stop"]?.nilIfBlank else {
                return
            }
            currentProgram = ProgramDraft(channel: channel, start: start, stop: stop)
        case "title":
            guard currentProgram != nil else { return }
            textElement = elementName
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textElement != nil {
            textBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "display-name":
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                currentChannel?.displayNames.append(value)
            }
            clearTextBuffer()
        case "channel":
            if let currentChannel {
                channels.append(
                    XMLTVDocument.Channel(
                        id: currentChannel.id,
                        displayNames: currentChannel.displayNames
                    )
                )
            }
            currentChannel = nil
        case "title":
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentProgram?.title.isEmpty == true {
                currentProgram?.title = value
            }
            clearTextBuffer()
        case "programme":
            if let currentProgram {
                programs.append(
                    XMLTVDocument.Program(
                        channel: currentProgram.channel,
                        title: currentProgram.title,
                        start: currentProgram.start,
                        stop: currentProgram.stop
                    )
                )
            }
            currentProgram = nil
        default:
            break
        }
    }

    private func clearTextBuffer() {
        textElement = nil
        textBuffer = ""
    }
}

private enum XMLTVServiceError: LocalizedError {
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .parseFailed:
            return "XMLTV 解析失败"
        }
    }
}

private extension Substring {
    var leftPaddedClockPart: String {
        count == 1 ? "0\(self)" : String(prefix(2))
    }
}
