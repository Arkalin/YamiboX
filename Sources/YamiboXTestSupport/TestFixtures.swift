import Foundation
import YamiboXCore

/// Discuz X3.5 touch/forum/post.htm upload structure with synthetic credentials.
public enum ForumMobileComposerFixture {
    public static let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=42&mobile=2")!
    public static let html = """
    <html><head><title>参与 / 回复主题</title></head><body><div id="ct">
    <form id="postform" method="post" action="forum.php?mod=post&amp;action=reply&amp;tid=42&amp;replysubmit=yes">
      <input type="hidden" name="formhash" value="fixture-formhash">
      <textarea id="needmessage" name="message" placeholder="写下想说的话..."></textarea>
      <div class="mimg">
        <a class="post_imgbtn">上传图片<input type="file" name="Filedata" id="filedata" multiple accept=".jpg,.jpeg,.gif,.png,image/jpeg,image/png"></a>
        <a class="post_attbtn">上传附件<input type="file" name="Filedata" id="attfiledata" multiple></a>
      </div>
      <button type="submit" name="replysubmit" value="true">发送回复</button>
    </form></div>
    <script>
    $(document).on('change', '#filedata', function() {
      if (typeof FileReader != 'undefined') {
        $.buildfileupload({
          uploadurl:'misc.php?mod=swfupload&operation=upload&type=image&inajax=yes&infloat=yes&simple=2',
          files:tmpfiles, uploadformdata:{uid:"123", hash:"fixture-mobile-hash"},
          uploadinputname:'Filedata', maxfilesize:"2048", success:uploadsuccess,
          error:function() { popup.open('上传失败'); }
        });
      } else {
        $.ajaxfileupload({
          url:'misc.php?mod=swfupload&operation=upload&type=image&inajax=yes&infloat=yes&simple=2',
          data:{uid:"123", hash:"fixture-mobile-hash"}, dataType:'text', fileElementId:'filedata',
          success:uploadsuccess, error:function() { popup.open('上传失败'); }
        });
      }
    });
    $(document).on('change', '#attfiledata', function() {
      if (typeof FileReader != 'undefined') {
        $.buildfileupload({
          uploadurl:'misc.php?mod=swfupload&operation=upload&fid=16&inajax=yes&infloat=yes&simple=2',
          files:tmpfiles, uploadformdata:{uid:"123", hash:"fixture-mobile-hash"},
          uploadinputname:'Filedata', maxfilesize:"5120", success:uploadsuccess,
          error:function() { popup.open('上传失败'); }
        });
      } else {
        $.ajaxfileupload({
          url:'misc.php?mod=swfupload&operation=upload&fid=16&inajax=yes&infloat=yes&simple=2',
          data:{uid:"123", hash:"fixture-mobile-hash"}, dataType:'text', fileElementId:'attfiledata',
          success:uploadsuccess, error:function() { popup.open('上传失败'); }
        });
      }
    });
    </script></body></html>
    """
}

/// 由 NovelReadingSessionTests / NovelReadingSessionRuntimeTests 收敛出的共享
/// fixture(两份私有副本逐字节一致):按 (章节标题, 正文) 列表构造小说投影。
public func makeNovelDocument(
    view: Int,
    maxView: Int,
    segments: [(chapterTitle: String, text: String)]
) -> NovelReaderProjection {
    NovelReaderProjection(
        threadID: "9001",
        view: view,
        maxView: maxView,
        segments: segments.map { .text($0.text, chapterTitle: $0.chapterTitle) }
    )
}

/// 由 FavoriteUpdateNotificationTests / FavoriteUpdateMonitorTests 收敛出的共享
/// fixture(两份副本仅差 `title` 参数,这里取参数并集;Notification 侧沿用原来
/// 硬编码的默认标题 “更新主题”)。
public func makeThreadPage(
    threadID: String,
    postID: String,
    title: String = "更新主题",
    replyCount: Int,
    pageCount: Int
) throws -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: threadID, fid: "50"),
        title: title,
        posts: [
            ForumThreadPost(
                postID: postID,
                author: BlogReaderUser(uid: "u1", name: "作者"),
                contentHTML: "<p>正文</p>",
                contentText: "正文"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: pageCount),
        totalReplies: replyCount,
        forumID: "50",
        forumName: "测试板块"
    )
}
