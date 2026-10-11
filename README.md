# ZLOG — 前台报错可追溯性改造（阶段 1 MVP）

每条用户可见的消息携带日志 ID；凭 ID 在 SLG1 查到**时间、用户、系统、报错位置（程序/Include/行号）、业务上下文**。

对应开发计划：`abap-message-trace-dev-plan.md` 的阶段 1（模块 A 核心类 + B 出口兜底 + C1 查询规程 + D1/D2 清理），参考项目 [SchwarzIT/sap-usi-logging-api](https://github.com/SchwarzIT/sap-usi-logging-api)、[ABAP-Logger](https://github.com/ABAP-Logger/ABAP-Logger)、[greltel/abap-cloud-logger](https://github.com/greltel/abap-cloud-logger)。

## 对象清单

| 对象 | 类型 | 说明 |
|---|---|---|
| ZCL_LOG | 类 | 核心日志类（含 ABAP Unit） |
| Z_LOG_SAVE_RFC / FUGR ZLOG_DB | RFC 函数 | 独立 LUW 持久化（DESTINATION 'NONE'） |
| ZLOG_DEMO | 程序 | 演示 + 验收脚本 |
| ZLOG_QUERY | 程序 | 查询报表：ID/日期/用户检索 + 双击追溯行跳源码（阶段2 C2/C3） |
| ZLOG_SCAN | 程序 | 基线扫描：按包找未走 ZCL_LOG 的裸消息点，输出热点清单（E1） |
| SLG0 对象 ZLOG（子对象 ERROR/AUDIT/TRACE） | 定制 | **手工配置**，见下 |
| 消息类 ZLOG 001 = `&1&2&3&4` | SE91 | **手工配置**，自由文本载体 |

## 安装

**前置定制（两步，各 1 分钟）**：

1. **SE91**：建消息类 `ZLOG`，编号 `001`，短文本/长文本均为 `&1&2&3&4`（四个变量无缝拼接，用于自由文本入库）。
2. **SLG0**：建对象 `ZLOG`（描述随意，如 "消息追溯日志"），子对象 `ERROR`、`AUDIT`、`TRACE`。

**代码**：abapGit 导入本仓库（或 zip 离线导入）。若 FUGR 导入异常，退回手工方式：SE80/ADT 建函数组 `ZLOG_DB`，在组内按 `src/zlog_db.fugr.zlog_save_rfc.abap` 文件头的接口注释建 RFC 函数 `Z_LOG_SAVE_RFC`（参数全部为标准 DDIC 类型），再粘贴源码；类与程序直接粘贴即可。

**验证**：运行 `ZLOG_DEMO`，屏幕输出两个 Log ID；运行 `ZLOG_QUERY` 粘入任一 ID，应看到消息行 + `at INCL line N` 追溯行；双击追溯行直接跳到报错源码行。SLG1（对象 ZLOG + 外部编号 = ID）同样可查。

## API（ZCL_LOG，全部静态方法）

```abap
" 出口兜底一步式（最常用）：
DATA(ls_ret2) = zcl_log=>log_now(
    iv_text = lv_msgtx                  " 现有 msgtx 文本
    it_ctx  = VALUE #( ( name = 'VBELN' value = lv_vbeln ) ) ).
lv_msgtx = ls_ret2-message.             " 文本尾部已带 " (log XXXX)"

" 会话式（多条件、多步骤共享一个 ID）：
DATA(lv_id) = zcl_log=>begin( iv_subobject = zcl_log=>c_subobject_aud ).
zcl_log=>msg(  iv_msgid = 'ZSD' iv_msgno = '017' iv_msgv1 = lv_matnr ).  " T100 消息
zcl_log=>text( |重试第 { n } 次失败| ).                                    " 自由文本
zcl_log=>exception( lx ).                " 类异常：文本 + RAISE 点行号
zcl_log=>capture( ).                     " 兜底捕获当前 sy-msg*
zcl_log=>save( ).
```

**设计要点**：

- **ID 即返回**：`begin( )` 生成 20 位 ID（C22 UUID 截前 20——BAPIRET2-LOG_NO 只有 char20，22 位会被静默截断）写入 BAL 外部编号，未保存也可返回给前台；与 BAL 的 LOGNUMBER 解耦。
- **默认独立 LUW**（`c_save_indep`）：保存走 `Z_LOG_SAVE_RFC` RFC 'NONE'，调用方随后 ROLLBACK 也丢不了错误日志。`c_save_luw`（随 LUW）仅供 TRACE 类低价值日志。
- **位置采集**：`msg/text` 记录调用者帧（`SYSTEM_CALLSTACK` 按 include 过滤 `ZCL_LOG` 帧，非固定深度）；`exception` 用 `cx_root->get_source_position` 记录 RAISE 点。位置与业务键以**追溯行**入库：每条消息后追加一条 I 级消息 `at INCL line N; K=V; K=V`（816 上 BAL 消息参数要求 ALTEXT/CALLBACK，裸参数报 BL205，故弃用）。
- **量控（D3）**：同文本同位置的连续重复自动合并，追溯行标注总次数（`at INCL line N x5`）；单日志上限 `c_max_entries`（默认 200），超出只计数并在保存时补一条 W 级提示。循环里刷消息不再撑爆日志。
- `capture( )` 记录的是捕获点位置，不是原始 raise 点——尽量在错误传播必经之路调用。
- 上下文名值对：name ≤ 20、value ≤ 50（BAL 消息参数宽度）。**不要记录敏感明文**。

## 出口接法（存量系统 B1/B2）

在 msgty/msgtx 汇合的出口（OData 错误返回 / 表单 / ALV / 接口封装，通常全系统 2~5 处）：

```abap
IF ls_return-msgty CA 'EA'.
  DATA(ls_ret2) = zcl_log=>log_now(
      iv_text = ls_return-msgtx
      it_ctx  = VALUE #( ( name = 'GUID' value = lv_request_guid ) ) ).
  ls_return-msgtx = ls_ret2-message.     " 用户看到 "原文本 (log 4C3F...)"
ENDIF.
```

前端零改造。后续排期再给返回结构追加 `log_id` 字段（log_no 已有）并独立展示。

## 日常使用（支持人员动线）

1. 用户报障提供 ID（或截图里的 `(log XXXX)`）。
2. 首选：运行 `ZLOG_QUERY`（SA38/SE38），ID 粘进 P_ID（支持部分粘贴模糊匹配），日期/用户可缩小范围；结果按时间倒序，双击 `at INCL line N` 追溯行直接跳到报错源码行。
3. 备选：SLG1，对象 `ZLOG`，外部编号 = ID（完整粘贴，或前缀 + `*`）；消息行下方的 I 级追溯行即位置与业务上下文。

## 日志清理（D1/D2）

| 子对象 | 用途 | 建议保留期 |
|---|---|---|
| ERROR | 前台报错 | 90 天 |
| AUDIT | 留痕 | 365 天 |
| TRACE | 临时排查 | 14 天 |

SLG2 按对象+子对象+日期范围建后台作业（每月跑一次，删 N-保留期 之前的），日期范围分批、避开业务高峰。**改造上线第一天就建作业**。

## 基线扫描（存量改造 E1）

运行 `ZLOG_SCAN`（SA38）：包 = 目标自研包，默认模式 `MESSAGE` / `msgtx`（可改），扫 PROG/函数 include/类方法 include，跳过含 `ZCL_LOG` 的行，输出"裸消息点"候选清单（含误报需人工确认，上限默认 500 条）。出口兜底运行一个月后，按 SLG1/ZLOG_QUERY 中出现频率排出热点，逐批替换为 `zcl_log=>msg( )`；新代码规约：禁止不经 ZCL_LOG 的裸消息（后续加 ATC 检查）。

## 已知限制（MVP 范围内接受）

- **目标发布基线为 ABAP Platform 816（S/4 2025）**：该版本 `BAL_LOG_CREATE` 头参数名为 `I_S_LOG`（旧版本为 `I_S_LOG_HEADER`）、`SYSTEM_CALLSTACK` 输出参数用 `CALLSTACK`（勿用新表 `ET_CALLSTACK`，行类型不同）。**移植到 7.5x 及更早系统时需改回 `I_S_LOG_HEADER`**（两个文件各一处）。

- 自由文本正文 ≤ 200 字符入库（4×50 拆分进 ZLOG 001）；更长内容待 A8 JSON 容器（侧表）。
- `save_indep` 每次 save 起一个 RFC 'NONE' 内部会话，高吞吐场景注意量控（只记 E/A）。
- `save_luw` 模式下 BAL_DB_SAVE 可能隐式提交数据库，勿在更新流程（V1/V2）中使用该模式。
- BAL 消息体在簇表：不支持按消息文本 SQL 检索；入口永远是 ID → 表头。
- 日志组件自身失败静默（不打断业务）；错误轨迹是后续项（参考 abap-cloud-logger error trail）。
- 重命名 ZCL_LOG 需同步修改 `caller_position` 的栈帧过滤串。

## 路线图（对应开发计划阶段 2/3）

- C2/C3：查询报表（BAL_DB_SEARCH/LOAD，双击调用栈帧 `RS_TOOL_ACCESS` 跳源码行）
- A8：JSON 上下文侧表（需同步挂接标准删除，见 SchwarzIT 教训）
- D4：按用户临时日志级别（带失效日期）
- E3：ATC 检查禁止裸消息
