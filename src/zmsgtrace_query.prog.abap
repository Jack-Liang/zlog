REPORT zmsgtrace_query.

* ---------------------------------------------------------------------
* 消息追溯日志查询报表（开发计划 C2/C3，阶段 2）
*   粘贴日志 ID（或留空按用户/日期浏览）→ BAL 检索 → ALV 展示
*   双击含 "at INCL line N" 的追溯行 → RS_TOOL_ACCESS 跳到报错源码行
*
* 已在 ABAP Platform 816 验证的读取路径：
*   BAL_DB_SEARCH(i_s_log_filter → e_t_log_header)
*   → BAL_DB_LOAD(i_t_log_header)
*   → BAL_GLB_SEARCH_MSG(i_t_log_handle → e_t_msg_handle)
*   → BAL_LOG_MSG_READ(i_s_msg_handle → e_s_msg)
* ---------------------------------------------------------------------

PARAMETERS:
  p_id    TYPE c LENGTH 20 LOWER CASE,  " 日志 ID（可粘贴部分，模糊匹配）
                                        " LOWER CASE 必须：ID 混合大小写，屏幕会强制大写导致永远查不到
  p_sub   TYPE balsubobj,              " 子对象（空=全部）
  p_rows  TYPE i DEFAULT 100.          " 浏览模式最多取多少条日志

DATA: gv_from TYPE sydatum.

SELECT-OPTIONS:
  s_user  FOR sy-uname,
  s_date  FOR sy-datum OBLIGATORY,
  s_time  FOR sy-uzeit.               " 时间窗（缩窄加载量）

INITIALIZATION.
  " 默认完整区间：最近 30 天 + 全天 00:00~23:59
  s_date[] = VALUE #( ( sign = 'I' option = 'BT'
                        low  = sy-datum - 30
                        high = sy-datum ) ).
  s_time[] = VALUE #( ( sign = 'I' option = 'BT'
                        low = '000000' high = '235959' ) ).


CLASS lcl_events DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS constructor IMPORTING ir_table TYPE REF TO data.
    METHODS on_double_click FOR EVENT double_click OF cl_salv_events_table
      IMPORTING row column.
  PRIVATE SECTION.
    DATA mr_table TYPE REF TO data.
    METHODS jump_to_source IMPORTING iv_incl TYPE clike
                                     iv_line TYPE i
                                     iv_text TYPE clike.
ENDCLASS.

