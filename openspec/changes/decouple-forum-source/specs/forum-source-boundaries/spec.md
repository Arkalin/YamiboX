# Spec Delta

## Purpose

为论坛数据源建立可独立编译、装配和替换的开发期边界，使论坛协议变化无需传播到阅读、书库、公共界面与用户数据实现，同时保留论坛专用界面对来源公开能力的有意依赖。

## ADDED Requirements

### Requirement: 编译依赖符合最终七模块边界

系统 SHALL 使用七个实际 package targets；项目内直接依赖 SHALL 限于 Core 无上游业务模块、UI 依赖 Core、ForumSource 依赖 Core、Reader 和 Library 各自依赖 Core/UI、UserData 依赖 Core、Forum 依赖 Core/UI/ForumSource。App SHALL 负责组合这些模块。Reader、Library、UserData 与公共 UI MUST NOT 直接或传递依赖 ForumSource。

#### Scenario: 非论坛模块独立消费中立契约
- **WHEN** 检查 package 的声明依赖及其传递闭包，并分别编译非论坛消费者
- **THEN** Reader、Library、UserData 与公共 UI 不需要 ForumSource、Forum 或 App 的实现即可满足其模块依赖
- **AND** Forum 可以使用 ForumSource 显式公开的论坛专用 API

#### Scenario: 旧过渡依赖不能成为交付状态
- **WHEN** Library 或其他非论坛模块仍通过临时包装、重新导出或聚合模块访问 ForumSource
- **THEN** 边界检查失败，不能以 App 整体构建成功认定解耦完成

### Requirement: Core 不成为间接业务依赖通道

Core SHALL 仅导出来源中立的值、能力契约、必要的纯计算规则及共享基础资源；MUST NOT 承载来源协议实现、应用装配、具体存储、网络执行或功能页面。论坛 DTO、解析器和具体 Store MUST NOT 通过改名、类型别名、宽依赖包或整模块重新导出伪装成中立契约。

#### Scenario: Source 依赖 Core 不会获得应用实现
- **WHEN** 单独构建 ForumSource 及其声明依赖
- **THEN** 构建闭包不包含阅读/书库工作流、数据库实现、账号存储、平台交互或 App 装配代码

#### Scenario: 公共签名不泄漏实现类型
- **WHEN** 消费者仅导入 Core 并实现或调用中立能力
- **THEN** 无需命名论坛实体、HTML 解析类型、数据库对象、图片管线对象或具体账号 Store

### Requirement: 论坛专用与来源中立 API 分离

ForumSource SHALL 提供供 Forum 使用的论坛专用公开能力，并实现供其他功能使用的中立内容、目录发现、远端收藏、更新检查与资源能力。中立 API SHALL 以不透明来源身份、位置和资源引用表达请求与结果；MUST NOT 要求消费者解释论坛页码、作者筛选、帖子结构、HTML、认证字段或请求头。

#### Scenario: 阅读器不计算来源分页规则
- **WHEN** 阅读器请求下一段内容或恢复已保存的位置
- **THEN** 它提交来源给出的不透明位置并获得中立内容及后续位置，不自行构造论坛参数或对来源页码做运算

#### Scenario: 论坛功能继续访问专用能力
- **WHEN** Forum 展示帖子、执行发帖编辑或论坛专属交互
- **THEN** 它通过 ForumSource 的公开论坛 API 获取所需模型和远端结果，而不访问来源内部解析、传输或存储实现

#### Scenario: 来源不支持可选能力
- **WHEN** 一个符合中立契约的来源不提供评论、评分或原帖等可选能力
- **THEN** 消费者获得明确的不可用结果并安全隐藏或禁用对应入口，不尝试向下转换到论坛实现

### Requirement: 来源可用独立宿主显式装配

ForumSource SHALL 接受显式运行环境及最小外部能力，支持由仅持有其合法依赖的宿主装配。创建来源 MUST NOT 隐式读取 App 启动参数、全局 App 容器或当前账号 Store，也 MUST NOT 隐式初始化数据库、Keychain、磁盘缓存或功能页面。

#### Scenario: 无 App 的内存宿主
- **WHEN** 一个不导入 Reader、Library、UserData、公共 UI 或 App 的宿主提供内存传输、凭据、缓存和诊断能力
- **THEN** 它能够创建 ForumSource 并完成代表性的内容读取与解析，不访问宿主未提供的生产账号或存储设施

#### Scenario: 缺少必须的运行能力
- **WHEN** 宿主未提供请求所需环境或安全能力
- **THEN** 装配或调用明确失败，不回退到全局单例、默认账号、默认数据库或隐藏网络环境

### Requirement: 算法归属不由装配层掩盖

来源 URL 解释、论坛协议、内容解析、分页、来源发现和来源资源请求策略 SHALL 由 ForumSource 负责。阅读交互、本地目录编辑、书库操作和用户数据事务 SHALL 由对应消费者或存储能力负责。App 适配 SHALL 限于连接能力、转换边界值和协调宿主生命周期，MUST NOT 变成来源算法或持久化算法的替代实现。

#### Scenario: 修改论坛协议只影响来源责任
- **WHEN** 来源的 HTML 结构、URL 规则、分页或资源鉴权规则发生变化
- **THEN** 不需要修改 Reader、Library、UserData 或公共 UI 中的来源解析逻辑，因为这些模块不包含此类逻辑

#### Scenario: 修改本地目录不重新解释远端协议
- **WHEN** 用户编辑目录并触发身份重映射
- **THEN** 本地业务提交中立身份变更，由用户数据能力原子落盘，不调用论坛解析器或在存储事务内访问网络

### Requirement: 非论坛网络能力不经由论坛来源

应用的非论坛网络消费者 SHALL 仅依赖它们实际需要的中立传输、安全配置与诊断能力；MUST NOT 因共享网络基础设施而依赖 ForumSource、论坛会话或论坛 URL 规则。

#### Scenario: 仅装配同步或更新能力
- **WHEN** 宿主提供 WebDAV 同步或应用更新检查的配置与传输能力，其既有授权前置条件已由中立账号上下文满足，而未创建论坛来源
- **THEN** 这些能力仍可执行自身请求和错误处理，不要求构造论坛会话实现、论坛缓存或论坛解析器，也不绕过原有账号/同步授权检查

### Requirement: 架构准入能拒绝非法依赖

项目 SHALL 提供可执行的架构准入，检查实际 target 存在性、声明依赖、传递依赖、禁止导入和已知实现泄漏。准入 SHALL 对违规返回非零结果及可定位原因，并包含证明它确实拒绝违规的负向验证；MUST NOT 仅以目录命名、文档声明或字符串搜索无命中认定所有边界通过。

#### Scenario: 声明非法依赖或导入
- **WHEN** 验证副本加入 Reader 到 ForumSource 的依赖，或以限定、修饰、重新导出等形式导入禁止模块
- **THEN** 准入失败并指出违规模块或文件

#### Scenario: 通过 Core 绕过边界
- **WHEN** 验证副本让 Core 依赖业务模块，或把已识别的论坛具体模型重新暴露为中立消费者签名
- **THEN** 对应的依赖或泄漏检查失败；移除注入后原项目通过同一准入

#### Scenario: 更换消费者的来源实现
- **WHEN** 使用内存能力替换论坛来源来驱动阅读、详情、目录发现、远端收藏和更新检查
- **THEN** 消费者能够完成约定流程，不实例化或调用真实论坛来源，也不依靠未声明的运行时类型转换
