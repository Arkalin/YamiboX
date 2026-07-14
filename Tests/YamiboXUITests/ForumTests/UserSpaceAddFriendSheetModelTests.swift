import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
@Test func addFriendSheetModelClampsNoteToTenCharacters() {
    let model = UserSpaceAddFriendSheetModel()

    model.note = "一二三四五六七八九十十一十二"

    #expect(model.note == "一二三四五六七八九十")

    model.note = "短备注"

    #expect(model.note == "短备注")
}

@MainActor
@Test func addFriendSheetModelResolvesGroupWithFallbacks() {
    let model = UserSpaceAddFriendSheetModel()
    let form = UserSpaceAddFriendForm(
        uid: "705216",
        name: "张瑞泽",
        formHash: "form123",
        options: [
            UserSpaceAddFriendOption(id: 3, name: "同好"),
            UserSpaceAddFriendOption(id: 7, name: "好友")
        ]
    )
    let emptyForm = UserSpaceAddFriendForm(uid: "705216", name: nil, formHash: "form456", options: [])

    #expect(model.resolvedGroupID(for: form) == 3)
    #expect(model.resolvedGroupID(for: emptyForm) == 1)

    model.selectedGroupID = 7

    #expect(model.resolvedGroupID(for: form) == 7)
    #expect(model.resolvedGroupID(for: emptyForm) == 7)
}

@MainActor
@Test func addFriendSheetModelResetsGroupSelectionWhenFormChanges() {
    let model = UserSpaceAddFriendSheetModel()
    model.selectedGroupID = 9
    let form = UserSpaceAddFriendForm(
        uid: "705216",
        name: "张瑞泽",
        formHash: "form123",
        options: [UserSpaceAddFriendOption(id: 4, name: "同好")]
    )

    model.resetGroupSelection(for: form)

    #expect(model.selectedGroupID == 4)

    model.resetGroupSelection(for: nil)

    #expect(model.selectedGroupID == nil)
}