CLASS lcl_events IMPLEMENTATION.

  METHOD constructor.
    mr_table = ir_table.
  ENDMETHOD.

  METHOD on_double_click.
    FIELD-SYMBOLS: <lt_out> TYPE STANDARD TABLE.

    ASSIGN mr_table->* TO <lt_out>.
    READ TABLE <lt_out> ASSIGNING FIELD-SYMBOL(<ls_out>) INDEX row.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    ASSIGN COMPONENT 'INCL' OF STRUCTURE <ls_out> TO FIELD-SYMBOL(<lv_incl>).
    ASSIGN COMPONENT 'LINE' OF STRUCTURE <ls_out> TO FIELD-SYMBOL(<lv_line>).
    IF <lv_incl> IS NOT INITIAL AND <lv_line> IS NOT INITIAL.
      ASSIGN COMPONENT 'TEXT' OF STRUCTURE <ls_out> TO FIELD-SYMBOL(<lv_text>).
      jump_to_source( iv_incl = <lv_incl>
                      iv_line = <lv_line>
                      iv_text = <lv_text> ).
      RETURN.                          " 仅追溯行可跳转
    ENDIF.

    " A8：快照行 → 弹窗展示完整 JSON
    ASSIGN COMPONENT 'SNAP_JSON' OF STRUCTURE <ls_out> TO FIELD-SYMBOL(<lv_json>).
    IF <lv_json> IS NOT INITIAL.
      TRY.
          cl_demo_output=>display_text( <lv_json> ).
        CATCH cx_root ##NO_HANDLER.
      ENDTRY.
    ENDIF.
  ENDMETHOD.


  METHOD jump_to_source.
    " 行号漂移自动愈合：追溯行带语句摘录（"line N/M: <摘录>"）时优先按摘录
    " 定位"现在的行号"，代码改过也能跳对；无摘录（旧日志/降级）直跳旧行号
    DATA: lv_excerpt TYPE string,
          lt_src     TYPE string_table,
          lv_jump    TYPE i,
          lv_stmt    TYPE string,
          lv_hits    TYPE i,
          lv_first   TYPE i.

    lv_jump = iv_line.

    FIND REGEX 'line [0-9]+[0-9/]*: ([^;]+)' IN iv_text
         SUBMATCHES lv_excerpt ##REGEX_POSIX.
    IF sy-subrc = 0 AND lv_excerpt IS NOT INITIAL.
      CONDENSE lv_excerpt.

      READ REPORT iv_incl INTO lt_src.
      IF sy-subrc <> 0.
        MESSAGE |include 已不存在（{ iv_incl }），无法跳转| TYPE 'S' DISPLAY LIKE 'W'.
        RETURN.
      ENDIF.

      lv_stmt = ``.
      IF iv_line >= 1 AND iv_line <= lines( lt_src ).
        lv_stmt = condense( lt_src[ iv_line ] ).
      ENDIF.

      IF NOT lv_stmt CS lv_excerpt.      " 旧行号已漂移/越界 → 按摘录搜当前源码
        LOOP AT lt_src ASSIGNING FIELD-SYMBOL(<lv_src>).
          lv_stmt = condense( <lv_src> ).
          IF lv_stmt CS lv_excerpt.
            lv_hits = lv_hits + 1.
            IF lv_first = 0.
              lv_first = sy-tabix.
            ENDIF.
          ENDIF.
        ENDLOOP.
        CASE lv_hits.
          WHEN 1.
            lv_jump = lv_first.
            MESSAGE |代码已变动，自动定位到当前第 { lv_first } 行（记录时第 { iv_line } 行）| TYPE 'S'.
          WHEN 0.
            MESSAGE |代码已变动且未再找到该语句，按记录时行号 { iv_line } 跳转| TYPE 'S' DISPLAY LIKE 'W'.
          WHEN OTHERS.
            lv_jump = lv_first.
            MESSAGE |该语句现出现 { lv_hits } 次，跳到第一处（第 { lv_first } 行）| TYPE 'S'.
        ENDCASE.
      ENDIF.
    ENDIF.

    CALL FUNCTION 'RS_TOOL_ACCESS'
      EXPORTING
        operation   = 'SHOW'
        object_type = 'PROG'
        object_name = iv_incl
        position    = lv_jump
      EXCEPTIONS
        OTHERS      = 0.
  ENDMETHOD.

ENDCLASS.


START-OF-SELECTION.
  PERFORM search_and_display.


