# 分离编译检查、发布归档与更新说明

[Swift 工作流](../../.github/workflows/swift.yml)把编译检查开放给其他工作流复用，避免复制并逐渐分叉检查逻辑。它不是发布的隐式依赖，现行发布前仍需按[发布维护流程](../development/release.md#编译检查与质量门禁)验证同一个提交。

[发布身份校验](../../scripts/validate-release-identity.sh)从实际归档的 scheme、配置、destination 和 target 解析版本，因为工程文件可能同时包含多个配置，文本匹配不能证明发布身份。AltStore 分发会在安装时重签名，所以[发布工作流](../../.github/workflows/release.yml)产出未签名的 IPA。GitHub Release 保留 Markdown 和来源引用；应用内更新提示是纯文本，因此只在写入更新源时转换标题及来源引用。
