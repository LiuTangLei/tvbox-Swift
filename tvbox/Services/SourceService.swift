import Foundation

struct VideoPage {
    let videos: [Movie.Video]
    let page: Int
    let pageCount: Int?
}

struct SearchResultGroup: Identifiable {
    let source: SourceBean
    let videos: [Movie.Video]
    let sourceOrder: Int

    init(source: SourceBean, videos: [Movie.Video], sourceOrder: Int = Int.max) {
        self.source = source
        self.videos = videos
        self.sourceOrder = sourceOrder
    }

    var id: String { source.key }
}

/// 视频源数据服务 - 对应 Android 版 SourceViewModel.java
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
    static let shared = SourceService()

    private let network = NetworkManager.shared
    private let bridge = BridgeClient.shared
    private let decoder = JSONDecoder()

    private init() {}

    private func shouldUseBridge(for sourceBean: SourceBean) throws -> Bool {
        guard sourceBean.requiresBridge else { return false }
        guard bridge.isEnabled else {
            throw SourceError.unsupportedType(sourceBean.typeDescription)
        }
        return true
    }

    // MARK: - 获取分类列表

    /// 获取指定源的分类列表和首页推荐
    func getSort(sourceBean: SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        let api = sourceBean.api
        guard !api.isEmpty else {
            throw SourceError.emptyApi
        }
        if try shouldUseBridge(for: sourceBean) {
            let jsonStr = try await bridge.home(source: sourceBean)
            return try parseSort(jsonStr, sourceBean: sourceBean)
        }

        guard sourceBean.isSupportedInSwift else {
            throw SourceError.unsupportedType(sourceBean.typeDescription)
        }

        // 确保 api 是有效的 HTTP URL
        guard sourceBean.isHttpApi else {
            throw SourceError.invalidApiUrl(api)
        }

        let jsonStr: String
        if sourceBean.type == 0 {
            // XML 接口
            jsonStr = try await network.getString(from: api, headers: sourceBean.headers)
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口，需要 extend 和 filter 参数
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "filter", value: "true")
            ]
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            let url = try buildURL(base: api, queryItems: queryItems)
            jsonStr = try await network.getString(from: url, headers: sourceBean.headers)
        } else {
            // JSON 接口 (type=1)
            let url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "ac", value: "class")]
            )
            jsonStr = try await network.getString(from: url, headers: sourceBean.headers)
        }

        var (sorts, homeVideos) = try parseSort(jsonStr, sourceBean: sourceBean)

        // 当大多数推荐视频的 vod_pic 为空时（ac=class 接口常见情况），
        // 额外请求列表接口获取带完整海报的推荐视频
        let picMissingCount = homeVideos.filter { $0.pic.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let needsFallback = homeVideos.isEmpty || picMissingCount > homeVideos.count / 2

        if needsFallback && (sourceBean.type == 1 || sourceBean.type == 4) {
            let listUrl: String
            if sourceBean.type == 4 {
                // type=4 用 ac=detail 格式，与 getList 保持一致
                let ext = Self.base64URLString("{}")
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "detail"),
                        URLQueryItem(name: "filter", value: "true"),
                        URLQueryItem(name: "pg", value: "1"),
                        URLQueryItem(name: "ext", value: ext)
                    ]
                )
            } else {
                // type=1 用 ac=videolist 格式
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "videolist"),
                        URLQueryItem(name: "pg", value: "1")
                    ]
                )
            }
            if let listStr = try? await network.getString(from: listUrl, headers: sourceBean.headers) {
                let fallback = (try? parseVideoList(listStr, sourceBean: sourceBean)) ?? []
                if !fallback.isEmpty {
                    homeVideos = fallback
                }
            }
        }

        if !sourceBean.categories.isEmpty {
            let allowed = Set(sourceBean.categories)
            sorts = sorts.filter { allowed.contains($0.name) }
        }

        return (sorts, homeVideos)
    }

    private func parseSort(_ jsonStr: String, sourceBean: SourceBean) throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }

        var sorts: [MovieSort.SortData] = []
        var homeVideos: [Movie.Video] = []

        if sourceBean.type == 0 {
            // XML 格式
            sorts = parseXMLCategories(from: jsonStr)
        } else {
            // JSON 格式 (type=1, type=4)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let rootFilters = parseRootFilters(json["filters"])

                // 解析分类
                if let classList = json["class"] as? [[String: Any]] {
                    for cls in classList {
                        let id = stringValue(cls["type_id"]) ?? ""
                        let name = stringValue(cls["type_name"]) ?? ""
                        let flag = stringValue(cls["type_flag"]) ?? ""
                        let inlineFilters = parseFilters(cls["filters"])
                        let filters = inlineFilters.isEmpty ? (rootFilters[id] ?? []) : inlineFilters
                        sorts.append(MovieSort.SortData(id: id, name: name, flag: flag, filters: filters))
                    }
                }

                // 解析首页推荐视频
                if let list = json["list"] as? [[String: Any]] {
                    for item in list {
                        let decoder = JSONDecoder()
                        if let itemData = try? JSONSerialization.data(withJSONObject: item),
                           var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                            video.sourceKey = sourceBean.key
                            homeVideos.append(video)
                        }
                    }
                }
            }
        }

        return (sorts, homeVideos)
    }

    private func parseXMLCategories(from xml: String) -> [MovieSort.SortData] {
        // 简化的 XML 分类解析
        var sorts: [MovieSort.SortData] = []
        let pattern = "<ty id=\"(\\d+)\"[^>]*>([^<]+)</ty>"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                if let idRange = Range(match.range(at: 1), in: xml),
                   let nameRange = Range(match.range(at: 2), in: xml) {
                    let id = String(xml[idRange])
                    let name = String(xml[nameRange])
                    sorts.append(MovieSort.SortData(id: id, name: name))
                }
            }
        }
        return sorts
    }

    // MARK: - 获取分类视频列表

    /// 获取分类下的视频列表
    func getList(sourceBean: SourceBean, sortData: MovieSort.SortData, page: Int = 1, filters: [String: String]? = nil) async throws -> [Movie.Video] {
        try await getListPage(sourceBean: sourceBean, sortData: sortData, page: page, filters: filters).videos
    }

    /// 获取分类下的视频列表和分页信息
    func getListPage(sourceBean: SourceBean, sortData: MovieSort.SortData, page: Int = 1, filters: [String: String]? = nil) async throws -> VideoPage {
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        if try shouldUseBridge(for: sourceBean) {
            let jsonStr = try await bridge.category(source: sourceBean, sortData: sortData, page: page, filters: filters)
            return try parseVideoPage(jsonStr, sourceBean: sourceBean, requestedPage: page)
        }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }

        let url: String
        if sourceBean.type == 0 {
            // XML 接口
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "t", value: sortData.id),
                    URLQueryItem(name: "pg", value: String(page))
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "filter", value: "true"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]

            // 附加筛选参数（base64 编码）
            if let filters = filters, !filters.isEmpty {
                if let filterData = try? JSONSerialization.data(withJSONObject: filters),
                   let filterStr = String(data: filterData, encoding: .utf8) {
                    let ext = Self.base64URLString(filterStr)
                    queryItems.append(URLQueryItem(name: "ext", value: ext))
                }
            } else {
                let ext = Self.base64URLString("{}")
                queryItems.append(URLQueryItem(name: "ext", value: ext))
            }

            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "videolist"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]

            // 附加筛选参数
            if let filters = filters, !filters.isEmpty {
                if let filterData = try? JSONSerialization.data(withJSONObject: filters),
                   let filterStr = String(data: filterData, encoding: .utf8) {
                    queryItems.append(URLQueryItem(name: "f", value: filterStr))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        }

        let jsonStr = try await network.getString(from: url, headers: sourceBean.headers)
        return try parseVideoPage(jsonStr, sourceBean: sourceBean, requestedPage: page)
    }

    private func parseVideoList(_ jsonStr: String, sourceBean: SourceBean) throws -> [Movie.Video] {
        try parseVideoPage(jsonStr, sourceBean: sourceBean, requestedPage: 1).videos
    }

    private func parseVideoPage(_ jsonStr: String, sourceBean: SourceBean, requestedPage: Int) throws -> VideoPage {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }

        var videos: [Movie.Video] = []
        var responsePage = requestedPage
        var pageCount: Int?

        if sourceBean.type == 0 {
            videos = parseXMLVideoList(from: jsonStr, sourceKey: sourceBean.key)
        } else {
            // JSON 格式 (type=1, type=4)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                responsePage = intValue(json["page"]) ?? responsePage
                pageCount = intValue(json["pagecount"]) ?? intValue(json["pageCount"])
                let list = json["list"] as? [[String: Any]] ?? []
                let decoder = JSONDecoder()
                for item in list {
                    if let itemData = try? JSONSerialization.data(withJSONObject: item),
                       var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                        video.sourceKey = sourceBean.key
                        videos.append(video)
                    }
                }
            }
        }

        return VideoPage(videos: videos, page: responsePage, pageCount: pageCount)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? Double {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        if let value = value as? Bool { return value ? "1" : "0" }
        return nil
    }

    private func parseRootFilters(_ value: Any?) -> [String: [MovieSort.SortFilter]] {
        guard let object = value as? [String: Any] else { return [:] }
        var result: [String: [MovieSort.SortFilter]] = [:]
        for (key, rawValue) in object {
            let filters = parseFilters(rawValue)
            if !filters.isEmpty { result[key] = filters }
        }
        return result
    }

    private func parseFilters(_ value: Any?) -> [MovieSort.SortFilter] {
        if let array = value as? [[String: Any]] {
            return array.compactMap(parseFilter)
        }
        if let array = value as? [Any] {
            return array.compactMap { parseFilter($0 as? [String: Any]) }
        }
        if let object = value as? [String: Any], object["key"] != nil || object["value"] != nil || object["values"] != nil {
            return parseFilter(object).map { [$0] } ?? []
        }
        return []
    }

    private func parseFilter(_ object: [String: Any]?) -> MovieSort.SortFilter? {
        guard let object else { return nil }
        let key = stringValue(object["key"]) ?? ""
        guard !key.isEmpty else { return nil }
        let rawValues = object["value"] ?? object["values"]
        let values = parseFilterValues(rawValues)
        guard !values.isEmpty else { return nil }
        return MovieSort.SortFilter(
            key: key,
            name: stringValue(object["name"]) ?? key,
            initialValue: stringValue(object["init"]),
            values: values
        )
    }

    private func parseFilterValues(_ value: Any?) -> [MovieSort.SortFilter.SortFilterValue] {
        let rawItems: [[String: Any]]
        if let items = value as? [[String: Any]] {
            rawItems = items
        } else if let items = value as? [Any] {
            rawItems = items.compactMap { $0 as? [String: Any] }
        } else {
            rawItems = []
        }
        return rawItems.compactMap { item in
            let display = stringValue(item["n"]) ?? stringValue(item["name"]) ?? ""
            let rawValue = stringValue(item["v"]) ?? stringValue(item["value"]) ?? display
            guard !display.isEmpty || !rawValue.isEmpty else { return nil }
            return MovieSort.SortFilter.SortFilterValue(n: display.isEmpty ? rawValue : display, v: rawValue)
        }
    }

    private func parseXMLVideoList(from xml: String, sourceKey: String) -> [Movie.Video] {
        // 简化 XML 视频列表解析
        var videos: [Movie.Video] = []
        let pattern = "<video>.*?<id>(\\d+)</id>.*?<name><!\\[CDATA\\[(.+?)\\]\\]></name>.*?<pic>(.*?)</pic>.*?<note><!\\[CDATA\\[(.*?)\\]\\]></note>.*?</video>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                var video = Movie.Video()
                if let r = Range(match.range(at: 1), in: xml) { video.id = String(xml[r]) }
                if let r = Range(match.range(at: 2), in: xml) { video.name = String(xml[r]) }
                if let r = Range(match.range(at: 3), in: xml) { video.pic = String(xml[r]) }
                if let r = Range(match.range(at: 4), in: xml) { video.note = String(xml[r]) }
                video.sourceKey = sourceKey
                videos.append(video)
            }
        }
        return videos
    }

    // MARK: - 获取详情

    /// 获取视频详情
    func getDetail(sourceBean: SourceBean, vodId: String) async throws -> VodInfo? {
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        if try shouldUseBridge(for: sourceBean) {
            let jsonStr = try await bridge.detail(source: sourceBean, vodId: vodId)
            return try parseDetail(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
        }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }

        let url: String
        if sourceBean.type == 0 {
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "ids", value: vodId)
            ]

            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        }

        let jsonStr = try await network.getString(from: url, headers: sourceBean.headers)
        return try parseDetail(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
    }

    private func parseDetail(_ jsonStr: String, sourceKey: String, type: Int) throws -> VodInfo? {
        if type == 0 {
            return parseXMLDetail(jsonStr, sourceKey: sourceKey)
        }

        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["list"] as? [[String: Any]],
           let first = list.first {

            let decoder = JSONDecoder()
            if let itemData = try? JSONSerialization.data(withJSONObject: first),
               var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                video.sourceKey = sourceKey

                let playFrom = first["vod_play_from"] as? String ?? ""
                let playUrl = first["vod_play_url"] as? String ?? ""

                return VodInfo.from(
                    video: video,
                    playFrom: playFrom,
                    playUrl: playUrl,
                    flagGroups: parseStructuredFlagGroups(structuredFlagGroupsValue(in: first))
                )
            }
        }

        return nil
    }

    private func structuredFlagGroupsValue(in object: [String: Any]) -> Any? {
        for key in ["vodFlags", "vod_flags", "flags", "playFlags", "play_flags"] {
            if let value = object[key] { return value }
        }
        return nil
    }

    private func parseStructuredFlagGroups(_ value: Any?) -> [VodInfo.FlagGroup] {
        let flags: [[String: Any]]
        if let value = value as? [[String: Any]] {
            flags = value
        } else if let value = value as? [Any] {
            flags = value.compactMap { $0 as? [String: Any] }
        } else {
            return []
        }

        return flags.compactMap { flag in
            let name = firstStringValue(in: flag, keys: ["flag", "show", "name", "title", "from", "player"])
            guard !name.isEmpty else { return nil }

            let episodes = parseStructuredEpisodes(from: firstValue(in: flag, keys: ["episodes", "items", "list", "urls", "url", "playUrl", "vod_play_url"]))

            guard !episodes.isEmpty else { return nil }
            return VodInfo.FlagGroup(name: name, episodes: episodes)
        }
    }

    private func parseStructuredEpisodes(from value: Any?) -> [VodInfo.Episode] {
        if let value = value as? [[String: Any]] {
            return value.enumerated().compactMap { parseStructuredEpisode($0.element, index: $0.offset) }
        }
        if let value = value as? [Any] {
            return value.enumerated().flatMap { index, item -> [VodInfo.Episode] in
                if let object = item as? [String: Any] {
                    return parseStructuredEpisode(object, index: index).map { [$0] } ?? []
                }
                if let string = stringValue(item)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                    if string.contains("#") || string.contains("$") {
                        return VodInfo.episodes(from: string)
                    }
                    return [VodInfo.Episode(name: String(format: "%02d", index + 1), url: string)]
                }
                return []
            }
        }
        if let value = stringValue(value) {
            return VodInfo.episodes(from: value)
        }
        return []
    }

    private func parseStructuredEpisode(_ object: [String: Any], index: Int) -> VodInfo.Episode? {
        let url = firstStringValue(in: object, keys: ["url", "id", "playUrl", "vod_play_url", "episodeUrl"])
        guard !url.isEmpty else { return nil }
        let name = firstStringValue(in: object, keys: ["name", "title", "desc", "remark", "vod_name"])
        let fallbackName = String(format: "%02d", index + 1)
        return VodInfo.Episode(name: name.isEmpty ? fallbackName : name, url: url)
    }

    private func firstValue(in object: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key] { return value }
        }
        return nil
    }

    private func firstStringValue(in object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = stringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    // MARK: - 搜索

    /// 在指定源中搜索
    func search(sourceBean: SourceBean, keyword: String, quick: Bool = false) async throws -> [Movie.Video] {
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        if try shouldUseBridge(for: sourceBean) {
            let jsonStr = try await bridge.search(source: sourceBean, keyword: keyword, quick: quick)
            let videos = try parseVideoList(jsonStr, sourceBean: sourceBean)
            return filterSearchResults(videos, keyword: keyword)
        }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }

        let quickValue = String(quick)
        let url: String
        if sourceBean.type == 0 {
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "wd", value: keyword),
                    URLQueryItem(name: "quick", value: quickValue)
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "wd", value: keyword),
                URLQueryItem(name: "quick", value: quickValue)
            ]

            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "wd", value: keyword),
                    URLQueryItem(name: "quick", value: quickValue)
                ]
            )
        }

        let jsonStr = try await network.getString(from: url, headers: sourceBean.headers)
        let videos = try parseVideoList(jsonStr, sourceBean: sourceBean)
        return filterSearchResults(videos, keyword: keyword)
    }

    /// 多源并发搜索
    func searchAll(keyword: String) async -> [Movie.Video] {
        await searchGroups(keyword: keyword).flatMap(\.videos)
    }

    /// 多源并发搜索并保留来源分组，搜索页可和 Android 一样按站点切换。
    /// `onGroup` 会在每个源完成时立刻回调，用于搜索页渐进展示结果。
    func searchGroups(
        keyword: String,
        quick: Bool = false,
        onGroup: ((SearchResultGroup) async -> Void)? = nil
    ) async -> [SearchResultGroup] {
        let sources = await ApiConfig.shared.getSearchableSources()
        let candidates = sources.enumerated().filter { _, source in
            source.isAvailableForPlayback && (source.requiresBridge || source.isHttpApi)
        }
        let bridgeCandidates = candidates.map(\.1).filter { $0.requiresBridge }
        if !bridgeCandidates.isEmpty {
            try? await bridge.register(sources: bridgeCandidates, replace: false)
        }
        let maxConcurrentSearches = bridgeCandidates.isEmpty ? 20 : 10

        return await withTaskGroup(of: (Int, SourceBean, [Movie.Video]).self) { group in
            var nextCandidate = 0

            func enqueueNextSearch() {
                guard nextCandidate < candidates.count else { return }
                let (index, source) = candidates[nextCandidate]
                nextCandidate += 1
                group.addTask { [self] in
                    do {
                        if quick && !source.isQuickSearchEnabled { return (index, source, []) }
                        return (index, source, try await self.search(sourceBean: source, keyword: keyword, quick: quick))
                    } catch {
                        return (index, source, [])
                    }
                }
            }

            for _ in 0..<min(maxConcurrentSearches, candidates.count) {
                enqueueNextSearch()
            }

            var groups: [(Int, SearchResultGroup)] = []
            while let (index, source, videos) = await group.next() {
                if !videos.isEmpty {
                    let resultGroup = SearchResultGroup(source: source, videos: videos, sourceOrder: index)
                    groups.append((index, resultGroup))
                    await onGroup?(resultGroup)
                }
                enqueueNextSearch()
            }
            return groups.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// 对源返回结果做本地关键词过滤，规避部分接口返回推荐/无关内容。
    private func filterSearchResults(_ videos: [Movie.Video], keyword: String) -> [Movie.Video] {
        let tokens = keyword
            .split(whereSeparator: \.isWhitespace)
            .map { normalizeSearchText(String($0)) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return videos }

        return videos.filter { video in
            let searchableText = normalizeSearchText([
                video.name,
                video.note,
                video.actor,
                video.director,
                video.type,
                video.area,
                video.year
            ].joined(separator: " "))
            guard !searchableText.isEmpty else { return false }
            return tokens.allSatisfy { searchableText.contains($0) }
        }
    }

    private func normalizeSearchText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let scalars = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    // MARK: - 播放解析

    /// 对齐 Android `SiteApi.playerContent` + 可用的 `ParseJob` 子集。
    /// Swift 本地无法复用 Android native extractor / WebView 嗅探；这里优先覆盖直链、type=4 player、
    /// JSON 解析器、请求头、字幕、弹幕、DRM 等可直接表达的播放结果。
    func resolvePlayback(sourceBean: SourceBean, flag: String, id: String) async throws -> BridgePlayback {
        guard !sourceBean.requiresBridge else {
            return try await bridge.play(source: sourceBean, flag: flag, id: id)
        }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }

        var candidate: PlaybackCandidate
        if sourceBean.type == 4 {
            candidate = try await remotePlaybackCandidate(sourceBean: sourceBean, flag: flag, id: id)
        } else {
            candidate = syntheticPlaybackCandidate(sourceBean: sourceBean, flag: flag, id: id)
        }

        let parseContext = await MainActor.run {
            (parses: ApiConfig.shared.parseBeanList, flags: ApiConfig.shared.vodFlagList)
        }
        candidate = await resolvePlayableURLIfNeeded(
            candidate,
            parses: parseContext.parses,
            vodFlags: parseContext.flags
        )

        let playbackURL = candidate.playbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !playbackURL.isEmpty else { throw SourceError.parseError("播放地址为空") }

        return BridgePlayback(
            url: playbackURL,
            headers: candidate.headers,
            fallbackURL: nil,
            proxied: false,
            startPosition: candidate.startPosition,
            artwork: candidate.artwork,
            descriptionText: candidate.descriptionText,
            qualities: candidate.qualities,
            format: candidate.format,
            parse: candidate.parse,
            flag: candidate.flag,
            jxFrom: candidate.jxFrom,
            expiresAt: candidate.expiresAt,
            subtitles: candidate.subtitles,
            danmakus: candidate.danmakus,
            drm: candidate.drm
        )
    }

    private func remotePlaybackCandidate(sourceBean: SourceBean, flag: String, id: String) async throws -> PlaybackCandidate {
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(sourceBean.api) }
        var queryItems = [
            URLQueryItem(name: "play", value: id),
            URLQueryItem(name: "flag", value: flag)
        ]
        if let ext = sourceBean.ext, !ext.isEmpty {
            let extend = await resolveExtend(ext)
            if !extend.isEmpty {
                queryItems.append(URLQueryItem(name: "extend", value: extend))
            }
        }
        let url = try buildURL(base: sourceBean.api, queryItems: queryItems)
        let jsonStr = try await network.getString(from: url, headers: sourceBean.headers)
        let response = try decodePlayResponse(jsonStr)
        return PlaybackCandidate(response: response, sourceBean: sourceBean, fallbackFlag: flag, fallbackURL: id)
    }

    private func syntheticPlaybackCandidate(sourceBean: SourceBean, flag: String, id: String) -> PlaybackCandidate {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let playURLPrefix = sourceBean.playUrl
        let parse = Self.looksLikeDirectMediaURL(trimmedID) && playURLPrefix.isEmpty ? 0 : 1
        return PlaybackCandidate(
            rawURL: trimmedID,
            playbackURL: playURLPrefix + trimmedID,
            headers: sourceBean.headers,
            playUrl: playURLPrefix,
            parse: parse,
            flag: flag
        )
    }

    private func decodePlayResponse(_ jsonStr: String) throws -> BridgePlayResponse {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("播放结果不是 UTF-8")
        }
        return try decoder.decode(BridgePlayResponse.self, from: data)
    }

    private func resolvePlayableURLIfNeeded(
        _ candidate: PlaybackCandidate,
        parses: [ParseBean],
        vodFlags: [String]
    ) async -> PlaybackCandidate {
        let needsParse = candidate.parse == 1 || shouldUseParse(candidate: candidate, parses: parses, vodFlags: vodFlags)
        guard needsParse else { return candidate }
        guard let parser = selectJSONParser(
            playUrl: candidate.playUrl,
            flag: candidate.flag,
            parses: parses,
            requiresDefaultParse: needsParse
        ) else {
            return candidate
        }
        guard let parsed = await runJSONParser(parser, webURL: candidate.rawURL) else {
            return candidate
        }

        var resolved = candidate
        resolved.playbackURL = parsed.url
        resolved.rawURL = parsed.url
        if !parsed.headers.isEmpty {
            resolved.headers = parsed.headers
        }
        resolved.jxFrom = parsed.from ?? parser.name.nilIfBlank
        resolved.qualities = []
        return resolved
    }

    private func shouldUseParse(candidate: PlaybackCandidate, parses: [ParseBean], vodFlags: [String]) -> Bool {
        guard !parses.isEmpty else { return false }
        let flag = candidate.flag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flag.isEmpty else { return false }
        let matchesConfigFlag = vodFlags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
        return candidate.playUrl.isEmpty && matchesConfigFlag
    }

    private func selectJSONParser(
        playUrl: String,
        flag: String,
        parses: [ParseBean],
        requiresDefaultParse: Bool
    ) -> ParseBean? {
        let trimmedPlayURL = playUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPlayURL.range(of: "json:", options: [.caseInsensitive, .anchored]) != nil {
            let url = String(trimmedPlayURL.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : ParseBean(name: "json", url: url, type: 1)
        }
        if trimmedPlayURL.range(of: "parse:", options: [.caseInsensitive, .anchored]) != nil {
            let name = String(trimmedPlayURL.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            return parses.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.type == 1 && $0.matches(flag: flag)
            }
        }
        guard trimmedPlayURL.isEmpty else { return nil }
        guard requiresDefaultParse else { return nil }
        return parses.first { $0.type == 1 && $0.matches(flag: flag) }
            ?? parses.first { $0.type == 1 }
    }

    private func runJSONParser(_ parser: ParseBean, webURL: String) async -> ParsedPlaybackURL? {
        let parserURL = parser.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parserURL.isEmpty, !target.isEmpty else { return nil }

        do {
            let response = try await network.getString(from: parserURL + target, headers: parser.headers)
            return parseJSONParserResponse(response, fallbackHeaders: parser.headers, fallbackFrom: parser.name)
        } catch {
            return nil
        }
    }

    private func parseJSONParserResponse(
        _ jsonStr: String,
        fallbackHeaders: [String: String],
        fallbackFrom: String
    ) -> ParsedPlaybackURL? {
        if let response = try? decodePlayResponse(jsonStr),
           let url = response.rawUrl?.nilIfBlank ?? response.url?.nilIfBlank {
            let headers = PlaybackHTTPHeaders.normalized(response.headers)
            return ParsedPlaybackURL(
                url: url,
                headers: headers.isEmpty ? fallbackHeaders : headers,
                from: response.jxFrom?.nilIfBlank ?? fallbackFrom.nilIfBlank
            )
        }

        guard let data = jsonStr.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let topLevelURL = stringValue(object["url"])
        let dataObject = object["data"] as? [String: Any]
        let nestedURL = stringValue(dataObject?["url"])
        guard let url = (topLevelURL ?? nestedURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return nil
        }

        let headers = firstHeaderMap(in: [object, dataObject].compactMap { $0 })
        return ParsedPlaybackURL(
            url: url,
            headers: headers.isEmpty ? fallbackHeaders : headers,
            from: stringValue(object["jxFrom"])?.nilIfBlank ?? stringValue(object["from"])?.nilIfBlank ?? fallbackFrom.nilIfBlank
        )
    }

    private func firstHeaderMap(in objects: [[String: Any]]) -> [String: String] {
        for object in objects {
            for key in ["header", "headers"] {
                if let headers = object[key] as? [String: String] {
                    let normalized = PlaybackHTTPHeaders.normalized(headers)
                    if !normalized.isEmpty { return normalized }
                }
                if let headers = object[key] as? [String: Any] {
                    let normalized = PlaybackHTTPHeaders.normalized(
                        headers.reduce(into: [String: String]()) { result, item in
                            if let value = stringValue(item.value) {
                                result[item.key] = value
                            }
                        }
                    )
                    if !normalized.isEmpty { return normalized }
                }
            }
        }
        return [:]
    }

    // MARK: - Extend 解析

    /// 解析 extend 参数（对应 Android 端 getFixUrl）
    /// 如果 extend 是 HTTP URL，则下载其内容作为 extend 值
    /// 如果 extend 是普通字符串，则直接返回
    private func resolveExtend(_ extend: String) async -> String {
        guard !extend.isEmpty else { return "" }

        // 非 HTTP URL 直接返回
        guard extend.hasPrefix("http://") || extend.hasPrefix("https://") else {
            return extend
        }

        // 从 HTTP URL 加载 extend 内容
        do {
            let content = try await network.getString(from: extend)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 如果内容过长（>2500），回退到使用原始 URL
            if trimmed.count > 2500 { return extend }
            return trimmed
        } catch {
            return extend
        }
    }

    private func parseXMLDetail(_ xml: String, sourceKey: String) -> VodInfo? {
        guard let videoBlock = firstMatch(
            pattern: #"<video[\s\S]*?</video>"#,
            in: xml
        ) else {
            return nil
        }

        let vodId = extractXMLTag("id", in: videoBlock)
        guard !vodId.isEmpty else { return nil }

        var video = Movie.Video(id: vodId)
        video.name = extractXMLTag("name", in: videoBlock)
        video.pic = extractXMLTag("pic", in: videoBlock)
        video.note = extractXMLTag("note", in: videoBlock)
        video.year = extractXMLTag("year", in: videoBlock)
        video.area = extractXMLTag("area", in: videoBlock)
        video.type = extractXMLTag("type", in: videoBlock)
        video.director = extractXMLTag("director", in: videoBlock)
        video.actor = extractXMLTag("actor", in: videoBlock)
        video.des = extractXMLTag("des", in: videoBlock)
        video.sourceKey = sourceKey

        let ddNodes = extractXMLDDNodes(from: videoBlock)
        let playFrom: String
        let playUrl: String

        if ddNodes.isEmpty {
            playFrom = "默认"
            playUrl = ""
        } else {
            playFrom = ddNodes.map { $0.flag }.joined(separator: "$$$")
            playUrl = ddNodes.map { $0.url }.joined(separator: "$$$")
        }

        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
    }

    private func extractXMLDDNodes(from block: String) -> [(flag: String, url: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<dd([^>]*)>([\s\S]*?)</dd>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsRange = NSRange(block.startIndex..<block.endIndex, in: block)
        let matches = regex.matches(in: block, range: nsRange)
        var result: [(flag: String, url: String)] = []

        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            guard let attrRange = Range(match.range(at: 1), in: block),
                  let valueRange = Range(match.range(at: 2), in: block) else {
                continue
            }

            let attrs = String(block[attrRange])
            let rawUrl = decodeXMLText(String(block[valueRange]))
            guard !rawUrl.isEmpty else { continue }

            let flag = firstMatch(
                pattern: #"flag\s*=\s*["']([^"']+)["']"#,
                in: attrs,
                captureGroup: 1
            ) ?? "线路\(index + 1)"
            result.append((flag: decodeXMLText(flag), url: rawUrl))
        }

        return result
    }

    private func extractXMLTag(_ tag: String, in content: String) -> String {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escapedTag)>\\s*([\\s\\S]*?)\\s*</\(escapedTag)>"
        let value = firstMatch(pattern: pattern, in: content, captureGroup: 1) ?? ""
        return decodeXMLText(value)
    }

    private func firstMatch(pattern: String, in content: String, captureGroup: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > captureGroup,
              let subRange = Range(match.range(at: captureGroup), in: content) else {
            return nil
        }
        return String(content[subRange])
    }

    private func decodeXMLText(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>"), value.count >= 12 {
            value.removeFirst(9)
            value.removeLast(3)
        }
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&#39;", with: "'")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildURL(base: String, queryItems: [URLQueryItem]) throws -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBase) else {
            throw SourceError.invalidApiUrl(base)
        }

        var mergedQueryItems = components.queryItems ?? []
        mergedQueryItems.append(contentsOf: queryItems)
        components.queryItems = mergedQueryItems

        guard let url = components.url else {
            throw SourceError.invalidApiUrl(base)
        }
        return url.absoluteString
    }

    private static func base64URLString(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func looksLikeDirectMediaURL(_ value: String) -> Bool {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercased.isEmpty else { return false }
        if lowercased.contains("url=http") || lowercased.contains("v=http") || lowercased.contains(".html") {
            return false
        }
        if lowercased.hasPrefix("rtmp:") { return true }
        if lowercased.contains("video/tos") { return true }
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return false }
        return lowercased.range(
            of: #"\.(m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(\?|$)"#,
            options: .regularExpression
        ) != nil
    }
}

