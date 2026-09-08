# Charger 开发规范

本文件定义本 Roblox 项目的代码和场景构建约定。新增功能、修改脚本和创建场景对象时，均应遵守本规范。

------

## 项目结构与 Rojo

本项目通过 Rojo 同步代码到 Studio，映射由 `default.project.json` 定义：

```text
src/shared  -> ReplicatedStorage/Shared
src/server  -> ServerScriptService/Server
src/client  -> StarterPlayer/StarterPlayerScripts/Client
```

当前仓库的主要结构：

```text
Charger/
├─ src/
│  ├─ shared/
│  │  ├─ GameplayConfig.luau
│  │  └─ MinionModifierConfig.luau
│  ├─ server/
│  │  ├─ GameplayBootstrap.server.luau
│  │  └─ Services/
│  │     ├─ BossService.luau
│  │     ├─ DemoArenaService.luau
│  │     ├─ GameplayUtil.luau
│  │     ├─ ForcedRunService.luau
│  │     ├─ MinionModifierService.luau
│  │     ├─ RandomMinionModifierGroupService.luau
│  │     ├─ MinionService.luau
│  │     ├─ MinionSpawnService.luau
│  │     ├─ PlayerEnergyService.luau
│  │     ├─ PlayerProgressionService.luau
│  │     ├─ KillZoneService.luau
│  │     └─ TrapService.luau
│  └─ client/
│     ├─ BossPresentation.client.luau
│     ├─ EnergyHud.client.luau
│     ├─ ForcedRunController.client.luau
│     ├─ MinionPickupPresentation.client.luau
│     ├─ MinionModifierPresentation.client.luau
│     ├─ RandomMinionModifierGroupPresentation.client.luau
│     ├─ MinionPresentation.client.luau
│     └─ ProgressionPresentation.client.luau
├─ docs/
│  ├─ MinionModifier.md
│  └─ TagsAndAttributes.md
├─ assets/
│  ├─ wooden+nutcracker+3d+model/
│  ├─ wooden+nutcracker+3d+model500/
│  └─ *.blend / *.blend1 / *.glb
├─ AGENTS.md
├─ default.project.json
├─ rojo-serve.bat
├─ Scene.rbxmx
└─ SoliderMinion.rbxm
```

- `src/shared` 保存客户端与服务端共用的标签、属性、玩法参数和配置校验。
- `src/server/GameplayBootstrap.server.luau` 是服务端入口，统一启动 `src/server/Services` 下的权威玩法服务。
- `src/server/Services` 保存玩家成长与能量、强制前进、士兵生成与队列、数量修改器、陷阱、即死区域、Boss、演示场景及通用实例工具。
- `src/client` 保存 HUD、Boss 玩家隔离与反馈、成长反馈、士兵跟随及数量修改器等客户端表现。
- `docs` 保存玩法对象的配置与使用说明。
- `assets`、`Scene.rbxmx` 和 `SoliderMinion.rbxm` 是场景与美术源资源，不在当前 Rojo 源码映射中。
- 新增、删除或移动上述主要模块和目录时，应同步更新本节。

### 跑动能量结算

- `GameplayConfig.Defaults.EnergyPerStud` 定义每 stud 跑动距离对应的能量。
- `GameplayConfig.Defaults.DistancePerEnergyAward` 定义一次能量结算所需累计的跑动距离（studs）。
- `PlayerEnergyService` 只累计玩家位于 `GameZone` 内的有效跑动距离；累计距离达到结算间隔后，按 `结算份数 × DistancePerEnergyAward × EnergyPerStud` 增加能量。
- 一次移动跨过多个结算间隔时必须结算全部完整份数，未满一个间隔的距离应保留到后续跑动，角色重建时清零。
- 跑动能量仍由服务端权威计算；客户端不得提交距离或决定结算结果。

### 玩家重生与出生保护

