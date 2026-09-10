import Testing
@testable import YamiboXCore

@Suite
struct DiscuzFormHashParserTests {
    @Test(arguments: [
        "data:{'favoritesubmit':'true', 'formhash':'a1b2c3d4'}",
        #"data: {"favoritesubmit": "true", "formhash": "a1b2c3d4"}"#,
        "data: { favoritesubmit: true, formhash: 'a1b2c3d4', }"
    ])
    func extractsTouchTemplateAJAXToken(parameters: String) throws {
        let html = "<html><body><script>$.ajax({type:'POST', \(parameters)});</script></body></html>"
        let document = try KannaSoup.parse(html)
        #expect(DiscuzFormHashParser.formHash(in: document, html: html) == "a1b2c3d4")
        #expect(DiscuzFormHashParser.formHash(inHTML: html) == "a1b2c3d4")
    }

    @Test func preservesFormAndLogoutLinkPrecedence() throws {
        let script = "<script>$.ajax({data:{formhash:'scripttoken'}});</script>"
        for source in [
            #"<input name="formhash" value="preferred">"#,
            #"<div class="btn_exit"><a href="member.php?action=logout&amp;formhash=preferred">Logout</a></div>"#
        ] {
            let html = "<html><body>\(source)\(script)</body></html>"
            let document = try KannaSoup.parse(html)
            #expect(DiscuzFormHashParser.formHash(in: document, html: html) == "preferred")
            #expect(DiscuzFormHashParser.formHash(inHTML: html) == "preferred")
        }
    }

    @Test(arguments: [
        "<pre>data:{formhash:'posttext'}</pre>",
        "<script src='external.js'>$.ajax({data:{formhash:'external'}});</script>",
        "<script>$.ajax({data:{formhash:getToken()}});</script>",
        "<script>$.ajax({data:{formhash:''}});</script>",
        "<script>$.ajax({data:{hash:'uploadtoken'}});</script>"
    ])
    func rejectsNonLiteralAndNonScriptTokens(source: String) throws {
        let html = "<html><body>\(source)</body></html>"
        let document = try KannaSoup.parse(html)
        #expect(DiscuzFormHashParser.formHash(in: document, html: html) == nil)
        #expect(DiscuzFormHashParser.formHash(inHTML: html) == nil)
    }

    @Test func skipsUnrelatedAJAXParameters() throws {
        let html = """
        <html><body><script>
        $.ajax({data:{formhash:getToken()}});
        $.ajax({data:{hash:'unrelated'}});
        $.ajax({data:{'favoritesubmit':'true', 'formhash':'a1b2c3d4'}});
        </script></body></html>
        """
        let document = try KannaSoup.parse(html)
        #expect(DiscuzFormHashParser.formHash(in: document, html: html) == "a1b2c3d4")
        #expect(DiscuzFormHashParser.formHash(inHTML: html) == "a1b2c3d4")
    }
}