private struct ParsedPlaybackURL {
    let url: String
    let headers: [String: String]
    let from: String?
}

private struct PlaybackCandidate {
    var rawURL: String
    var playbackURL: String
    var headers: [String: String]
    var playUrl: String
    var parse: Int?
    var flag: String
    var jxFrom: String?
    var qualities: [BridgePlaybackQuality]
    var startPosition: TimeInterval?
    var artwork: String?
    var descriptionText: String?
    var format: String?
    var expiresAt: TimeInterval?
    var subtitles: [BridgePlaybackSubtitle]
    var danmakus: [BridgePlaybackDanmaku]
    var drm: PlayableDRM?

    init(
        rawURL: String,
        playbackURL: String,
        headers: [String: String],
        playUrl: String,
        parse: Int?,
        flag: String,
        jxFrom: String? = nil,
        qualities: [BridgePlaybackQuality] = [],
        startPosition: TimeInterval? = nil,
        artwork: String? = nil,
        descriptionText: String? = nil,
        format: String? = nil,
        expiresAt: TimeInterval? = nil,
        subtitles: [BridgePlaybackSubtitle] = [],
        danmakus: [BridgePlaybackDanmaku] = [],
        drm: PlayableDRM? = nil
    ) {
        self.rawURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.playbackURL = playbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = PlaybackHTTPHeaders.normalized(headers)
        self.playUrl = playUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parse = parse
        self.flag = flag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.jxFrom = jxFrom?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.qualities = qualities
        self.startPosition = startPosition
        self.artwork = artwork?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.descriptionText = descriptionText?.stripHTML.nilIfBlank
        self.format = format?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.expiresAt = expiresAt
        self.subtitles = subtitles
        self.danmakus = danmakus
        self.drm = drm
    }