- `GameplayConfig.Defaults.PlayerRespawnSeconds` 定义玩家死亡后的重生间隔；当前值为 `0.5` 秒。
- `GameplayBootstrap.server.luau` 在服务启动前将该配置写入 `Players.RespawnTime`。不要在其他服务中重复实现角色自动重生计时。
- 修改重生间隔后必须停止旧模拟并启动新的 Play/Test；运行中的服务端不会因 Rojo 同步自动重启。
- 当前场景的 `Workspace.SpawnLocation.Duration` 应保持为 `0`，以禁用 Roblox 自动添加的可见 `ForceField` 出生保护球。新增 `SpawnLocation` 时，除非明确需要出生保护罩，也应将 `Duration` 设为 `0`。

### GameZone 预置 MinionPicker

- 服务器启动时，`MinionSpawnService` 会收集每个 `GameZone` 后代中已有且带 `MinionPicker` Tag 的有效对象，作为固定位置预置。
- 预置对象必须是 `BasePart` 或包含 `BasePart` 的 `Model`，并设置有效的 `MinionType`；该名称必须精确匹配 `ServerStorage/MinionTemplates` 的直接子对象。
- 场景中的预置原件只作为位置与外观原型。启动后服务会将原件移出 DataModel，并为每名玩家、每次出生在原位置创建带 `SpawnOwnerUserId` 的独立副本；因此运行时在原层级看不到预置原件属于正常行为。
- `GameZone.MinionSpawnCount` 是每名玩家在该区域的目标数量。有效预置数小于目标时，只随机补足差值；预置数大于目标时保留全部预置且不再随机生成。
- 预置数超过目标数的提示只允许在 `RunService:IsStudio()` 时输出，不得污染发布服务器日志或改变发布运行逻辑。
- `MinionSpawnCount = -1` 会同时禁用预置与随机 picker；仅使用三个手摆 picker 时应设为 `3`，而不是 `-1`。
- 随机 picker 选点时必须把预置位置计入 `MinionSpawnMinSpacing` 检查，避免随机对象与固定对象重叠。
- 玩家死亡、角色移除或离开服务器时必须清理该玩家的运行时 picker；重生后再次进入相应区域时，预置和随机 picker 都按新的一条命重新创建。

- `*.server.luau` 是服务端 Script；只放服务端逻辑。
- `*.client.luau` 是客户端 LocalScript；只放输入、界面、镜头、音效和本地特效等表现逻辑。
- 普通 `*.luau` 用作 ModuleScript。需要两端共用的模块放入 `src/shared`。
- 不要在 Studio 中直接编辑由 Rojo 管理的脚本；修改源文件后通过 Rojo 同步。
- 验证脚本改动时，如果 Studio MCP 当前可用，应停止旧模拟后再启动新的 Play/Test；已运行的脚本不会因为源文件同步而自动重启。
- 如果 Studio MCP 当前不可用，则跳过所有 Studio 运行时验证，不得因此阻塞脚本开发。

------

# 开发环境原则

## 默认优先完成代码任务

Codex 的首要目标是完成用户要求的代码修改，而不是维护、诊断或修复本地开发环境。

除非用户当前任务明确要求检查 Studio 场景、运行 Play/Test、查看 Output 或操作 Studio，否则：

- 不要为了“确保环境正常”进行长时间环境诊断。
- 不要反复启动 PowerShell 检查 Studio、MCP、端口或进程。
- 不要因为 Studio MCP 不可用而停止代码修改。
- 不要自行把“恢复 MCP”当作当前任务的一部分。
- 不要花费大量时间处理与当前代码任务无直接关系的开发环境问题。

能够通过本地源码完成的任务，应优先直接修改源码。

------

# 每次新对话：Rojo 与 Studio MCP

每个新开的对话首次需要检查、调试或修改本项目时，可以进行一次轻量环境判断。

同一对话后续回合不得重复进行环境探测。

只有以下情况可以重新检查：

- 用户明确要求重新连接；
- 用户明确要求运行新的 Play/Test；
- 用户明确要求检查 Studio 场景、Explorer 或 Output；
- 当前已有 MCP 会话在执行 Studio 相关任务期间明确失效。

------

## Rojo 服务

Rojo 主要用于将本地源码同步到 Studio。

### 检查规则