FORM search_and_display.

  TYPES: BEGIN OF ty_out,
           log_id    TYPE c LENGTH 20,
           subobject TYPE balsubobj,
           aluser    TYPE syuname,
           aldate    TYPE sydatum,
           altime    TYPE syuzeit,
           msgty     TYPE c LENGTH 1,
           text      TYPE c LENGTH 220,
           incl      TYPE c LENGTH 40,
           line      TYPE i,
           snap_json TYPE string,       " A8：完整 JSON（双击弹窗展示）
         END OF ty_out,
         ty_out_t TYPE STANDARD TABLE OF ty_out WITH EMPTY KEY.

  DATA: ls_filter  TYPE bal_s_lfil,
        lt_headers TYPE balhdr_t,
        lt_logh    TYPE bal_t_logh,
        lt_msgh    TYPE bal_t_msgh,
        lt_out     TYPE ty_out_t.

  FIELD-SYMBOLS: <ls_hdr> TYPE balhdr.

  " ---- 1) 检索条件 ---------------------------------------------------
  " 必须用类的常量：硬编码曾漏改（'ZLOG' vs 'ZMSGTRACE'）导致新日志全部查不到
  APPEND VALUE #( sign = 'I' option = 'EQ' low = zcl_msgtrace=>c_object ) TO ls_filter-object.
  IF p_sub IS NOT INITIAL.
    APPEND VALUE #( sign = 'I' option = 'EQ' low = p_sub ) TO ls_filter-subobject.
  ENDIF.
  IF p_id IS NOT INITIAL.
    APPEND VALUE #( sign = 'I' option = 'CP'
                    low  = |*{ p_id }*| ) TO ls_filter-extnumber.
  ENDIF.
  ls_filter-aluser[] = s_user[].
  ls_filter-date_time-date_from = s_date-low.
  ls_filter-date_time-time_from = COND #( WHEN s_time-low IS NOT INITIAL
                                          THEN s_time-low ELSE '000000' ).
  ls_filter-date_time-date_to   = s_date-high.
  IF ls_filter-date_time-date_to IS INITIAL.
    ls_filter-date_time-date_to = sy-datum.
  ENDIF.
  " 时间上界默认 23:59:59——留空 = 00:00:00 会把"当天"的日志全部排除
  ls_filter-date_time-time_to   = COND #( WHEN s_time-high IS NOT INITIAL
                                          THEN s_time-high ELSE '235959' ).
  ls_filter-max_nr_logs = p_rows.

  CALL FUNCTION 'BAL_DB_SEARCH'
    EXPORTING
      i_s_log_filter  = ls_filter
    IMPORTING
      e_t_log_header  = lt_headers
    EXCEPTIONS
      OTHERS          = 4.

  IF sy-subrc <> 0 OR lt_headers IS INITIAL.
    MESSAGE |未找到匹配的日志（ID={ p_id }）| TYPE 'S'.
    RETURN.
  ENDIF.

  " ---- 2) 加载并读取消息 ---------------------------------------------
  CALL FUNCTION 'BAL_DB_LOAD'
    EXPORTING
      i_t_log_header = lt_headers
    EXCEPTIONS
      OTHERS         = 4.
  IF sy-subrc <> 0.
    MESSAGE '日志加载失败' TYPE 'E'.
  ENDIF.

  " bal_t_logh 是排序表：APPEND 乱序会 ITAB_ILLEGAL_SORT_ORDER dump，必须 INSERT
  LOOP AT lt_headers ASSIGNING <ls_hdr>.
    INSERT <ls_hdr>-log_handle INTO TABLE lt_logh.
  ENDLOOP.

  CALL FUNCTION 'BAL_GLB_SEARCH_MSG'
    EXPORTING
      i_t_log_handle = lt_logh
    IMPORTING
      e_t_msg_handle = lt_msgh
    EXCEPTIONS
      OTHERS         = 4.

  DATA: ls_msg   TYPE bal_s_msg,
        lv_text  TYPE c LENGTH 220,
        lv_incl  TYPE c LENGTH 40,
        lv_line  TYPE c LENGTH 10,
        " BAL 按时间倒序返回消息：追溯行(I)先出现，其后跟本体行(E)——
        " 待回填机制把位置带给本体行，使 E 行也能直接双击跳转
        lv_pincl TYPE c LENGTH 40,
        lv_pline TYPE i.

  LOOP AT lt_msgh INTO DATA(ls_msgh).
    CLEAR: ls_msg, lv_text, lv_incl, lv_line.
    CALL FUNCTION 'BAL_LOG_MSG_READ'
      EXPORTING
        i_s_msg_handle = ls_msgh
      IMPORTING
        e_s_msg        = ls_msg.
    MESSAGE ID ls_msg-msgid TYPE 'I' NUMBER ls_msg-msgno
            WITH ls_msg-msgv1 ls_msg-msgv2 ls_msg-msgv3 ls_msg-msgv4
            INTO lv_text.

    " 消息归属哪个日志头（消息句柄含 log_handle）
    READ TABLE lt_headers ASSIGNING <ls_hdr>
         WITH KEY log_handle = ls_msgh-log_handle.
    IF sy-subrc <> 0.
      CONTINUE.
    ENDIF.

    APPEND VALUE ty_out(
        log_id    = <ls_hdr>-extnumber
        subobject = <ls_hdr>-subobject
        aluser    = <ls_hdr>-aluser
        aldate    = <ls_hdr>-aldate
        altime    = <ls_hdr>-altime
        msgty     = ls_msg-msgty
        text      = lv_text ) TO lt_out.

    " 本体行：继承前一条追溯行的位置（配对）
    IF lv_pincl IS NOT INITIAL
       AND lt_out[ lines( lt_out ) ]-incl IS INITIAL.
      lt_out[ lines( lt_out ) ]-incl = lv_pincl.
      lt_out[ lines( lt_out ) ]-line = lv_pline.
      CLEAR: lv_pincl, lv_pline.
    ENDIF.

    " 解析追溯行 "at INCL line N"，供双击跳源码
    FIND REGEX 'at ([A-Za-z0-9_/=]+) line ([0-9]+)'
         IN lv_text SUBMATCHES lv_incl lv_line ##REGEX_POSIX.
    IF sy-subrc = 0 AND lv_incl IS NOT INITIAL.
      lt_out[ lines( lt_out ) ]-incl = lv_incl.
      lt_out[ lines( lt_out ) ]-line = lv_line.
      lv_pincl = lv_incl.              " 等待配对的本体行
      lv_pline = lv_line.
    ENDIF.
  ENDLOOP.

  " ---- 3) A8 快照行：ZMSGTRACE_CTX 按 log_id 关联，S 级行 + 双击看完整 JSON ----
  DATA lr_id TYPE RANGE OF zmsgtrace_ctx-log_id.
  LOOP AT lt_headers ASSIGNING <ls_hdr>.
    APPEND VALUE #( sign = 'I' option = 'EQ' low = <ls_hdr>-extnumber(20) )
           TO lr_id.
  ENDLOOP.

  IF lr_id IS NOT INITIAL.
    SELECT log_id, name, data_str FROM zmsgtrace_ctx
      INTO TABLE @DATA(lt_snap)
      WHERE log_id IN @lr_id.

    LOOP AT lt_snap INTO DATA(ls_snap).
      READ TABLE lt_headers ASSIGNING <ls_hdr>
           WITH KEY extnumber = ls_snap-log_id.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      APPEND VALUE ty_out(
          log_id    = ls_snap-log_id
          subobject = <ls_hdr>-subobject
          aluser    = <ls_hdr>-aluser
          aldate    = <ls_hdr>-aldate
          altime    = <ls_hdr>-altime
          msgty     = 'S'
          text      = |snap { ls_snap-name }: { substring(
                          val = ls_snap-data_str
                          len = nmin( val1 = 160
                                      val2 = strlen( ls_snap-data_str ) ) ) }|
          snap_json = ls_snap-data_str ) TO lt_out.
    ENDLOOP.
  ENDIF.

  IF lt_out IS INITIAL.
    MESSAGE |找到 { lines( lt_headers ) } 个日志头，但无消息内容| TYPE 'S'.
    RETURN.
  ENDIF.

  SORT lt_out BY aldate DESCENDING altime DESCENDING.

  PERFORM display CHANGING lt_out.

ENDFORM.


FORM display CHANGING ct_out TYPE STANDARD TABLE.

  DATA: lo_alv     TYPE REF TO cl_salv_table,
        lo_events  TYPE REF TO cl_salv_events_table,
        lo_handler TYPE REF TO lcl_events,
        lr_table   TYPE REF TO data.

  GET REFERENCE OF ct_out INTO lr_table.
  CREATE OBJECT lo_handler EXPORTING ir_table = lr_table.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = lo_alv
        CHANGING  t_table      = ct_out ).

      lo_alv->get_columns( )->set_optimize( abap_true ).
      lo_events = lo_alv->get_event( ).
      SET HANDLER lo_handler->on_double_click FOR lo_events.
      lo_alv->display( ).

    CATCH cx_root.
      MESSAGE 'ALV 显示失败' TYPE 'E'.
  ENDTRY.

ENDFORM.
