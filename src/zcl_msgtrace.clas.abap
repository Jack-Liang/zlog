CLASS zcl_msgtrace DEFINITION PUBLIC FINAL CREATE PUBLIC.

  " ---------------------------------------------------------------------
  " 前台报错可追溯性改造 · 核心日志类（开发计划模块 A）
  "
  " 设计要点：
  " 1. 日志 ID 为自生成 UUID（写入 BAL EXTNUMBER），begin( ) 即返回，
  "    与保存时机解耦 —— BAL 自己的 LOGNUMBER 要保存后才有，不作依赖
  " 2. 一次交互一个日志一个 ID，msg/text/exception 条目共享
  " 3. 默认独立 LUW 保存（RFC 'NONE'），调用方 ROLLBACK 不丢错误日志
  "    （借鉴 greltel/abap-cloud-logger 应急日志思路；ABAP-Logger Issue #4 教训）
  " 4. 调用者位置按栈帧过滤（include CS 'ZCL_MSGTRACE'），不写死栈深度
  "    （SchwarzIT caller_level = 4 的教训）
  " 5. 自由文本借消息类 ZMSGTRACE 001（&1&2&3&4）落成标准 BAL 消息，
  "    从而每条消息都能带 PROG/INCL/LINE 等参数，SLG1 详情可见
  " ---------------------------------------------------------------------

  PUBLIC SECTION.

    TYPES:
      " ID 定长 20：BAPIRET2-LOG_NO 仅 char20，22 位 UUID 会静默截断导致下游残缺
      tv_log_id    TYPE c LENGTH 20,
      tv_save_mode TYPE c LENGTH 1,
      BEGIN OF ty_ctx,
        name  TYPE c LENGTH 30,   " 建议 <= 20，BAL 消息参数名最长 20
        value TYPE c LENGTH 50,
      END OF ty_ctx,
      ty_ctx_t TYPE STANDARD TABLE OF ty_ctx WITH EMPTY KEY.

    CONSTANTS:
      c_object        TYPE balobj_d  VALUE 'ZMSGTRACE',   " SLG0 对象
      c_subobject_err TYPE balsubobj VALUE 'ERROR',
      c_subobject_aud TYPE balsubobj VALUE 'AUDIT',
      c_subobject_trc TYPE balsubobj VALUE 'TRACE',
      " D5 保留期（天）：写入 BAL 头 ALDATE_DEL，SLG2 清理作业自动尊重
      c_retention_err TYPE i VALUE 90,
      c_retention_aud TYPE i VALUE 365,
      c_retention_trc TYPE i VALUE 14,
      c_save_luw      TYPE tv_save_mode VALUE 'L',   " 随调用方 LUW（TRACE 用）
      c_save_indep    TYPE tv_save_mode VALUE 'R',   " 独立 LUW（默认，回滚不丢）
      c_msgclass_txt  TYPE sy-msgid VALUE 'ZMSGTRACE',    " SE91: ZMSGTRACE 001 = &1&2&3&4
      c_txtno_txt     TYPE sy-msgno VALUE '001',
      c_max_entries   TYPE i        VALUE 200.       " 单日志条目上限（量控）

    " 开启日志会话：立即返回日志 ID（此刻尚未保存）
    " iv_stack = X 时每条目额外记录调用链（A6，排查深层嵌套路径用）
    CLASS-METHODS begin
      IMPORTING
        iv_subobject TYPE balsubobj   DEFAULT c_subobject_err
        iv_save_mode TYPE tv_save_mode DEFAULT c_save_indep
        it_ctx       TYPE ty_ctx_t    OPTIONAL
        iv_stack     TYPE abap_bool   DEFAULT abap_false
      RETURNING VALUE(rv_log_id) TYPE tv_log_id.

    " 结构化快照（A8）：任意结构/内表序列化为 JSON 存侧表 ZMSGTRACE_CTX，
    " 会话级（与条目同 LUW 保存），还原"当时的数据长什么样"
    " 示例：zcl_msgtrace=>snap( iv_name = 'ORDER' ig_data = ls_order ).
    CLASS-METHODS snap
      IMPORTING
        iv_name TYPE clike
        ig_data TYPE any.

    " T100 消息条目
    CLASS-METHODS msg
      IMPORTING
        iv_msgid TYPE sy-msgid
        iv_msgno TYPE sy-msgno
        iv_msgv1 TYPE any    DEFAULT space
        iv_msgv2 TYPE any    DEFAULT space
        iv_msgv3 TYPE any    DEFAULT space
        iv_msgv4 TYPE any    DEFAULT space
        iv_msgty TYPE sy-msgty DEFAULT 'E'
        it_ctx   TYPE ty_ctx_t OPTIONAL
      RETURNING VALUE(rs_ret2) TYPE bapiret2.

    " 自由文本条目（留痕场景，正文 <= 200 字符入库）
    CLASS-METHODS text
      IMPORTING
        iv_text  TYPE clike
        iv_msgty TYPE sy-msgty DEFAULT 'E'
        it_ctx   TYPE ty_ctx_t OPTIONAL
      RETURNING VALUE(rs_ret2) TYPE bapiret2.

    " 兜底：某处已经 MESSAGE 过，就地捕获当前 sy-msg*
    " 注意：位置记录的是捕获点，不是原始 raise 点
    CLASS-METHODS capture
      IMPORTING
        it_ctx TYPE ty_ctx_t OPTIONAL
      RETURNING VALUE(rs_ret2) TYPE bapiret2.

    " 异常条目：文本 + RAISE EXCEPTION 的准确源码位置
    CLASS-METHODS exception
      IMPORTING
        ix_ex    TYPE REF TO cx_root
        iv_msgty TYPE sy-msgty DEFAULT 'E'
        it_ctx   TYPE ty_ctx_t OPTIONAL
      RETURNING VALUE(rs_ret2) TYPE bapiret2.

    " 一步式：记录 + 保存（出口兜底 B1/B2 最常用）
    " 返回的 bapiret2-message 尾部已带 " (log ID)"
    CLASS-METHODS log_now
      IMPORTING
        iv_text      TYPE clike
        iv_msgty     TYPE sy-msgty DEFAULT 'E'
        it_ctx       TYPE ty_ctx_t OPTIONAL
        iv_subobject TYPE balsubobj DEFAULT c_subobject_err
      RETURNING VALUE(rs_ret2) TYPE bapiret2.

    " 一步式纯文本版：返回值直接赋给 msgtx（尾部带 log ID）
    " 存量迁移一行替换：ls_return-msgtx = zcl_msgtrace=>text_now( |...| ).
    " 需要类型/LOG_NO 字段时用 log_now
    CLASS-METHODS text_now
      IMPORTING
        iv_text      TYPE clike
        iv_msgty     TYPE sy-msgty DEFAULT 'E'
        it_ctx       TYPE ty_ctx_t OPTIONAL
        iv_subobject TYPE balsubobj DEFAULT c_subobject_err
      RETURNING VALUE(rv_text) TYPE string.

    " 一步式双字段版（B3）：msgtx 干净文本 + logid 分离返回，一次调用直填两个字段
    "   zcl_msgtrace=>log_parts( EXPORTING iv_text = |...|
    "                       IMPORTING ev_text = ls_return-msgtx
    "                                 ev_log_id = ls_return-logid ).
    CLASS-METHODS log_parts
      IMPORTING
        iv_text      TYPE clike
        iv_msgty     TYPE sy-msgty DEFAULT 'E'
        it_ctx       TYPE ty_ctx_t OPTIONAL
        iv_subobject TYPE balsubobj DEFAULT c_subobject_err
      EXPORTING
        ev_text      TYPE string
        ev_log_id    TYPE tv_log_id.

    " 保存并关闭会话。独立 LUW 模式下不受调用方后续 ROLLBACK 影响
    CLASS-METHODS save RETURNING VALUE(rv_log_id) TYPE tv_log_id.

    CLASS-METHODS get_id RETURNING VALUE(rv_log_id) TYPE tv_log_id.

    " 会话内省（单元测试 / 监控用）：当前缓冲状态快照
    TYPES: BEGIN OF ty_stats,
             entries      TYPE i,      " 已缓冲条目数
             last_repeats TYPE i,      " 最新条目重复次数（量控）
             overflow     TYPE i,      " 超上限丢弃数
             snaps        TYPE i,      " 快照数
             last_stack   TYPE string, " 最新条目调用链（未开启为空）
             last_snap    TYPE string, " 最新快照 JSON
           END OF ty_stats.

    CLASS-METHODS get_stats RETURNING VALUE(rs_stats) TYPE ty_stats.
    " 最近一次保存的日志 ID（save 后 get_id 已清空时的取值口）
    CLASS-METHODS get_last_id RETURNING VALUE(rv_log_id) TYPE tv_log_id.
    CLASS-METHODS is_active RETURNING VALUE(rv_active) TYPE abap_bool.
    CLASS-METHODS reset.                       " 丢弃未保存内容

  PRIVATE SECTION.

    TYPES:
      BEGIN OF ty_position,
        mainprogram TYPE c LENGTH 40,
        include     TYPE c LENGTH 40,
        line        TYPE i,
      END OF ty_position,
      BEGIN OF ty_entry,
        msgty   TYPE sy-msgty,
        msgid   TYPE sy-msgid,
        msgno   TYPE sy-msgno,
        msgv1   TYPE symsgv,
        msgv2   TYPE symsgv,
        msgv3   TYPE symsgv,
        msgv4   TYPE symsgv,
        pos     TYPE ty_position,
        ctx     TYPE ty_ctx_t,
        repeats TYPE i,                  " 同文本同位置的连续重复次数
        stack   TYPE string,             " 调用链（A6 开关开启时）
      END OF ty_entry,
      ty_entries TYPE STANDARD TABLE OF ty_entry WITH EMPTY KEY,
      BEGIN OF ty_snap,                   " A8 快照（与 FM 侧类型保持一致）
        name     TYPE c LENGTH 30,
        data_str TYPE string,             " JSON
      END OF ty_snap,
      ty_snap_t TYPE STANDARD TABLE OF ty_snap WITH EMPTY KEY,
      BEGIN OF ty_buffer,
        log_id      TYPE tv_log_id,
        subobject   TYPE balsubobj,
        save_mode   TYPE tv_save_mode,
        created_by  TYPE syuname,
        created_on  TYPE sydatum,
        created_at  TYPE syuzeit,
        caller_prog TYPE c LENGTH 40,
        entries     TYPE ty_entries,
        base_ctx    TYPE ty_ctx_t,
        overflow    TYPE i,              " 超上限被丢弃的消息数
        stack_mode  TYPE abap_bool,      " 每条目附加调用链（A6）
        snaps       TYPE ty_snap_t,      " 结构化快照（A8）
      END OF ty_buffer.

    CLASS-DATA gs_buffer TYPE ty_buffer.
    CLASS-DATA gv_last_id TYPE tv_log_id.      " 最近一次保存的 ID

    CLASS-METHODS:
      ensure_begin,
      add_entry
        IMPORTING is_entry     TYPE ty_entry
        RETURNING VALUE(rs_ret2) TYPE bapiret2,
      caller_position
        RETURNING VALUE(rs_pos) TYPE ty_position,
      build_stack
        RETURNING VALUE(rv_stack) TYPE string,
      snap_serialize
        IMPORTING iv_name  TYPE clike
                  ig_data  TYPE any
        RETURNING VALUE(rv_json) TYPE string,
      write_snaps_to_db
        IMPORTING iv_log_id TYPE tv_log_id,
      retention_days
        RETURNING VALUE(rv_days) TYPE i,
      split_text
        IMPORTING iv_text  TYPE clike
        CHANGING  cs_entry TYPE ty_entry,
      split_to_vars
        IMPORTING iv_text TYPE clike
        EXPORTING ev_v1   TYPE symsgv
                  ev_v2   TYPE symsgv
                  ev_v3   TYPE symsgv
                  ev_v4   TYPE symsgv,
      build_ret2
        IMPORTING is_entry    TYPE ty_entry
        RETURNING VALUE(rs_ret2) TYPE bapiret2,
      build_transport_tables
        EXPORTING et_msgs TYPE bapirettab,
      add_entries_to_bal
        IMPORTING iv_handle TYPE balloghndl
                  it_msgs   TYPE bapirettab,
      save_luw,
      save_indep.