首次需要修改项目时，可以进行一次轻量的只读检查，判断是否已有本项目的 `rojo serve` 正在运行。

不要：

- 只因为看到 `rojo.exe` 就假定同步一定正常；
- 为了调查 Rojo 状态进行递归进程诊断；
- 反复执行 PowerShell 查询；
- 自动启动多个 Rojo 服务；
- 因为无法确认 Rojo 状态而阻止修改源码。

如果无法简单确认 Rojo 正常：

1. 提醒用户确认或启动 Rojo；
2. 继续完成本地源码修改；
3. 最终报告中注明未确认 Studio 侧同步状态。

除非用户明确授权，否则不要自行额外启动新的 Rojo serve。

------

# Studio MCP

## 本机已验证路径映射（2026-09-04）

当前项目与 Studio MCP 的有效路径为：

```text
Codex workspace: E:\Roblox\Projects\Charger
Codex project key: e:\roblox\projects\charger
Studio MCP executable: E:\Roblox\Versions\version-9fe94fb0e9d84c25\StudioMCP.exe
```

Codex 全局配置 `D:\Codex\.codex\config.toml` 中应使用：

```toml
[mcp_servers.Roblox_Studio]
command = 'E:\Roblox\Versions\version-9fe94fb0e9d84c25\StudioMCP.exe'
```

Roblox Studio 自动更新后 `version-*` 目录可能变化。如果配置指向的版本目录已不存在，
只在 `E:\Roblox\Versions` 的当前版本目录中定位 `StudioMCP.exe`，更新上述 `command`；
不要继续使用已经删除的旧版本路径，也不要扫描无关磁盘、端口或进程。

## 核心原则

Studio MCP 是一个**可选的验证工具**，不是修改 Luau 代码的必要条件。

如果当前已有明确可用的 Studio MCP 会话，则可以复用。

如果没有明确可用的 MCP，则不要为了寻找 MCP 而扫描进程、端口或系统状态。

原则：

```text
已知有可用 MCP
→ 使用 MCP

不知道有没有 MCP
→ 可以尝试一次连接

连接失败
→ 立即进入 Script-Only Mode
→ 继续修改代码
```

不要：

```text
连接失败
→ 查端口
→ 查进程
→ 启动 PowerShell
→ 查插件
→ 重启 MCP
→ 再连接
→ 再查 Studio
→ 再连接
```

------

## MCP 连接规则

每个新对话：

- 如果当前上下文中已经存在明确可用、仍能响应的 Studio MCP 会话，则直接复用。
- 不得为了寻找一个“可能存在”的 MCP 会话而扫描系统。
- 如果没有现成会话，并且当前任务确实需要 Studio，则最多尝试 **一次** MCP 连接。
- 首次连接失败后，立即停止所有 MCP 连接尝试。

**禁止自动重试 MCP。**

同一对话中一旦进入 Script-Only Mode，除非用户明确要求重新连接，否则不得再次尝试 MCP。

------

# Script-Only Mode

## 进入条件

满足以下任一条件时，本对话立即进入 **Script-Only Mode（仅脚本模式）**：

- 用户明确说明没有开启 Studio MCP；
- 当前没有可用的 Studio MCP；
- Studio MCP 首次连接失败；
- 已有 MCP 会话失效且当前任务不明确要求 Studio 验证；
- 当前任务本身只需要修改 Luau 源码，不需要 Studio 场景信息。

------

## Script-Only Mode 的硬规则

本节优先级高于本文所有 Play/Test、Explorer、Output、Studio 验证和场景检查规则。

进入 Script-Only Mode 后：

- **禁止继续尝试连接 Studio MCP。**
- **禁止自动重连 Studio MCP。**
- **禁止启动新的 MCP / stdio / 插件桥接进程。**
- **禁止为了诊断 MCP 执行 PowerShell。**
- **禁止扫描 Studio 端口。**
- **禁止扫描 MCP 进程。**
- **禁止为了“确认 Studio 是否运行”进行系统诊断。**
- **禁止启动 Play/Test。**
- **禁止停止或重试 Play/Test。**
- **禁止查看 Studio Explorer。**
- **禁止查看 Client Output。**
- **禁止查看 Server Output。**
- **禁止查看 Developer Console。**
- **禁止检查 Studio 当前模式。**
- **禁止检查 Studio 中对象当前运行状态。**
- **禁止因为不能验证 Studio 而阻塞代码任务。**
- **禁止将“恢复 Studio MCP”作为代码任务的隐式子任务。**

