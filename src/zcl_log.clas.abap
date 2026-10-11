CLASS zcl_log DEFINITION PUBLIC FINAL CREATE PUBLIC.

  " ---------------------------------------------------------------------
  " 前台报错可追溯性改造 · 核心日志类（开发计划模块 A）
  "
  " 设计要点：
  " 1. 日志 ID 为自生成 UUID（写入 BAL EXTNUMBER），begin( ) 即返回，
  "    与保存时机解耦 —— BAL 自己的 LOGNUMBER 要保存后才有，不作依赖
  " 2. 一次交互一个日志一个 ID，msg/text/exception 条目共享
  " 3. 默认独立 LUW 保存（RFC 'NONE'），调用方 ROLLBACK 不丢错误日志
  "    （借鉴 greltel/abap-cloud-logger 应急日志思路；ABAP-Logger Issue #4 教训）
  " 4. 调用者位置按栈帧过滤（include CS 'ZCL_LOG'），不写死栈深度
  "    （SchwarzIT caller_level = 4 的教训）
  " 5. 自由文本借消息类 ZLOG 001（&1&2&3&4）落成标准 BAL 消息，
  "    从而每条消息都能带 PROG/INCL/LINE 等参数，SLG1 详情可见
  " ---------------------------------------------------------------------

  PUBLIC SECTION.

    TYPES:
      tv_log_id    TYPE sysuuid-c22,
      tv_save_mode TYPE c LENGTH 1,
      BEGIN OF ty_ctx,
        name  TYPE c LENGTH 30,   " 建议 <= 20，BAL 消息参数名最长 20
        value TYPE c LENGTH 50,
      END OF ty_ctx,
      ty_ctx_t TYPE STANDARD TABLE OF ty_ctx WITH EMPTY KEY.

    CONSTANTS:
      c_object        TYPE balobj_d  VALUE 'ZLOG',   " SLG0 对象
      c_subobject_err TYPE balsubobj VALUE 'ERROR',  " 保留期建议 90 天
      c_subobject_aud TYPE balsubobj VALUE 'AUDIT',  " 保留期建议 365 天
      c_subobject_trc TYPE balsubobj VALUE 'TRACE',  " 保留期建议 14 天
      c_save_luw      TYPE tv_save_mode VALUE 'L',   " 随调用方 LUW（TRACE 用）
      c_save_indep    TYPE tv_save_mode VALUE 'R',   " 独立 LUW（默认，回滚不丢）
      c_msgclass_txt  TYPE sy-msgid VALUE 'ZLOG',    " SE91: ZLOG 001 = &1&2&3&4
      c_txtno_txt     TYPE sy-msgno VALUE '001'.

    " 开启日志会话：立即返回日志 ID（此刻尚未保存）
    CLASS-METHODS begin
      IMPORTING
        iv_subobject TYPE balsubobj   DEFAULT c_subobject_err
        iv_save_mode TYPE tv_save_mode DEFAULT c_save_indep
        it_ctx       TYPE ty_ctx_t    OPTIONAL
      RETURNING VALUE(rv_log_id) TYPE tv_log_id.

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

    " 保存并关闭会话。独立 LUW 模式下不受调用方后续 ROLLBACK 影响
    CLASS-METHODS save RETURNING VALUE(rv_log_id) TYPE tv_log_id.

    CLASS-METHODS get_id RETURNING VALUE(rv_log_id) TYPE tv_log_id.
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
        msgty TYPE sy-msgty,
        msgid TYPE sy-msgid,
        msgno TYPE sy-msgno,
        msgv1 TYPE symsgv,
        msgv2 TYPE symsgv,
        msgv3 TYPE symsgv,
        msgv4 TYPE symsgv,
        pos   TYPE ty_position,
        ctx   TYPE ty_ctx_t,
      END OF ty_entry,
      ty_entries TYPE STANDARD TABLE OF ty_entry WITH EMPTY KEY,
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
      END OF ty_buffer.

    CLASS-DATA gs_buffer TYPE ty_buffer.

    CLASS-METHODS:
      ensure_begin,
      add_entry
        IMPORTING is_entry     TYPE ty_entry
        RETURNING VALUE(rs_ret2) TYPE bapiret2,
      caller_position
        RETURNING VALUE(rs_pos) TYPE ty_position,
      split_text
        IMPORTING iv_text  TYPE clike
        CHANGING  cs_entry TYPE ty_entry,
      build_ret2
        IMPORTING is_entry    TYPE ty_entry
        RETURNING VALUE(rs_ret2) TYPE bapiret2,
      build_transport_tables
        EXPORTING et_msgs TYPE bapirettab
                  et_pars TYPE bapirettab,
      add_entries_to_bal
        IMPORTING iv_handle TYPE balloghndl,
      save_luw,
      save_indep.

