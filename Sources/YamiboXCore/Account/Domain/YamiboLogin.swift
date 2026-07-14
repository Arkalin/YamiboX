import Foundation

public struct YamiboLoginQuestion: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public static let none = YamiboLoginQuestion(id: "0", title: "安全提问（未设置请忽略）")

    public static let defaultQuestions: [YamiboLoginQuestion] = [
        none,
        YamiboLoginQuestion(id: "1", title: "母亲的名字"),
        YamiboLoginQuestion(id: "2", title: "爷爷的名字"),
        YamiboLoginQuestion(id: "3", title: "父亲出生的城市"),
        YamiboLoginQuestion(id: "4", title: "您其中一位老师的名字"),
        YamiboLoginQuestion(id: "5", title: "您个人计算机的型号"),
        YamiboLoginQuestion(id: "6", title: "您最喜欢的餐馆名称"),
        YamiboLoginQuestion(id: "7", title: "驾驶执照最后四位数字")
    ]
}

public struct YamiboLoginRequest: Equatable, Sendable {
    public let username: String
    public let password: String
    public let questionID: String
    public let answer: String

    public init(username: String, password: String, questionID: String = "0", answer: String = "") {
        self.username = username
        self.password = password
        self.questionID = questionID
        self.answer = answer
    }
}

struct YamiboLoginForm: Sendable {
    var actionURL: URL
    var hiddenFields: [(String, String)]
    var questions: [YamiboLoginQuestion]
}
