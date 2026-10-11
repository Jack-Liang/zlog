# 前台报错可追溯性改造 — 开发计划

> 版本：v1.0（已交付）　日期：2026-10-11
> 目标系统：自有 ABAP 系统（经典 ABAP，7.40+）

> **状态（2026-10-11 收口）**：阶段 1~3 已全部实现并真机验收（a4h / ABAP Platform 816），代码在 GitHub `Jack-Liang/zlog`，功能与用法以仓库 README 为准。功能点对照：A1~A10 全交付（A8 为 JSON 快照侧表 ZMSGTRACE_CTX）；B1~B3 代码形态交付（出口实装待生产落地）；C1~C4 全交付；D1/D2/D3/D5 交付（D6 由 ZMSGTRACE_CLEANUP 按日期对齐替代 ENHO 挂接）；E1/E3 交付，E2 为持续性业务工作。按需待做：D4 临时日志级别、D6 正式挂接、B4 RAP、Fiori 查询。计划外新增：行号漂移对策（追溯行 `line N/M` + 语句摘录 + 查询端自动愈合跳转）。发布基线 816；移植 7.5x 需改回 `I_S_LOG_HEADER`（见 README 已知限制）。


## 1. 背景与目标

**问题**：用户在前台看到报错，只知道消息文本；开发排查时不知道消息在哪里报的、什么时候报的，靠 where-used 和复现摸索，耗时长。

**目标**：每条用户可见的消息携带一个日志 ID；支持人员凭 ID 即可查到该消息的**时间、用户、系统环境、报错位置（程序/Include/行号）、业务上下文**，并直接跳转到报错源码行。

**非目标（本期不做）**：
- 不全量替换存量消息点（按热点渐进）
- 不做跨系统日志集中聚合（仅预留 ID 贯穿能力）
- 不改前端展示逻辑（通过文本拼 ID 过渡）

## 2. 参考项目与借鉴点

