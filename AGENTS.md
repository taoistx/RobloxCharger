# Charger 开发规范

本文件定义本 Roblox 项目的代码和场景构建约定。新增功能、修改脚本和创建场景对象时，均应遵守本规范。

## 项目结构与 Rojo

本项目通过 Rojo 同步代码到 Studio，映射由 `default.project.json` 定义：

```text
src/shared  -> ReplicatedStorage/Shared
src/server  -> ServerScriptService/Server
src/client  -> StarterPlayer/StarterPlayerScripts/Client
```

- `*.server.luau` 是服务端 Script；只放服务端逻辑。
- `*.client.luau` 是客户端 LocalScript；只放输入、界面、镜头、音效和本地特效等表现逻辑。
- 普通 `*.luau` 用作 ModuleScript。需要两端共用的模块放入 `src/shared`。
- 不要在 Studio 中直接编辑由 Rojo 管理的脚本；修改源文件后通过 Rojo 同步。
- 验证脚本改动时，先停止当前模拟再启动新的 Play/Test 会话；已运行的脚本不会因为源文件同步而自动重启。

## 每次对话开始：Rojo 与 Studio MCP

每个**新开的对话**首次需要检查、调试或改动本项目时，先完成以下环境检查；同一对话的后续回合不重复执行。仅当 Rojo/MCP 会话已失效、Studio 被关闭、用户要求重新连接，或进行新的 Play/Test 验证时，才按需重新检查。

### Rojo 服务

- 先以只读方式检查是否存在正在运行的 **Rojo serve** 进程；不要只因看到 `rojo.exe` 就假定同步服务可用。
- 若 Rojo 未启动、不是 serve 模式，或无法确认正在为本项目同步，先明确提醒用户启动或修复 Rojo；除非用户明确授权，不自行额外启动一个 Rojo 服务。
- Rojo 正常后，改动由源文件同步到 Studio；可在 Studio Explorer 或 Studio MCP 中抽查对应脚本路径，确认同步实际生效。

### Studio MCP

- 每个对话优先复用已经存在且仍可响应的 Studio MCP 连接、Studio ID 和会话；连接成功后保存并持续复用它们，后续回合不得为了“再次确认”而重连。
- 若当前没有可用连接，先尝试连接 Studio MCP。首次失败时应有限重试（最多 3 次，串行进行），再向用户说明失败原因或需要其检查 Studio/插件状态。
- 不要并行建立连接，也不要每次工具调用都新建 stdio/MCP 会话。手动启动的 MCP 进程必须复用同一个会话；确认该会话已失效或退出后，才可创建一个替代会话。
- Studio MCP 可用时，脚本改动后应：确认 Rojo 已同步对应脚本、停止旧 Play、启动新的 Play/Test、检查 Client 和 Server Output；测试结束后停止 Play，回到 Edit 模式。
- Studio MCP 仅用于检查、Play/Test 和场景验证。Rojo 管理的脚本仍只修改本地 `src` 源文件，禁止通过 MCP 或 Studio 直接编辑这些脚本。

## 场景对象：标签负责行为，属性负责数据

场景中的 Part、Attachment 或 Model 不应各自携带业务 Script。功能由少量统一的组件/服务脚本根据标签绑定。

- **标签（Tag）**表示对象具备的行为或身份，例如 `Charger`、`Interactable`、`DamageZone`。
- **属性（Attribute）**表示该对象的配置或可展示状态，例如 `ChargeRate`、`Capacity`、`Enabled`、`CurrentCharge`。
- 标签和属性优先挂在功能对象的根 `Model`；若对象没有 Model，则挂在其核心 `BasePart`。不要依赖深层级路径或对象名称表达业务含义。
- 标签与属性名称使用 PascalCase，语义明确；避免含糊的 `Data`、`Value`、`Flag`。
- 属性只能存简单、可序列化的值和 Roblox 数据类型。复杂配置放入共享 ModuleScript；不要尝试用多个无意义属性拼装嵌套表。
- 每一个生产标签必须在对应组件模块的注释或常量表中写明：可接受的实例类型、必填属性、可选属性、默认值和有效范围。

推荐的充电桩对象约定：根 Model 带 `Charger` 标签，属性使用 `ChargeRate: number`、`Capacity: number`、`Enabled: boolean`；运行时展示状态可由服务端写入 `CurrentCharge: number`。