没有 Studio MCP **不是错误**。

没有 Studio MCP **不需要被修复**。

没有 Studio MCP **不影响完成普通 Luau 开发任务**。

------

## Script-Only Mode 下应该做什么

仅脚本模式下，只关心本地项目源码与配置。

主要允许操作：

```text
src/shared
src/server
src/client
default.project.json
相关项目配置文件
```

可以进行：

1. 阅读现有 Luau 源码。
2. 修改 Luau 源码。
3. 新建、拆分和重构 ModuleScript。
4. 调整客户端/服务端职责。
5. 修改共享类型。
6. 修改 Remote 定义。
7. 修改 CollectionService 组件逻辑。
8. 静态检查代码结构。
9. 检查 require 路径。
10. 检查类型和明显语法问题。
11. 阅读与当前修改直接相关的本地文件。
12. 根据 `default.project.json` 判断 Rojo 映射关系。

完成任务后报告：

- 修改了哪些文件；
- 修改了什么逻辑；
- 做了哪些静态检查；
- 如果 MCP 不可用，注明：

```text
Studio MCP 当前不可用，本次仅完成源码修改与静态检查，
未执行 Studio / Play/Test 运行时验证。
```

这不应被视为任务未完成。

------

## 什么时候允许重新连接 MCP

进入 Script-Only Mode 后，只有用户明确提出类似要求时，才允许重新尝试 Studio MCP：

```text
连接一下 Studio
用 MCP 看一下
帮我运行 Play/Test
看看 Studio 里的对象
检查 Output
测试一下实际效果
```

除此之外，不得自行重新连接。

------

# Play/Test 规则

Play/Test 是可选运行时验证，不是所有代码修改的强制步骤。

只有同时满足以下条件才允许进行 Play/Test：

1. 当前已经存在可正常响应的 Studio MCP 会话；
2. 不需要通过额外诊断才能获得该 MCP；
3. 当前修改确实值得运行时验证。

正确：

```text
MCP 已连接
→ 修改源码
→ Rojo 同步
→ 停止旧 Play
→ 启动新 Play
→ 检查 Output
→ 停止 Play
```

正确：

```text
MCP 不可用
→ 修改源码
→ 静态检查
→ 跳过 Play/Test
→ 完成任务
```

错误：

```text
MCP 不可用
→ 为了 Play/Test 修 MCP
→ 查 PowerShell
→ 查端口
→ 查 Studio
→ 重连
→ 再重连
```

------

# PowerShell 与环境诊断限制

Codex 不应将 PowerShell 当作默认探索手段。

除非当前任务明确需要，否则：

- 不要反复启动 PowerShell 子进程；
- 不要执行大量系统环境探测；
- 不要递归扫描磁盘；
- 不要递归扫描整个项目；
- 不要检查与当前修改无关的系统进程；
- 不要检查与当前修改无关的网络端口；
- 不要为了确认 MCP 状态反复调用 PowerShell；
- 不要因为一个命令失败就连续尝试多个等价 PowerShell 命令。

优先使用明确路径和针对性操作。

例如需要寻找代码时优先：

```text
rg
精确文件路径
明确的 src 子目录
```

避免：

```text
Get-ChildItem -Recurse 整个项目
递归扫描 .git
递归扫描大型资源目录
全盘查找 Roblox / Studio / MCP 文件
```

环境检查应快速失败、快速降级。

------

# 场景对象：标签负责行为，属性负责数据

场景中的 Part、Attachment 或 Model 不应各自携带业务 Script。

功能由少量统一的组件/服务脚本根据标签绑定。

