import Foundation

struct TagGroup: Equatable, Sendable {
    let id: UUID
    var displayName: String
    var sortOrder: Int
    let isSystem: Bool
}

/// Stable seed IDs for the seven built-in sidebar groups. Migration and runtime share these UUIDs.
enum TagGroupSeed: Int, CaseIterable, Identifiable, Sendable {
    case people
    case placesAndScenes
    case activities
    case food
    case nature
    case documents
    case other

    var id: UUID {
        switch self {
        case .people:
            UUID(uuidString: "a0000000-0000-4000-8000-000000000001")!
        case .placesAndScenes:
            UUID(uuidString: "a0000000-0000-4000-8000-000000000002")!
        case .activities:
            UUID(uuidString: "a0000000-0000-4000-8000-000000000003")!
        case .food:
            UUID(uuidString: "a0000000-0000-4000-8000-000000000004")!
        case .nature:
            UUID(uuidString: "a0000000-0000-4000-8000-000000000005")!
        case .documents:
            UUID(uuidString: "a0000000-0000-4000-8000-000000000006")!
        case .other:
            UUID(uuidString: "a0000000-0000-4000-8000-000000000007")!
        }
    }

    var displayName: String {
        switch self {
        case .people: "人物与关系"
        case .placesAndScenes: "地点与场景"
        case .activities: "活动与事件"
        case .food: "美食与餐饮"
        case .nature: "自然与动植物"
        case .documents: "文档与屏幕"
        case .other: "物品与其他"
        }
    }

    var sortOrder: Int { rawValue }

    /// One-time / create-time keyword seed. After assignment, membership is user-owned.
    static func classify(displayName: String) -> TagGroupSeed {
        let normalized = displayName.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let keywordGroups: [(TagGroupSeed, [String])] = [
            (.people, [
                "人像", "人物", "肖像", "自拍", "合影", "家人", "家庭", "朋友", "亲友", "儿童", "孩子", "宝宝",
                "person", "people", "portrait", "selfie", "family", "friend", "child", "baby",
            ]),
            (.placesAndScenes, [
                "旅行", "地点", "城市", "乡村", "街道", "户外", "室内", "环境", "场景", "风景", "海滩", "海边",
                "山景", "水域", "建筑", "公园", "travel", "place", "city", "street", "outdoor", "indoor", "scene",
                "landscape", "beach", "mountain", "water", "building", "architecture", "park",
            ]),
            (.activities, [
                "活动", "运动", "聚会", "生日", "节日", "庆典", "婚礼", "演出", "会议", "工作", "课堂", "比赛", "event",
                "activity", "sport", "party", "birthday", "festival", "holiday", "wedding", "concert", "meeting",
                "work", "game",
            ]),
            (.food, [
                "美食", "食物", "餐饮", "早餐", "午餐", "晚餐", "菜肴", "饮料", "咖啡", "甜点", "水果", "food",
                "meal", "breakfast", "lunch", "dinner", "drink", "coffee", "dessert", "fruit",
            ]),
            (.nature, [
                "自然", "动物", "宠物", "猫", "狗", "鸟", "植物", "花卉", "鲜花", "树木", "野生", "animal", "pet",
                "cat", "dog", "bird", "plant", "flower", "tree", "wildlife", "nature",
            ]),
            (.documents, [
                "截图", "屏幕", "文档", "文件", "票据", "收据", "发票", "二维码", "文字", "表格", "幻灯片",
                "screenshot", "screen", "document", "receipt", "invoice", "qr", "text", "spreadsheet", "slide",
            ]),
        ]
        return keywordGroups.first { _, keywords in
            keywords.contains { normalized.localizedCaseInsensitiveContains($0) }
        }?.0 ?? .other
    }
}