## 组件绑定与资源清理

一个标签由一个明确的服务端或客户端组件负责，不能让多个脚本隐式争抢同一行为。

组件初始化必须覆盖“已有对象”和“以后创建的对象”：

```lua
for _, instance in CollectionService:GetTagged(TAG) do
    bind(instance)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)
```

- `bind()` 必须可安全地重复调用，或显式防重复绑定。
- `bind()` 中先验证实例类型、必填属性和属性范围；无效配置使用带模块前缀的 `warn()`，且不继续启用行为。
- `unbind()` 必须断开所有事件连接、清除缓存和销毁临时实例。对象失去标签、被移出 DataModel 或被销毁时都要正确清理。
- 不要只依赖“标签新增”信号；启动前已经存在的带标签对象不会再次触发它。
- 开启 Streaming 时，客户端对象可能离开/重新进入已流送区域。客户端逻辑必须能动态绑定和解绑，不得把客户端标签或属性修改当作可靠持久状态。

## 客户端、服务端与安全边界

- 服务端是游戏规则、经济、奖励、伤害、存档、交互结果和可见给其他玩家状态的唯一权威。
- 客户端只提出请求和做本地表现；客户端传入的所有参数都不可信。
- 每个 RemoteEvent、RemoteFunction、ProximityPrompt、ClickDetector 或 DragDetector 的服务端处理器都必须验证：玩家状态与权限、目标类型及预期标签、目标所属位置、距离、属性值范围和调用频率。
- 客户端不得指定任意实例路径或让服务端直接修改任意实例。服务端必须自行从可信上下文找到或验证目标。
- 对会改变状态的请求，客户端可做冷却提示，但服务端必须独立执行限流与冷却。
- 服务器写入的标签和属性可用于同步给客户端展示；客户端本地修改不能作为服务端判定依据。

## Luau 代码约定

- 新脚本默认首行使用 `--!strict`。只有在已知的兼容性原因下才能例外，并在附近说明原因。
- 所有变量和函数使用 `local`，除非 Roblox API 明确要求全局；共享接口使用 ModuleScript 导出。
- 跨模块数据结构、公共函数参数和返回值应有 Luau 类型。共享类型集中在 `src/shared`。
- 一个模块只负责一类职责。服务端服务处理规则，客户端控制器处理表现，工具模块不直接启动业务流程。
- 标签名、属性名、远程名和默认值集中为常量，禁止在多个脚本中散落重复字符串。
- 日志统一携带模块前缀，例如 `print("[ChargerService] started")`、`warn("[ChargerService] invalid ChargeRate", instance)`。完成稳定功能后，移除临时高频 `print()`。
- 优先使用事件、属性变化信号和明确的任务调度；不要为普通状态检查创建逐帧 `Heartbeat`/`RenderStepped` 循环或无限轮询。

## 性能与生命周期

- 对每个连接、玩家缓存、运行中任务和创建的 Instance，都要定义其释放时机。
- 玩家离开时清除以 Player 或 UserId 为键的服务端缓存，并断开与该玩家及角色相关的连接。
- 高频视觉效果优先客户端生成；服务端只维护影响游戏规则的最少状态。
- 性能优化先使用 Studio 的 MicroProfiler、Script Profiler 或 Developer Console 量测；不要在没有量测前引入 Parallel Luau 或复杂缓存。

## 开发与验证清单

每次新增或修改功能，至少检查：

1. 已检查 Rojo serve 正在运行；若无法确认，已提醒用户处理。
2. 已复用或按规则连接 Studio MCP，且没有留下重复 MCP 会话。
3. Rojo 已同步，且 Studio Explorer 或 Studio MCP 中的脚本路径、类型和源文件一致。
4. 在新的 Play/Test 中查看 **View -> Output**；Output 需显示正确的 Client/Server 上下文。命令栏不是 Output。
5. 带标签的既有对象、新增对象、移除标签对象和销毁对象均已测试。
6. 客户端能够看到正确表现，但直接伪造 Remote 或交互事件不能绕过服务端规则。
7. 反复进入/离开、重生以及多玩家测试不会产生重复连接、重复奖励或持续增长的缓存。