- **标签（Tag）**表示对象具备的行为或身份，例如 `Charger`、`Interactable`、`DamageZone`。
- **属性（Attribute）**表示对象的配置或可展示状态，例如 `ChargeRate`、`Capacity`、`Enabled`、`CurrentCharge`。
- 标签和属性优先挂在功能对象的根 `Model`。
- 如果对象没有 Model，则挂在其核心 `BasePart`。
- 不要依赖深层级路径或对象名称表达业务含义。
- 标签与属性名称使用 PascalCase。
- 避免含糊名称，例如 `Data`、`Value`、`Flag`。
- 属性只能存简单、可序列化的值以及 Roblox 支持的数据类型。
- 复杂配置放入共享 ModuleScript。
- 不要使用大量无意义 Attribute 拼装复杂嵌套数据。

每一个生产标签必须在对应组件模块的注释或常量定义中注明：

- 可接受的 Instance 类型；
- 必填属性；
- 可选属性；
- 默认值；
- 有效范围。

推荐的充电桩对象约定：

```text
Root Model
Tag: Charger

Attributes:
ChargeRate: number
Capacity: number
Enabled: boolean
CurrentCharge: number
```

`CurrentCharge` 等运行时权威状态应由服务端维护。

------

# 组件绑定与资源清理

一个标签应由一个明确的服务端或客户端组件负责。

不要让多个脚本隐式争抢同一个行为。

组件初始化必须同时覆盖：

- 启动前已经存在的对象；
- 运行过程中新增的对象；
- 标签被移除的对象。

推荐结构：

```lua
for _, instance in CollectionService:GetTagged(TAG) do
    bind(instance)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)
```

要求：

- `bind()` 必须可以安全重复调用，或者显式防止重复绑定。
- `bind()` 应验证 Instance 类型。
- `bind()` 应验证必填属性。
- `bind()` 应验证属性范围。
- 无效配置使用带模块前缀的 `warn()`。
- 无效对象不得继续启用业务逻辑。

`unbind()` 必须：

- 断开事件；
- 清理缓存；
- 停止任务；
- 销毁临时 Instance；
- 移除对象关联状态。

对象：

- 失去标签；
- 被移出 DataModel；
- 被销毁；

都必须能够正确清理。

不要只依赖 `GetInstanceAddedSignal()`，因为启动前已有标签对象不会重新触发它。

开启 Streaming 时：

- 客户端对象可能离开流送范围；
- 也可能重新进入流送范围；
- 客户端逻辑必须支持动态 bind / unbind；
- 客户端修改 Tag 或 Attribute 不得视为可靠持久状态。

------

# 客户端、服务端与安全边界

服务端是以下内容的唯一权威：

- 游戏规则；
- 经济；
- 奖励；
- 伤害；
- 存档；
- 交互结果；
- 需要同步给其他玩家的状态。

客户端负责：

- 输入；
- UI；
- 镜头；
- 声音；
- 本地视觉表现；
- 向服务端提出操作请求。

客户端传入的数据一律视为不可信。

以下服务端入口必须验证：

- `RemoteEvent`
- `RemoteFunction`
- `ProximityPrompt`
- `ClickDetector`
- `DragDetector`

至少验证：

- 玩家状态；
- 玩家权限；
- 目标 Instance 类型；
- 目标是否带预期 Tag；
- 目标是否属于可信区域；
- 玩家与目标距离；
- 参数范围；
- Attribute 范围；
- 调用频率；
- 服务端冷却。

客户端不得：

- 指定任意实例路径让服务端修改；
- 指定任意 Instance 作为可信目标；
- 直接决定奖励数值；
- 直接决定伤害；
- 直接决定经济结果；
- 直接决定持久化结果。

服务端必须自行根据可信上下文解析目标。

客户端可以显示冷却，但服务端必须独立实施限流和冷却。

服务端写入的 Tag 和 Attribute 可以同步给客户端作为展示依据。

客户端本地修改不得成为服务端规则判定依据。

------

# Luau 代码约定

## Strict

新脚本默认：

```lua
--!strict
```

只有存在明确兼容性原因时才允许例外，并在附近说明原因。

------

## 局部变量

所有变量和函数默认使用：