ENDCLASS.


CLASS zcl_msgtrace IMPLEMENTATION.

  METHOD begin.
    IF gs_buffer-log_id IS NOT INITIAL.
      save( ).                       " 防漏：先落盘上一个未保存的会话
    ENDIF.
    CLEAR gs_buffer.
    TRY.
        DATA(lv_uuid) = cl_system_uuid=>if_system_uuid_static~create_uuid_c22( ).
        gs_buffer-log_id = lv_uuid(20).
      CATCH cx_uuid_error ##NO_HANDLER.
    ENDTRY.
    IF gs_buffer-log_id IS INITIAL.
      gs_buffer-log_id = |{ sy-datum DATE = ISO }{ sy-uzeit }|.  " 兜底 16 位
    ENDIF.
    gs_buffer-subobject  = COND #( WHEN iv_subobject IS INITIAL
                                   THEN c_subobject_err ELSE iv_subobject ).
    gs_buffer-save_mode  = COND #( WHEN iv_save_mode IS INITIAL
                                   THEN c_save_indep ELSE iv_save_mode ).
    gs_buffer-created_by = sy-uname.
    gs_buffer-created_on = sy-datum.
    gs_buffer-created_at = sy-uzeit.
    gs_buffer-base_ctx   = it_ctx.
    gs_buffer-stack_mode = iv_stack.
    gs_buffer-caller_prog = caller_position( )-mainprogram.
    rv_log_id = gs_buffer-log_id.
  ENDMETHOD.


  METHOD msg.
    DATA ls_entry TYPE ty_entry.
    ensure_begin( ).
    ls_entry-msgty = iv_msgty.
    ls_entry-msgid = iv_msgid.
    ls_entry-msgno = iv_msgno.
    ls_entry-msgv1 = iv_msgv1.
    ls_entry-msgv2 = iv_msgv2.
    ls_entry-msgv3 = iv_msgv3.
    ls_entry-msgv4 = iv_msgv4.
    ls_entry-pos   = caller_position( ).
    IF gs_buffer-stack_mode = abap_true.
      ls_entry-stack = build_stack( ).
    ENDIF.
    rs_ret2 = add_entry( ls_entry ).
  ENDMETHOD.


  METHOD text.
    DATA ls_entry TYPE ty_entry.
    ensure_begin( ).
    ls_entry-msgty = iv_msgty.
    ls_entry-msgid = c_msgclass_txt.
    ls_entry-msgno = c_txtno_txt.
    split_text( EXPORTING iv_text = iv_text CHANGING cs_entry = ls_entry ).
    ls_entry-pos = caller_position( ).
    IF gs_buffer-stack_mode = abap_true.
      ls_entry-stack = build_stack( ).
    ENDIF.
    rs_ret2 = add_entry( ls_entry ).
  ENDMETHOD.


  METHOD capture.
    rs_ret2 = msg( iv_msgid = sy-msgid
                   iv_msgno = sy-msgno
                   iv_msgv1 = sy-msgv1
                   iv_msgv2 = sy-msgv2
                   iv_msgv3 = sy-msgv3
                   iv_msgv4 = sy-msgv4
                   iv_msgty = COND #( WHEN sy-msgty IS INITIAL
                                      THEN 'E' ELSE sy-msgty )
                   it_ctx   = it_ctx ).
  ENDMETHOD.


  METHOD exception.
    DATA ls_entry TYPE ty_entry.
    ensure_begin( ).
    ls_entry-msgty = iv_msgty.
    ls_entry-msgid = c_msgclass_txt.
    ls_entry-msgno = c_txtno_txt.
    split_text( EXPORTING iv_text = ix_ex->get_text( )
                CHANGING cs_entry = ls_entry ).
    TRY.
        ix_ex->get_source_position(
          IMPORTING program_name = ls_entry-pos-mainprogram
                    include_name = ls_entry-pos-include
                    source_line  = ls_entry-pos-line ).
      CATCH cx_root ##NO_HANDLER.    " 部分异常（如恢复的异常）无源码位置
    ENDTRY.
    IF gs_buffer-stack_mode = abap_true.
      ls_entry-stack = build_stack( ).
    ENDIF.
    rs_ret2 = add_entry( ls_entry ).
  ENDMETHOD.


  METHOD text_now.
    rv_text = log_now( iv_text      = iv_text
                       iv_msgty     = iv_msgty
                       it_ctx       = it_ctx
                       iv_subobject = iv_subobject )-message.
  ENDMETHOD.


  METHOD log_parts.
    DATA(ls_ret2) = log_now( iv_text      = iv_text
                             iv_msgty     = iv_msgty
                             it_ctx       = it_ctx
                             iv_subobject = iv_subobject ).
    " 从 ret2 的消息键重渲染 = 不带 " (log ID)" 后缀的干净文本
    MESSAGE ID ls_ret2-id TYPE 'I' NUMBER ls_ret2-number
            WITH ls_ret2-message_v1 ls_ret2-message_v2
                 ls_ret2-message_v3 ls_ret2-message_v4
            INTO ev_text.
    ev_log_id = ls_ret2-log_no.
  ENDMETHOD.


  METHOD snap.
    ensure_begin( ).
    APPEND VALUE ty_snap( name     = iv_name
                          data_str = snap_serialize( iv_name = iv_name
                                                     ig_data  = ig_data ) )
           TO gs_buffer-snaps.
  ENDMETHOD.


  METHOD snap_serialize.
    " 任意结构/内表 → JSON（sxml 写 JSON，任意发布可用）。
    " 键固定为 "data"；快照名存 ZMSGTRACE_CTX-NAME 列，不在 JSON 里重复
    TRY.
        DATA(lo_wr) = cl_sxml_string_writer=>create( if_sxml=>co_xt_json ).
        CALL TRANSFORMATION id
          SOURCE data = ig_data
          RESULT XML lo_wr.
        rv_json = cl_abap_codepage=>convert_from( lo_wr->get_output( ) ).
      CATCH cx_root ##NO_HANDLER.
        CLEAR rv_json.                   " 序列化失败不阻断业务
    ENDTRY.
  ENDMETHOD.


  METHOD write_snaps_to_db.
    " A8：快照写侧表（随 LUW 模式保存时由类直写；独立 LUW 模式由 FM 写）
    LOOP AT gs_buffer-snaps INTO DATA(ls_snap).
      INSERT zmsgtrace_ctx FROM @( VALUE #( log_id     = iv_log_id
                                       seq        = |{ sy-tabix }|
                                       name       = ls_snap-name
                                       data_str   = ls_snap-data_str
                                       created_by = gs_buffer-created_by
                                       created_on = gs_buffer-created_on ) ).
    ENDLOOP.
  ENDMETHOD.


  METHOD log_now.
    begin( iv_subobject = iv_subobject it_ctx = it_ctx ).
    rs_ret2 = text( iv_text = iv_text iv_msgty = iv_msgty it_ctx = it_ctx ).
    save( ).
  ENDMETHOD.


  METHOD save.
    rv_log_id = gs_buffer-log_id.
    gv_last_id = gs_buffer-log_id.
    IF gs_buffer-log_id IS INITIAL OR gs_buffer-entries IS INITIAL.
      CLEAR gs_buffer.
      RETURN.
    ENDIF.
    IF gs_buffer-overflow > 0.          " 超上限丢弃提示（量控 D3）
      APPEND VALUE ty_entry(
          msgty = 'W'
          msgid = c_msgclass_txt
          msgno = c_txtno_txt
          msgv1 = |{ gs_buffer-overflow } 条消息超出上限未记录| ) TO gs_buffer-entries.
    ENDIF.
    CASE gs_buffer-save_mode.
      WHEN c_save_luw.
        save_luw( ).
      WHEN OTHERS.
        save_indep( ).
    ENDCASE.
    CLEAR gs_buffer.
  ENDMETHOD.


  METHOD get_id.
    rv_log_id = gs_buffer-log_id.
  ENDMETHOD.


  METHOD get_last_id.
    rv_log_id = gv_last_id.
  ENDMETHOD.


  METHOD get_stats.
    rs_stats-entries      = lines( gs_buffer-entries ).
    rs_stats-overflow     = gs_buffer-overflow.
    rs_stats-snaps        = lines( gs_buffer-snaps ).
    IF gs_buffer-entries IS NOT INITIAL.
      DATA(ls_last) = gs_buffer-entries[ lines( gs_buffer-entries ) ].
      rs_stats-last_repeats = ls_last-repeats.
      rs_stats-last_stack   = ls_last-stack.
    ENDIF.
    IF gs_buffer-snaps IS NOT INITIAL.
      rs_stats-last_snap = gs_buffer-snaps[ lines( gs_buffer-snaps ) ]-data_str.
    ENDIF.
  ENDMETHOD.


  METHOD is_active.
    rv_active = xsdbool( gs_buffer-log_id IS NOT INITIAL ).
  ENDMETHOD.


  METHOD reset.
    CLEAR gs_buffer.
  ENDMETHOD.


  METHOD ensure_begin.
    IF gs_buffer-log_id IS INITIAL.
      begin( ).                       " 默认：ERROR 子对象 / 独立 LUW
    ENDIF.
  ENDMETHOD.


  METHOD add_entry.
    " 量控 D3：
    " 1) 降噪——同文本同位置的连续重复只记一条，次数累加（循环刷消息场景）
    " 2) 上限——超过 c_max_entries 不再缓冲，只计数；消息本身照常返回调用方
    IF lines( gs_buffer-entries ) > 0.
      DATA(ls_last) = gs_buffer-entries[ lines( gs_buffer-entries ) ].
      IF ls_last-msgty = is_entry-msgty
         AND ls_last-msgid = is_entry-msgid
         AND ls_last-msgno = is_entry-msgno
         AND ls_last-msgv1 = is_entry-msgv1
         AND ls_last-msgv2 = is_entry-msgv2
         AND ls_last-msgv3 = is_entry-msgv3
         AND ls_last-msgv4 = is_entry-msgv4
         AND ls_last-pos-include = is_entry-pos-include
         AND ls_last-pos-line = is_entry-pos-line.
        gs_buffer-entries[ lines( gs_buffer-entries ) ]-repeats =
            gs_buffer-entries[ lines( gs_buffer-entries ) ]-repeats + 1.
        rs_ret2 = build_ret2( is_entry ).
        RETURN.
      ENDIF.
    ENDIF.

    IF lines( gs_buffer-entries ) >= c_max_entries.
      gs_buffer-overflow = gs_buffer-overflow + 1.
      rs_ret2 = build_ret2( is_entry ).
      RETURN.
    ENDIF.

    DATA(ls_entry) = is_entry.
    ls_entry-repeats = 1.               " 语义：该条目出现的总次数
    APPEND LINES OF gs_buffer-base_ctx TO ls_entry-ctx.  " begin 上下文挂到每条
    APPEND ls_entry TO gs_buffer-entries.
    rs_ret2 = build_ret2( ls_entry ).
  ENDMETHOD.


  METHOD caller_position.
    DATA lt_stack TYPE abap_callstack.
    CALL FUNCTION 'SYSTEM_CALLSTACK'
      IMPORTING
        callstack = lt_stack.
    " 去掉日志类自身栈帧，剩余第一帧即业务调用方。
    " 不写死栈深度：类内部新增包装层不影响定位
    " （重命名本类时需同步修改过滤串）
    DELETE lt_stack WHERE include CS 'ZCL_MSGTRACE'.
    READ TABLE lt_stack INTO DATA(ls_frame) INDEX 1.
    IF sy-subrc = 0.
      rs_pos-mainprogram = ls_frame-mainprogram.
      rs_pos-include     = ls_frame-include.
      rs_pos-line        = ls_frame-line.
    ENDIF.
  ENDMETHOD.


  METHOD build_stack.
    " A6：紧凑调用链——直接调用方之后的 4 帧（直接调用方已在追溯行），
    " 形如 "PROG(12) <- PROG(34) <- PROG(56)"，截断在 200 字符预算内
    DATA lt_stack TYPE abap_callstack.
    CALL FUNCTION 'SYSTEM_CALLSTACK'
      IMPORTING
        callstack = lt_stack.
    DELETE lt_stack WHERE include CS 'ZCL_MSGTRACE'.
    LOOP AT lt_stack INTO DATA(ls_frame) FROM 2 TO 5.
      IF rv_stack IS NOT INITIAL.
        rv_stack = |{ rv_stack } <- |.
      ENDIF.
      rv_stack = |{ rv_stack }{ ls_frame-include }({ ls_frame-line })|.
    ENDLOOP.
  ENDMETHOD.


  METHOD retention_days.
    " D5：按子对象映射保留期，写入 BAL 头 ALDATE_DEL，SLG2 自动尊重
    CASE gs_buffer-subobject.
      WHEN c_subobject_aud.
        rv_days = c_retention_aud.
      WHEN c_subobject_trc.
        rv_days = c_retention_trc.
      WHEN OTHERS.
        rv_days = c_retention_err.
    ENDCASE.
  ENDMETHOD.


  METHOD split_text.
    " 正文拆 4 x 50 进 ZMSGTRACE 001 的 &1&2&3&4，超长部分截断
    DATA lv_text TYPE string.
    lv_text = iv_text.
    split_to_vars( EXPORTING iv_text = lv_text
                   IMPORTING ev_v1 = cs_entry-msgv1
                             ev_v2 = cs_entry-msgv2
                             ev_v3 = cs_entry-msgv3
                             ev_v4 = cs_entry-msgv4 ).
  ENDMETHOD.


  METHOD split_to_vars.
    " 正文拆 4 x 50 进 ZMSGTRACE 001 的 &1&2&3&4，超长部分截断
    DATA lv_text TYPE string.
    lv_text = iv_text.
    ev_v1 = lv_text.
    IF strlen( lv_text ) > 50.
      ev_v2 = lv_text+50.
    ENDIF.
    IF strlen( lv_text ) > 100.
      ev_v3 = lv_text+100.
    ENDIF.
    IF strlen( lv_text ) > 150.
      ev_v4 = lv_text+150.
    ENDIF.
  ENDMETHOD.


  METHOD build_ret2.
    " A/X 型在 INTO 场景会终止程序，映射为 E
    DATA(lv_msgty) = COND sy-msgty( WHEN is_entry-msgty CA 'AX'
                                    THEN 'E' ELSE is_entry-msgty ).
    MESSAGE ID is_entry-msgid TYPE lv_msgty NUMBER is_entry-msgno
            WITH is_entry-msgv1 is_entry-msgv2
                 is_entry-msgv3 is_entry-msgv4
            INTO DATA(lv_text).
    rs_ret2 = VALUE bapiret2(
      type       = lv_msgty
      id         = is_entry-msgid
      number     = is_entry-msgno
      message_v1 = is_entry-msgv1
      message_v2 = is_entry-msgv2
      message_v3 = is_entry-msgv3
      message_v4 = is_entry-msgv4
      log_no     = gs_buffer-log_id
      message    = |{ lv_text } (log { gs_buffer-log_id })| ).
  ENDMETHOD.


  METHOD build_transport_tables.
    " 复用标准结构 BAPIRET2 传输（避免自建 DDIC），每条目两行：
    "   本体行：TYPE/ID/NUMBER/MESSAGE_V1..4 = 消息本身
    "   追溯行：TYPE='I' ID='ZMSGTRACE'，文本 = "at INCL line N; K=V; K=V"
    " （不用 BAL 消息参数：816 要求 ALTEXT/CALLBACK，裸参数报 BL205）
    LOOP AT gs_buffer-entries INTO DATA(ls_entry).
      APPEND VALUE bapiret2( type       = ls_entry-msgty
                             id         = ls_entry-msgid
                             number     = ls_entry-msgno
                             message_v1 = ls_entry-msgv1
                             message_v2 = ls_entry-msgv2
                             message_v3 = ls_entry-msgv3
                             message_v4 = ls_entry-msgv4
                             log_no     = |{ sy-tabix }| ) TO et_msgs.

      DATA lv_trace TYPE string.
      lv_trace = |at { ls_entry-pos-include } line { ls_entry-pos-line }|.
      IF ls_entry-repeats > 1.          " 降噪计数（量控 D3）
        lv_trace = |{ lv_trace } x{ ls_entry-repeats }|.
      ENDIF.
      LOOP AT ls_entry-ctx ASSIGNING FIELD-SYMBOL(<ls_ctx>).
        lv_trace = |{ lv_trace }; { <ls_ctx>-name }={ <ls_ctx>-value }|.
      ENDLOOP.

      DATA: lv_v1 TYPE symsgv, lv_v2 TYPE symsgv,
            lv_v3 TYPE symsgv, lv_v4 TYPE symsgv.
      split_to_vars( EXPORTING iv_text = lv_trace
                     IMPORTING ev_v1 = lv_v1 ev_v2 = lv_v2
                               ev_v3 = lv_v3 ev_v4 = lv_v4 ).
      APPEND VALUE bapiret2( type       = 'I'
                             id         = c_msgclass_txt
                             number     = c_txtno_txt
                             message_v1 = lv_v1
                             message_v2 = lv_v2
                             message_v3 = lv_v3
                             message_v4 = lv_v4
                             log_no     = |{ sy-tabix }| ) TO et_msgs.

      " 调用链行（A6，仅 begin( iv_stack = X ) 时存在）
      IF ls_entry-stack IS NOT INITIAL.
        split_to_vars( EXPORTING iv_text = |stack: { ls_entry-stack }|
                       IMPORTING ev_v1 = lv_v1 ev_v2 = lv_v2
                                 ev_v3 = lv_v3 ev_v4 = lv_v4 ).
        APPEND VALUE bapiret2( type       = 'I'
                               id         = c_msgclass_txt
                               number     = c_txtno_txt
                               message_v1 = lv_v1
                               message_v2 = lv_v2
                               message_v3 = lv_v3
                               message_v4 = lv_v4
                               log_no     = |{ sy-tabix }| ) TO et_msgs.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD add_entries_to_bal.
    " 纯消息路径（无参数，见 build_transport_tables 注释）
    LOOP AT it_msgs INTO DATA(ls_m).
      CALL FUNCTION 'BAL_LOG_MSG_ADD'
        EXPORTING
          i_log_handle = iv_handle
          i_s_msg      = VALUE bal_s_msg(
              msgty = ls_m-type
              msgid = ls_m-id
              msgno = ls_m-number
              msgv1 = ls_m-message_v1
              msgv2 = ls_m-message_v2
              msgv3 = ls_m-message_v3
              msgv4 = ls_m-message_v4 )
        EXCEPTIONS
          OTHERS       = 1.
    ENDLOOP.
  ENDMETHOD.


  METHOD save_luw.
    " 随调用方 LUW：依赖调用方后续 COMMIT，ROLLBACK 会连带丢失。
    " 仅建议 TRACE 子对象使用；错误/留痕请用默认独立 LUW 模式
    DATA lv_handle TYPE balloghndl.
    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log = VALUE bal_s_log(
            object    = c_object
            subobject = gs_buffer-subobject
            extnumber = |{ gs_buffer-log_id }|
            aluser    = gs_buffer-created_by
            aldate    = gs_buffer-created_on
            altime    = gs_buffer-created_at
            aldate_del = gs_buffer-created_on + retention_days( ) ) " D5 保留期
      IMPORTING
        e_log_handle   = lv_handle
      EXCEPTIONS
        OTHERS         = 1.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    DATA lt_msgs TYPE bapirettab.
    build_transport_tables( IMPORTING et_msgs = lt_msgs ).
    add_entries_to_bal( iv_handle = lv_handle
                        it_msgs   = lt_msgs ).
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_save_all = abap_true
      EXCEPTIONS
        OTHERS      = 1.
    write_snaps_to_db( gs_buffer-log_id ).   " A8 快照随同 LUW 落库
  ENDMETHOD.


  METHOD save_indep.
    " RFC 'NONE'：起独立内部会话/独立 LUW 保存，调用方 ROLLBACK 带不走。
    " 传输表打包成 XSTRING 数据簇传参（接口全标量，
    " 与 abapGit 自带远程 FM 的参数风格一致，规避 TABLES 参数）
    DATA: lt_msgs    TYPE bapirettab,
          lv_payload TYPE xstring.

    build_transport_tables( IMPORTING et_msgs = lt_msgs ).
    EXPORT msgs  = lt_msgs
           snaps = gs_buffer-snaps          " A8 快照（FM 侧同布局类型解开）
           TO DATA BUFFER lv_payload.

    CALL FUNCTION 'ZMSGTRACE_SAVE_RFC'
      DESTINATION 'NONE'
      EXPORTING
        iv_object           = c_object
        iv_subobject        = gs_buffer-subobject
        iv_extnumber        = |{ gs_buffer-log_id }|
        iv_created_by       = gs_buffer-created_by
        iv_created_on       = gs_buffer-created_on
        iv_created_at       = gs_buffer-created_at
        iv_payload          = lv_payload
      EXCEPTIONS
        save_failed         = 1
        system_failure      = 2
        communication_failure = 3
        OTHERS              = 4.
    " 日志组件自身失败不得打断业务流程（静默）。
    " 后续演进：内部错误轨迹（参考 abap-cloud-logger 的 error trail）
  ENDMETHOD.

ENDCLASS.




