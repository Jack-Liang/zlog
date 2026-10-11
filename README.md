# ZMSGTRACE — 前台报错可追溯性改造

每条用户可见的消息携带日志 ID；凭 ID 查到**时间、用户、系统、报错位置（程序/Include/行号 + 语句摘录）、调用链、业务上下文、数据快照**。

对应开发计划：`abap-message-trace-dev-plan.md` 的阶段 1~3（模块 A 核心类 + B 出口三形态 + C 查询 + D 清理治理 + E 基线扫描）已全部交付，剩余为按需增强（见文末路线图）。参考项目 [SchwarzIT/sap-usi-logging-api](https://github.com/SchwarzIT/sap-usi-logging-api)、[ABAP-Logger/ABAP-Logger](https://github.com/ABAP-Logger/ABAP-Logger)、[greltel/abap-cloud-logger](https://github.com/greltel/abap-cloud-logger)。

## 对象清单

| 对象 | 类型 | 说明 |
|---|---|---|
| ZCL_MSGTRACE | 类 | 核心日志类（含 ABAP Unit，黑盒化） |
| ZMSGTRACE_SAVE_RFC / 函数组 ZMSGTRACE_DB | RFC 函数 | 独立 LUW 持久化（DESTINATION 'NONE'） |
| ZMSGTRACE_CTX | 透明表 | JSON 快照侧表（A8） |
| ZMSGTRACE_DEMO | 程序 | 演示 + 验收脚本 |
| ZMSGTRACE_QUERY | 程序 | 查询报表：ID/日期/用户/时间检索 + 双击跳源码（含行号漂移自动愈合）+ 快照弹窗 |
| ZMSGTRACE_SCAN | 程序 | 基线扫描：按包找裸消息点，支持"只扫某日后改动的对象"（E1/E3） |
| ZMSGTRACE_CLEANUP | 程序 | 快照侧表清理（随 SLG2 作业排班） |
| SLG0 对象 ZMSGTRACE（子对象 ERROR/AUDIT/TRACE） | 定制 | **手工配置**，见下 |
| 消息类 ZMSGTRACE 001 = `&1&2&3&4` | SE91 | **手工配置**，自由文本载体 |

## 安装

**前置定制（两步，各 1 分钟）**：

1. **SE91**：建消息类 `ZMSGTRACE`，编号 `001`，短文本/长文本均为 `&1&2&3&4`（四个变量无缝拼接，用于自由文本入库）。
2. **SLG0**：建对象 `ZMSGTRACE`（描述随意，如 "消息追溯日志"），子对象 `ERROR`、`AUDIT`、`TRACE`。

**代码**：abapGit 导入本仓库（或 zip 离线导入）。若 FUGR 导入异常，退回手工方式：SE80/ADT 建函数组 `ZMSGTRACE_DB`，在组内按 `src/zmsgtrace_db.fugr.zmsgtrace_save_rfc.abap` 文件头的接口注释建 RFC 函数 `ZMSGTRACE_SAVE_RFC`（参数全部为标准 DDIC 类型），再粘贴源码；类与程序直接粘贴即可。

**验证**：运行 `ZMSGTRACE_DEMO`，屏幕输出 Log ID；运行 `ZMSGTRACE_QUERY` 粘入任一 ID，应看到消息行 + `at INCL line N/M: <语句摘录>` 追溯行；双击追溯行直接跳到报错源码行（代码改过会自动定位到当前行，状态栏有提示）。SLG1（对象 ZMSGTRACE + 外部编号 = ID）同样可查。

## API（ZCL_MSGTRACE，全部静态方法）

```abap
" 出口兜底一步式（最常用）：
DATA(ls_ret2) = zcl_msgtrace=>log_now(
    iv_text = lv_msgtx                  " 现有 msgtx 文本
    it_ctx  = VALUE #( ( name = 'VBELN' value = lv_vbeln ) ) ).
lv_msgtx = ls_ret2-message.             " 文本尾部已带 " (log XXXX)"

" 一行式 / 双字段形态见下节"出口接法"

" 会话式（多条件、多步骤共享一个 ID）：
DATA(lv_id) = zcl_msgtrace=>begin( iv_subobject = zcl_msgtrace=>c_subobject_aud
                              iv_stack     = abap_true ).   " 可选：记录调用链
zcl_msgtrace=>msg(  iv_msgid = 'ZSD' iv_msgno = '017' iv_msgv1 = lv_matnr ).  " T100 消息
zcl_msgtrace=>text( |重试第 { n } 次失败| ).                                    " 自由文本
zcl_msgtrace=>exception( lx ).                " 类异常：文本 + RAISE 点行号
zcl_msgtrace=>capture( ).                     " 兜底捕获当前 sy-msg*
zcl_msgtrace=>snap( iv_name = 'ORDER'         " 数据快照（A8）：任意结构/内表 → JSON 侧表
                    ig_data  = ls_order ).
zcl_msgtrace=>save( ).

" 内省（测试/监控）：get_id( ) 当前会话 ID · get_last_id( ) 最近保存 ID
"                     get_stats( ) 缓冲状态（条目数/重复/溢出/快照数/最后调用链）
```

**设计要点**：

- **ID 即返回**：`begin( )` 生成 20 位 ID（C22 UUID 截前 20——BAPIRET2-LOG_NO 只有 char20，22 位会被静默截断）写入 BAL 外部编号，未保存也可返回给前台；与 BAL 的 LOGNUMBER 解耦。
- **默认独立 LUW**（`c_save_indep`）：保存走 `ZMSGTRACE_SAVE_RFC` RFC 'NONE'，调用方随后 ROLLBACK 也丢不了错误日志。`c_save_luw`（随 LUW）仅供 TRACE 类低价值日志。
- **位置采集**：`msg/text` 记录调用者帧（`SYSTEM_CALLSTACK` 按 include 过滤 `ZCL_MSGTRACE` 帧，非固定深度）；`exception` 用 `cx_root->get_source_position` 记录 RAISE 点。位置与业务键以**追溯行**入库：每条消息后追加一条 I 级消息 `at INCL line N/M: <语句摘录>; K=V; K=V`（816 上 BAL 消息参数要求 ALTEXT/CALLBACK，裸参数报 BL205，故弃用）。
- **行号漂移对策**：行号只在记录时的代码版本下精确，include 改动后旧日志的行号会漂。追溯行同时记两个"锚"：`line N/M`（M = 记录时 include 总行数，M 对不上即知已漂）+ 语句摘录（记录时该行源码 condense 后前 40 字符，`at INCL line N/M: lv_qty > lv_max; K=V`）——行号会漂，语句文本不漂。include 被删/行号越界时自动降级为纯行号。
- **量控（D3）**：同文本同位置的连续重复自动合并，追溯行标注总次数（`at INCL line N x5`）；单日志上限 `c_max_entries`（默认 200），超出只计数并在保存时补一条 W 级提示。循环里刷消息不再撑爆日志。
- **调用链（A6，可开关）**：`begin( iv_stack = abap_true )` 后每条目额外落一条 `stack: INCL(行) <- INCL(行)...`（直接调用方之后的 4 帧），排查深层嵌套路径用；默认关闭省日志量。
- **数据快照（A8）**：`snap( iv_name, ig_data )` 把任意结构/内表序列化成 JSON 存侧表 `ZMSGTRACE_CTX`（与条目同会话保存），还原"当时的数据长什么样"；ZMSGTRACE_QUERY 里双击快照行弹完整 JSON。
- **保留期（D5）**：落库时按子对象写 BAL 头原生字段 `ALDATE_DEL`（ERR 90 / AUDIT 365 / TRACE 14 天，常量 `c_retention_*`），SLG2 清理作业自动尊重——保留策略跟着数据走。
- `capture( )` 记录的是捕获点位置，不是原始 raise 点——尽量在错误传播必经之路调用。
- 上下文名值对：name ≤ 20、value ≤ 50（BAL 消息参数宽度）。**不要记录敏感明文**。

## 出口接法（存量系统 B1/B2）

存量迁移的一行式写法（`text_now` 直接返回文本，尾部带 log ID）：

```abap
" 原来：ls_return-msgtx = |物料 { lv_matnr } 不存在|.
ls_return-msgty = 'E'.                                              " 照常
ls_return-msgtx = zcl_msgtrace=>text_now( |物料 { lv_matnr } 不存在| ).  " 就地替换
```

需要类型/LOG_NO 字段时用 `log_now`（返回 bapiret2）。

双字段形态（B3：msgtx 干净文本 + logid 分离，返回结构追加 `logid TYPE zcl_msgtrace=>tv_log_id` 即 char20，向后兼容）：

```abap
zcl_msgtrace=>log_parts(
    EXPORTING iv_text  = |物料 { lv_matnr } 不存在|
               it_ctx   = VALUE #( ( name = 'MATNR' value = lv_matnr ) )
    IMPORTING ev_text   = ls_return-msgtx    " 干净文本，不带 ID 后缀
              ev_log_id = ls_return-logid ). " 20 位 ID，独立字段
```

在 msgty/msgtx 汇合的出口（OData 错误返回 / 表单 / ALV / 接口封装，通常全系统 2~5 处）：

```abap
IF ls_return-msgty CA 'EA'.
  DATA(ls_ret2) = zcl_msgtrace=>log_now(
      iv_text = ls_return-msgtx
      it_ctx  = VALUE #( ( name = 'GUID' value = lv_request_guid ) ) ).
  ls_return-msgtx = ls_ret2-message.     " 用户看到 "原文本 (log 4C3F...)"
ENDIF.
```

前端零改造；三形态按需选（一行式 `text_now` / 双字段 `log_parts` / 完整 bapiret2 `log_now`）。

## 日常使用（支持人员动线）

1. 用户报障提供 ID（或截图里的 `(log XXXX)`）。
2. 首选：运行 `ZMSGTRACE_QUERY`（SA38/SE38），ID 粘进 P_ID（支持部分粘贴模糊匹配，区分大小写），日期/用户/时间可缩小范围；结果按时间倒序，双击 `at INCL line N/M: <语句摘录>` 追溯行直接跳到报错源码行——**代码改过、行号漂了也会按语句摘录自动定位到当前行**（状态栏提示）。双击快照行弹完整 JSON。
3. 备选：SLG1，对象 `ZMSGTRACE`，外部编号 = ID（完整粘贴，或前缀 + `*`）；消息行下方的 I 级追溯行即位置与业务上下文。

## 日志清理（D1/D2/D5）

保留期已由数据自带：落库时按子对象写入 BAL 头 `ALDATE_DEL`（ERR 90 天 / AUDIT 365 天 / TRACE 14 天），**SLG2 删除作业自动尊重该日期**，到期的日志才可被删。

因此作业很简单：SLG2 按对象 `ZMSGTRACE` + 日期范围建后台作业（每月跑一次），不必按子对象拆分，也不必精确计算保留期——数据自己带着"免删期"。日期范围分批、避开业务高峰。**改造上线第一天就建作业**。

SLG2 只清 BAL：快照侧表 `ZMSGTRACE_CTX` 由 `ZMSGTRACE_CLEANUP` 负责（默认 400 天 = 最长保留期 365 + 缓冲），随 SLG2 作业同班次排一条即可；父日志已删的孤儿快照行同样到期消失。

## 基线扫描（存量改造 E1）

运行 `ZMSGTRACE_SCAN`（SA38）：包 = 目标自研包，默认模式 `MESSAGE` / `msgtx`（可改），扫 PROG/函数 include/类方法 include，跳过含 `ZCL_MSGTRACE` 的行，输出"裸消息点"候选清单（含误报需人工确认，上限默认 500 条）。

`P_SINC` 填日期时**只扫该日期之后改动的对象**（按主程序 PROGDIR-UDAT 过滤）——评审或运输前检查"新碰过的代码是否还有裸消息"用一个日期搞定；留空 = 全量基线。出口兜底运行一个月后，按 SLG1/ZMSGTRACE_QUERY 中出现频率排出热点，逐批替换为 `zcl_msgtrace=>msg( )`。

## 新代码规约（E3）

1. 新代码**禁止裸消息**：错误/留痕路径不写不经 ZCL_MSGTRACE 的 `MESSAGE` 和 `msgtx` 赋值（纯技术性提示、确定不外发的除外）。
2. 存量"谁碰谁迁"：改到哪块代码，顺手把该块的裸消息换成三形态之一（`text_now` / `log_parts` / `log_now`，见出口接法）。
3. 检查手段：运输/评审前跑 `ZMSGTRACE_SCAN` + `P_SINC` = 本次改动起始日；ATC/abaplint 均无现成的"禁裸消息"规则，以 SCAN 为准。

## 已知限制（MVP 范围内接受）

- **目标发布基线为 ABAP Platform 816（S/4 2025）**：该版本 `BAL_LOG_CREATE` 头参数名为 `I_S_LOG`（旧版本为 `I_S_LOG_HEADER`）、`SYSTEM_CALLSTACK` 输出参数用 `CALLSTACK`（勿用新表 `ET_CALLSTACK`，行类型不同）。**移植到 7.5x 及更早系统时需改回 `I_S_LOG_HEADER`**（两个文件各一处）。

- 自由文本正文 ≤ 200 字符入库（4×50 拆分进 ZMSGTRACE 001）；结构化/大内容走 `snap( )`（JSON 侧表）。
- 自动愈合按语句摘录**精确匹配**：语句被改写或 pretty-printer 重排跨行时会失配，回落"按旧行号跳 + 状态栏提示"，不会跳错不声张。
- `save_indep` 每次 save 起一个 RFC 'NONE' 内部会话，高吞吐场景注意量控（只记 E/A）。
- `save_luw` 模式下 BAL_DB_SAVE 可能隐式提交数据库，勿在更新流程（V1/V2）中使用该模式。
- BAL 消息体在簇表：不支持按消息文本 SQL 检索；入口永远是 ID → 表头。
- 日志组件自身失败静默（不打断业务）；错误轨迹是后续项（参考 abap-cloud-logger error trail）。
- 重命名 ZCL_MSGTRACE 需同步修改 `caller_position` 的栈帧过滤串。

## 路线图（已完成项见上文对应章节）

已完成：核心类（含量控 D3 / 调用链 A6 / JSON 快照 A8 / 保留期 D5）· 出口三形态（text_now / log_parts / log_now，B1~B3）· 查询报表 ZMSGTRACE_QUERY（C2/C3，双击跳源码 + 位置回填 + **行号漂移自动愈合**）· 行号漂移对策（追溯行记 `line N/M` + 语句摘录）· 基线扫描 ZMSGTRACE_SCAN（E1 + E3 改动日期过滤）· ABAP Unit 黑盒化（get_stats）· abaplint 全绿 · 真机 E2E 验收。

按需待做：

- D4：按用户临时日志级别（带失效日期）
- D6：BAL 删除与侧表 ZMSGTRACE_CTX 的同步挂接（当前由 cleanup 程序按日期对齐两侧）
- B4：RAP 场景消息适配
- Fiori 版查询界面（RAP/OData 暴露 ZMSGTRACE_QUERY 逻辑）