```lua
local
```

除非 Roblox API 明确要求其他形式。

共享接口使用 ModuleScript 导出。

------

## 类型

以下内容应尽量提供 Luau 类型：

- 跨模块数据结构；
- 公共函数参数；
- 公共函数返回值；
- 服务接口；
- Remote 数据结构。

共享类型优先集中在：

```text
src/shared
```

------

## 单一职责

一个模块只负责一类职责。

例如：

```text
Server Service
→ 游戏规则与权威状态

Client Controller
→ 输入与表现

Shared Module
→ 类型、常量、共享算法

Utility
→ 无业务启动副作用的工具函数
```

工具模块不应因为被 `require()` 就自动启动大型业务流程。

------

## 常量

以下字符串应集中定义，不要散落重复硬编码：

- Tag 名；
- Attribute 名；
- Remote 名；
- 默认值；
- 配置键。

------

## 日志

统一使用模块前缀。

例如：

```lua
print("[ChargerService] started")

warn("[ChargerService] invalid ChargeRate", instance)
```

稳定功能完成后移除临时高频 `print()`。

------

## 事件优先

普通状态变化优先：

- Roblox Event；
- Signal；
- Attribute change；
- 明确的 task 调度。

避免为普通状态检查创建：

```text
Heartbeat
RenderStepped
while true do
无限轮询
```

除非确有逐帧需求。

------

# 性能与生命周期

对以下资源都必须定义释放时机：

- RBXScriptConnection；
- 玩家缓存；
- Character 缓存；
- 运行中的 task；
- 临时 Instance；
- Tween；
- 状态表；
- 组件绑定记录。

玩家离开时：

- 清理以 Player 为键的缓存；
- 清理以 UserId 为键的缓存；
- 断开玩家事件；
- 清理 Character 事件；
- 停止相关任务。

高频视觉效果优先在客户端生成。

服务端只维护影响游戏规则所需的最少状态。

不要在没有量测依据时引入：

- Parallel Luau；
- 复杂缓存；
- 自定义调度器；
- 大型 ECS；
- 过早微优化。

如果 Studio MCP 当前可用，可以使用：

- MicroProfiler；
- Script Profiler；
- Developer Console。

如果 Studio MCP 不可用，则跳过性能运行时量测，不得为了量测主动修复 MCP。

------

# 开发与验证清单

每次新增或修改功能，根据当前模式检查。

## 所有模式都需要

1. 修改正确的 `src` 源文件。
2. 没有通过 Studio 直接修改 Rojo 管理的脚本。
3. require 路径与 `default.project.json` 映射一致。
4. 客户端与服务端职责没有混淆。
5. Remote 输入经过服务端验证。
6. 新增连接、缓存和 Instance 有明确释放逻辑。
7. 已完成合理的静态代码检查。
8. 没有为了环境验证而执行无意义的重复 PowerShell 命令。

------

## Studio MCP 可用时额外检查

只有当前已经存在正常工作的 Studio MCP 时，才执行：

1. 确认 Rojo 已同步相关脚本。
2. 如有必要检查 Explorer 中实例路径。
3. 停止旧 Play/Test。
4. 启动新的 Play/Test。
5. 查看正确的 Client / Server Output。
6. 测试已有标签对象。
7. 测试运行时新增标签对象。
8. 测试移除标签。
9. 测试对象销毁。
10. 必要时测试玩家重生。
11. 必要时测试多玩家。
12. 测试结束后停止 Play，返回 Edit 模式。

------

## Script-Only Mode 时

Studio 相关验证全部自动记为：

```text
N/A — Studio MCP unavailable
```

不得把以下项目视为任务失败：

- 未运行 Play/Test；
- 未检查 Explorer；
- 未检查 Output；
- 未验证 Studio 场景；
- 未进行多玩家运行时测试。

最终简单说明：

```text
本次在 Script-Only Mode 下完成。
已修改源码并进行静态检查。
Studio MCP 当前不可用，因此未执行 Studio / Play/Test 验证。
```

然后结束任务。

**不要继续尝试修复 MCP。**