| 项目 | 借鉴什么 |
|---|---|
| [SchwarzIT/sap-usi-logging-api](https://github.com/SchwarzIT/sap-usi-logging-api) | 数据容器机制（调用栈/源码位置/任意数据挂到消息上）；调用者位置采集；按日志对象配置保留期（RETENTION_TIME + NO_EARLY_DELETE）；按用户/客户端临时调高日志级别且带失效日期；自建数据挂接标准删除流程清理 |
| [ABAP-Logger/ABAP-Logger](https://github.com/ABAP-Logger/ABAP-Logger) | 流式 API 的易用性设计（`logger->e( 'text' )`）；其 [Issue #4](https://github.com/ABAP-Logger/ABAP-Logger/issues/4)（ROLLBACK 丢日志）作为反面教训 |
| [greltel/abap-cloud-logger](https://github.com/greltel/abap-cloud-logger) | "应急日志"双镜像（写入同时镜像到第二个日志，防 dump/回滚丢失）；`expiry_date` 过期属性 |
| [fabianlupa/abap-log](https://github.com/fabianlupa/abap-log) | 日志器接口与多后端解耦（BAL/内表/DB 表），便于单测 |
| 文件日志世界（log4j/logging 等） | 结构化 JSON 上下文；correlation ID 贯穿传递（MDC/trace ID 思想） |
| SAP 标准 | BAL（SLG0/SLG1/SLG2）、`BAL_LOG_MSG_ADD_FREE_TEXT`、`CX_ROOT->GET_SOURCE_POSITION( )`、`RS_TOOL_ACCESS`（跳转源码行） |

## 3. 总体架构

```
业务代码 ──调用──> ZCL_LOG（核心日志类）
                     │  begin( ) 即返回自生成 UUID（写 EXTNUMBER）
                     │  msg( ) / text( ) / exception( ) 追加条目
                     │  save( )：随 LUW / 立即 / 独立 LUW(RFC 'NONE')
                     ▼
              BAL 应用日志（SLG0 对象，按保留期分子对象）
                     │
        ┌────────────┴────────────┐
     SLG1（标准，按外部编号=ID 查）   查询报表 ZLOG_QUERY
                                   （BAL_DB_SEARCH/LOAD + 双击跳源码）
```

**关键设计决策**：
1. **ID 与保存解耦**：ID 为自生成 UUID（C22），开日志时即返回；不依赖 BAL 保存后才分配的 LOGNUMBER。
2. **消息契约不变**：现有 `msgty`/`msgtx` 结构保持不动，追加 `log_id` 字段（向后兼容）；过渡期在出口把 ID 拼进 msgtx 文本（前端零改造）。
3. **存储选 BAL**：中低量、单点查询型负载（详见评估结论）；上下文先用消息参数，大快照需求出现时再引入侧表。
4. **位置采集按栈帧过滤**：不用固定栈深度（SchwarzIT `caller_level = 4` 的脆弱点），跳过日志类自身帧取第一个业务帧。

## 4. 功能点清单

优先级：P0 = MVP 必须；P1 = 二期；P2 = 按需增强。

### 模块 A：核心日志类（写入侧）

| # | 功能点 | 优先级 | 借鉴来源 | 说明 |
|---|---|---|---|---|
| A1 | 日志会话管理：`begin( )` 返回日志 ID | P0 | 本方案设计 | UUID→EXTNUMBER；一次交互一个日志一个 ID，多条目共享 |
| A2 | T100 消息条目 `msg( )` | P0 | ABAP-Logger | msgid/msgno/msgv1-4 |
| A3 | 自由文本条目 `text( )` | P0 | ABAP-Logger / `BAL_LOG_MSG_ADD_FREE_TEXT` | 任意文本 + 严重级别，支持"留痕"场景 |
| A4 | 异常条目 `exception( )`：自动取 raise 位置 | P1 | SchwarzIT `add_cx_src_pos_container` | `cx_root->get_source_position( )` 取程序/Include/行号 |
| A5 | 调用者位置自动采集 | P0 | SchwarzIT `add_caller_src_pos_container`（改进） | `SYSTEM_CALLSTACK` 按帧过滤（跳过日志类自身 include），不固定层数 |
| A6 | 完整调用栈记录（可开关） | P2 | SchwarzIT `dc_callstack` | 截掉日志类自身帧后整栈记录 |
| A7 | 上下文参数：名值对 | P0 | SchwarzIT message params | 业务键（单号/请求号等），SLG1 详情可见 |
| A8 | JSON 结构化上下文容器 | P2 | SchwarzIT `dc_json` + 文件日志世界 | 大快照、机器可读；若引入需配侧表（见 D6） |
| A9 | 保存策略三档：随 LUW / 立即保存 / 独立 LUW | P0 基础档，P1 完整 | ABAP-Logger Issue #4（反面）+ greltel 应急日志 | 独立 LUW 用 `CALL FUNCTION ... DESTINATION 'NONE'`，保证 ROLLBACK 不丢错误日志 |
| A10 | 返回 `bapiret2`（log_no = ID） | P0 | 本方案设计 | 与现有 msgty/msgtx 出口衔接 |

### 模块 B：出口兜底与消息集成（存量系统接入）

| # | 功能点 | 优先级 | 借鉴来源 | 说明 |
|---|---|---|---|---|
| B1 | 出口捕获点：在 OData 错误返回 / 表单 / ALV / 接口封装等出口统一调日志类 | P0 | 分层改造策略 | 全系统预计仅 2~5 处；记录时间/用户/上下文/ID，位置为出口栈 |
| B2 | msgtx 尾部拼 `(log ID)` | P0 | 本方案设计 | 前端零改造，用户立即可见 ID |
| B3 | 返回结构追加 `log_id` 字段 | P1 | 本方案设计 | 向后兼容，前端有排期后改为独立展示 |
| B4 | RAP / BAPIRETTAB 适配 | P2 | 视系统情况 | 如有 RAP 场景 |

### 模块 C：查询侧

| # | 功能点 | 优先级 | 借鉴来源 | 说明 |
|---|---|---|---|---|
| C1 | SLG1 使用规程 | P0 | SAP 标准 | 按对象 + 外部编号（ID）检索；零开发，写进运维手册 |
| C2 | 查询报表 ZLOG_QUERY：粘贴 ID → 展示日志详情 | P1 | SchwarzIT UI 层做法 | `BAL_DB_SEARCH` + `BAL_DB_LOAD` |
| C3 | 详情中双击调用栈/位置 → 跳转 ABAP 编辑器对应行 | P1 | SchwarzIT `dc_callstack~on_double_click` | `RS_TOOL_ACCESS( include, position )` |
| C4 | 按用户/日期/对象浏览 | P2 | — | 支持巡检与统计入门 |

### 模块 D：日志管理（清理与治理）

| # | 功能点 | 优先级 | 借鉴来源 | 说明 |
|---|---|---|---|---|
| D1 | SLG0 对象设计：子对象按保留期分层 | P0 | SchwarzIT RETENTION_TIME 思想的简化实现 | 如 `ZMSG/ERR`（90 天）、`ZMSG/AUDIT`（365 天）、`ZMSG/TRACE`（14 天） |
| D2 | SLG2 定期清理作业 | P0 | SAP 标准 | 按对象分作业、日期按月分批、避开写入高峰 |
| D3 | 量控：只记 E/A；循环内首条 + 计数 | P1 | 通用日志实践 | 防刷量 |
| D4 | 临时日志级别：按用户/客户端，带失效日期自动回落 | P2 | SchwarzIT `bal_lv_user/clnt` + ENDDA + 过期清理报表 | 排查疑难时临时开 verbose |
| D5 | 审计保留：重要日志不提前删 | P2 | SchwarzIT NO_EARLY_DELETE | 本期以子对象分层实现，必要时自建标志 |
| D6 | （条件触发）侧表清理挂接 | P2 | SchwarzIT ENHO 挂标准删除 + 孤儿数据报表 | 仅当引入 A8 侧表时必须做，否则留孤儿数据 |

### 模块 E：存量改造

| # | 功能点 | 优先级 | 借鉴来源 | 说明 |
|---|---|---|---|---|
| E1 | 基线扫描：`RS_ABAP_SOURCE_SCAN` 扫 msgtx 赋值 / `MESSAGE ... INTO` | P0 | 分层改造策略 | 建立报错点清单，量化改造量 |
| E2 | 热点替换：按出口日志统计的报障频率，替换 Top N 报错点为调日志类 | P1 起步，持续 | 帕累托策略 | 出口兜底跑一个月后数据自己排出优先级 |
| E3 | 新代码规约 + ATC 检查：禁止裸消息（不经过日志类） | P1 | 通用 CI 实践 | 存量"谁碰谁迁" |

## 5. 阶段划分与里程碑

| 阶段 | 周期 | 内容 | 出口标准 |
|---|---|---|---|
| **阶段 0：准备** | 第 1 周 | SLG0 对象/子对象定义（D1）；基线扫描出报告（E1）；设计冻结 | 报错点清单 + 对象命名评审通过 |
| **阶段 1：MVP 上线** | 第 2~3 周 | A1/A2/A3/A5/A7/A9 基础档/A10 + B1/B2 + C1 + D2 | 用户报障给出 ID → SLG1 查到时间/用户/上下文；出口闭环全通 |
| **阶段 2：查询与热点** | 第 4~6 周 | C2/C3 查询报表与跳源码 + A9 完整档 + A4 + B3 + E2 首批热点 + D3 + E3 | 凭 ID 在查询报表双击直达报错源码行 |
| **阶段 3：增强（按需）** | 排期后 | A6/A8/D4/D5/D6/B4/C4 | 按实际需求逐项验收 |

人力估算（单人）：阶段 0 约 2 人天；阶段 1 约 6~8 人天；阶段 2 约 8~10 人天。E2 为持续性工作，不计入里程碑。

## 6. 风险与已知坑（附对策）

| 风险/坑 | 来源 | 对策 |
|---|---|---|
| ROLLBACK 导致日志丢失 | ABAP-Logger Issue #4 | A9 保存策略；错误日志默认立即/独立 LUW 保存 |
| 固定栈深度取调用者，包装层变化后错位 | SchwarzIT `caller_level = 4` | 按栈帧 include 过滤，不写死层数 |
| 标准删除不清自建侧表数据 → 孤儿 | SchwarzIT 教训 | 引入侧表（A8/D6）时必须同步挂接删除，本期不引入侧表 |
| SLG2 大日期范围删除超时 | 通用实践 | 按月分批、后台作业、避开高峰、测试系统演练 |
| 消息参数/自由文本长度限制（约 50/受限字符） | BAL 限制 | 业务键走参数；大内容走 A8 容器（后期） |
| 日志量失控 | 通用风险 | D3 量控 + D1/D2 保留期分层从第一天就位 |
| 敏感数据落入日志 | 合规 | 规约：上下文只记业务键，不记敏感明文 |
| 隐式 COMMIT 破坏调用方事务 | BAL 行为 | 立即保存档位仅用于校验/错误路径；更新过程内禁用 |

## 7. 端到端验收场景

1. 用户在前台触发报错，消息文本尾部出现 `(log XXXX...)`，截图报障。
2. 支持人员打开 SLG1（或二期查询报表），输入对象 + ID，3 分钟内看到：时间、用户、系统/客户端、业务上下文、（热点替换后）报错程序与行号。
3. 二期起：查询报表中双击调用栈帧，ABAP 编辑器打开并定位到报错行。
4. 运行 90 天后 SLG2 作业自动清理过期日志，无手工干预。

## 8. 后续演进方向（不在本期）

- ID 跨系统传递（RFC 参数/接口返回字段），形成跨系统调用链（参照分布式 trace ID）
- 上下文 JSON 化后接入集中式日志/监控（BTP 日志服务或自建）
- 消息级 SQL 统计分析需求出现时，评估迁移自建透明表（ID 体系不变）