ENDCLASS.


CLASS zcl_log IMPLEMENTATION.

  METHOD begin.
    IF gs_buffer-log_id IS NOT INITIAL.
      save( ).                       " 防漏：先落盘上一个未保存的会话
    ENDIF.
    CLEAR gs_buffer.
    TRY.
        gs_buffer-log_id = cl_system_uuid=>if_system_uuid_static~create_uuid_c22( ).
      CATCH cx_uuid_error ##NO_HANDLER.
    ENDTRY.
    IF gs_buffer-log_id IS INITIAL.
      gs_buffer-log_id = |{ sy-datum DATE = ISO }{ sy-uzeit }|.  " 兜底 17 位
    ENDIF.
    gs_buffer-subobject  = COND #( WHEN iv_subobject IS INITIAL
                                   THEN c_subobject_err ELSE iv_subobject ).
    gs_buffer-save_mode  = COND #( WHEN iv_save_mode IS INITIAL
                                   THEN c_save_indep ELSE iv_save_mode ).
    gs_buffer-created_by = sy-uname.
    gs_buffer-created_on = sy-datum.
    gs_buffer-created_at = sy-uzeit.
    gs_buffer-base_ctx   = it_ctx.
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
    rs_ret2 = add_entry( ls_entry ).
  ENDMETHOD.


  METHOD log_now.
    begin( iv_subobject = iv_subobject it_ctx = it_ctx ).
    rs_ret2 = text( iv_text = iv_text iv_msgty = iv_msgty it_ctx = it_ctx ).
    save( ).
  ENDMETHOD.


  METHOD save.
    rv_log_id = gs_buffer-log_id.
    IF gs_buffer-log_id IS INITIAL OR gs_buffer-entries IS INITIAL.
      CLEAR gs_buffer.
      RETURN.
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
    DATA(ls_entry) = is_entry.
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
    DELETE lt_stack WHERE include CS 'ZCL_LOG'.
    READ TABLE lt_stack INTO DATA(ls_frame) INDEX 1.
    IF sy-subrc = 0.
      rs_pos-mainprogram = ls_frame-mainprogram.
      rs_pos-include     = ls_frame-include.
      rs_pos-line        = ls_frame-line.
    ENDIF.
  ENDMETHOD.


  METHOD split_text.
    " 正文拆 4 x 50 进 ZLOG 001 的 &1&2&3&4，超长部分截断
    DATA lv_text TYPE string.
    lv_text = iv_text.
    cs_entry-msgv1 = lv_text.
    IF strlen( lv_text ) > 50.
      cs_entry-msgv2 = lv_text+50.
    ENDIF.
    IF strlen( lv_text ) > 100.
      cs_entry-msgv3 = lv_text+100.
    ENDIF.
    IF strlen( lv_text ) > 150.
      cs_entry-msgv4 = lv_text+150.
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
    " 复用标准结构 BAPIRET2 传输（避免自建 DDIC）：
    "   it_msgs 行：LOG_NO = 条目序号
    "   it_pars 行：PARAMETER = 所属条目序号，ID = 参数名，
    "               MESSAGE_V1 = 参数值
    LOOP AT gs_buffer-entries INTO DATA(ls_entry).
      DATA(lv_idx) = |{ sy-tabix }|.
      APPEND VALUE bapiret2( type       = ls_entry-msgty
                             id         = ls_entry-msgid
                             number     = ls_entry-msgno
                             message_v1 = ls_entry-msgv1
                             message_v2 = ls_entry-msgv2
                             message_v3 = ls_entry-msgv3
                             message_v4 = ls_entry-msgv4
                             log_no     = lv_idx ) TO et_msgs.
      APPEND VALUE bapiret2( parameter  = lv_idx
                             id         = 'PROG'
                             message_v1 = ls_entry-pos-mainprogram ) TO et_pars.
      APPEND VALUE bapiret2( parameter  = lv_idx
                             id         = 'INCL'
                             message_v1 = ls_entry-pos-include ) TO et_pars.
      APPEND VALUE bapiret2( parameter  = lv_idx
                             id         = 'LINE'
                             message_v1 = |{ ls_entry-pos-line }| ) TO et_pars.
      APPEND VALUE bapiret2( parameter  = lv_idx
                             id         = 'SYS'
                             message_v1 = |{ sy-sysid }/{ sy-mandt }| ) TO et_pars.
      APPEND VALUE bapiret2( parameter  = lv_idx
                             id         = 'USER'
                             message_v1 = sy-uname ) TO et_pars.
      LOOP AT ls_entry-ctx ASSIGNING FIELD-SYMBOL(<ls_ctx>).
        APPEND VALUE bapiret2( parameter  = lv_idx
                               id         = <ls_ctx>-name
                               message_v1 = <ls_ctx>-value ) TO et_pars.
      ENDLOOP.
    ENDLOOP.
  ENDMETHOD.


  METHOD add_entries_to_bal.
    LOOP AT gs_buffer-entries INTO DATA(ls_entry).
      DATA lt_par TYPE bal_t_par.
      lt_par = VALUE #(
        ( parname = 'PROG' parvalue = ls_entry-pos-mainprogram )
        ( parname = 'INCL' parvalue = ls_entry-pos-include )
        ( parname = 'LINE' parvalue = |{ ls_entry-pos-line }| )
        ( parname = 'SYS'  parvalue = |{ sy-sysid }/{ sy-mandt }| )
        ( parname = 'USER' parvalue = sy-uname ) ).
      LOOP AT ls_entry-ctx ASSIGNING FIELD-SYMBOL(<ls_ctx>).
        APPEND VALUE bal_s_par( parname = <ls_ctx>-name
                                parvalue = <ls_ctx>-value ) TO lt_par.
      ENDLOOP.
      CALL FUNCTION 'BAL_LOG_MSG_ADD'
        EXPORTING
          i_log_handle = iv_handle
          i_s_msg      = VALUE bal_s_msg(
              msgty  = ls_entry-msgty
              msgid  = ls_entry-msgid
              msgno  = ls_entry-msgno
              msgv1  = ls_entry-msgv1
              msgv2  = ls_entry-msgv2
              msgv3  = ls_entry-msgv3
              msgv4  = ls_entry-msgv4
              params = VALUE #( t_par = lt_par ) )
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
            altime    = gs_buffer-created_at )
      IMPORTING
        e_log_handle   = lv_handle
      EXCEPTIONS
        OTHERS         = 1.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    add_entries_to_bal( lv_handle ).
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_save_all = abap_true
      EXCEPTIONS
        OTHERS      = 1.
  ENDMETHOD.


  METHOD save_indep.
    " RFC 'NONE'：起独立内部会话/独立 LUW 保存，调用方 ROLLBACK 带不走。
    " 两张传输表打包成 XSTRING 数据簇传参（接口全标量，
    " 与 abapGit 自带远程 FM 的参数风格一致，规避 TABLES 参数）
    DATA: lt_msgs    TYPE bapirettab,
          lt_pars    TYPE bapirettab,
          lv_payload TYPE xstring.

    build_transport_tables( IMPORTING et_msgs = lt_msgs
                                      et_pars = lt_pars ).
    EXPORT msgs = lt_msgs
           pars = lt_pars
           TO DATA BUFFER lv_payload.

    CALL FUNCTION 'Z_LOG_SAVE_RFC'
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