    init(response: BridgePlayResponse, sourceBean: SourceBean, fallbackFlag: String, fallbackURL: String) {
        let rawURL = response.rawUrl?.nilIfBlank ?? response.url?.nilIfBlank ?? fallbackURL
        let playbackURL = response.url?.nilIfBlank ?? sourceBean.playUrl + rawURL
        let responseHeaders = PlaybackHTTPHeaders.normalized(response.headers)
        self.init(
            rawURL: rawURL,
            playbackURL: playbackURL,
            headers: responseHeaders.isEmpty ? sourceBean.headers : responseHeaders,
            playUrl: response.playUrl ?? "",
            parse: response.parse,
            flag: response.flag ?? fallbackFlag,
            jxFrom: response.jxFrom,
            qualities: response.qualities,
            startPosition: response.startPosition,
            artwork: response.artwork,
            descriptionText: response.descriptionText,
            format: response.format,
            expiresAt: response.expiresAt,
            subtitles: response.subtitles ?? [],
            danmakus: response.danmakus ?? [],
            drm: response.drm?.playableDRM
        )
    }
}

enum SourceError: LocalizedError {
    case emptyApi
    case parseError(String)
    case unsupportedType(String)
    case invalidApiUrl(String)

    var errorDescription: String? {
        switch self {
        case .emptyApi: return "接口地址为空"
        case .parseError(let msg): return "数据解析错误: \(msg)"
        case .unsupportedType(let type): return "暂不支持 \(type) 类型的数据源，请切换其他源"
        case .invalidApiUrl(let url): return "无效的接口地址: \(url)"
        }
    }
}
