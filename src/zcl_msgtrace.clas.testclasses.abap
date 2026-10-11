" 单元测试全部走黑盒路径（公开 API + get_stats 内省），无需 FRIENDS。
" 持久化路径（save_luw / save_indep → RFC 'NONE'）有数据库副作用，
" 不在 ABAP Unit 中执行，由 ZMSGTRACE_DEMO + ZMSGTRACE_QUERY 人工验证。

CLASS ltcl_msgtrace DEFINITION FINAL FOR TESTING
  RISK LEVEL HARMLESS
  DURATION SHORT.

  PRIVATE SECTION.
    METHODS:
      begin_returns_unique_id FOR TESTING,
      text_ret2_carries_log_id FOR TESTING,
      text_is_split_into_msg_vars FOR TESTING,
      text_truncated_at_200_chars FOR TESTING,
      auto_begin_when_missing FOR TESTING,
      duplicates_collapsed FOR TESTING,
      overflow_capped FOR TESTING,
      stack_recorded_when_enabled FOR TESTING,
      snap_serializes_json FOR TESTING,
      ctx_recorded_on_text FOR TESTING,
      different_ctx_not_collapsed FOR TESTING,
      log_same_line IMPORTING matnr TYPE clike,
      teardown.

ENDCLASS.


CLASS ltcl_msgtrace IMPLEMENTATION.

  METHOD begin_returns_unique_id.
    DATA(lv_id1) = zcl_msgtrace=>begin( ).
    cl_abap_unit_assert=>assert_not_initial( lv_id1 ).
    zcl_msgtrace=>reset( ).
    DATA(lv_id2) = zcl_msgtrace=>begin( ).
    cl_abap_unit_assert=>assert_differs( exp = lv_id1 act = lv_id2 ).
  ENDMETHOD.


  METHOD text_ret2_carries_log_id.
    zcl_msgtrace=>begin( ).
    DATA(ls_ret2) = zcl_msgtrace=>text( '物料 4711 不存在' ).
    cl_abap_unit_assert=>assert_equals( exp = zcl_msgtrace=>get_id( )
                                        act = ls_ret2-log_no ).
    cl_abap_unit_assert=>assert_true(
        act = xsdbool( ls_ret2-message CS ' (log ' ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'ZMSGTRACE' act = ls_ret2-id ).
    cl_abap_unit_assert=>assert_equals( exp = '001' act = ls_ret2-number ).
  ENDMETHOD.


  METHOD text_is_split_into_msg_vars.
    zcl_msgtrace=>begin( ).
    DATA(ls_ret2) = zcl_msgtrace=>text( repeat( val = `x` occ = 120 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_ret2-message_v1 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_ret2-message_v2 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 20 act = strlen( ls_ret2-message_v3 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 0  act = strlen( ls_ret2-message_v4 ) ).
  ENDMETHOD.


  METHOD text_truncated_at_200_chars.
    zcl_msgtrace=>begin( ).
    DATA(ls_ret2) = zcl_msgtrace=>text( repeat( val = `y` occ = 250 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_ret2-message_v1 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_ret2-message_v2 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_ret2-message_v3 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_ret2-message_v4 ) ).
  ENDMETHOD.


  METHOD auto_begin_when_missing.
    zcl_msgtrace=>reset( ).
    cl_abap_unit_assert=>assert_false( zcl_msgtrace=>is_active( ) ).
    zcl_msgtrace=>text( '未显式 begin 也应能记录' ).
    cl_abap_unit_assert=>assert_true( zcl_msgtrace=>is_active( ) ).
    cl_abap_unit_assert=>assert_not_initial( zcl_msgtrace=>get_id( ) ).
  ENDMETHOD.


  METHOD duplicates_collapsed.                 " 量控 D3：降噪
    zcl_msgtrace=>begin( ).
    DO 3 TIMES.
      zcl_msgtrace=>text( 'same message' ).
    ENDDO.
    DATA(ls_stats) = zcl_msgtrace=>get_stats( ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = ls_stats-entries ).
    cl_abap_unit_assert=>assert_equals( exp = 3 act = ls_stats-last_repeats ).

    zcl_msgtrace=>text( 'different message' ).
    ls_stats = zcl_msgtrace=>get_stats( ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = ls_stats-entries ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = ls_stats-last_repeats ).
  ENDMETHOD.


  METHOD overflow_capped.                      " 量控 D3：上限保护
    zcl_msgtrace=>begin( ).
    DO 250 TIMES.
      zcl_msgtrace=>text( |msg no { sy-index }| ).
    ENDDO.
    DATA(ls_stats) = zcl_msgtrace=>get_stats( ).
    cl_abap_unit_assert=>assert_equals(
        exp = zcl_msgtrace=>c_max_entries act = ls_stats-entries ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = ls_stats-overflow ).
  ENDMETHOD.


  METHOD stack_recorded_when_enabled.          " A6 调用链开关
    zcl_msgtrace=>begin( iv_stack = abap_true ).
    zcl_msgtrace=>text( 'with stack' ).
    cl_abap_unit_assert=>assert_true(
        act = xsdbool( zcl_msgtrace=>get_stats( )-last_stack CS '(' ) ).

    zcl_msgtrace=>reset( ).
    zcl_msgtrace=>begin( ).
    zcl_msgtrace=>text( 'without stack' ).
    cl_abap_unit_assert=>assert_equals(
        exp = `` act = zcl_msgtrace=>get_stats( )-last_stack ).
  ENDMETHOD.


  METHOD snap_serializes_json.                 " A8 结构化快照
    TYPES: BEGIN OF ty_ord,
             matnr TYPE c LENGTH 18,
             qty   TYPE i,
           END OF ty_ord.

    zcl_msgtrace=>begin( ).
    zcl_msgtrace=>text( 'snap test' ).
    zcl_msgtrace=>snap( iv_name = 'ORDER'
                        ig_data = VALUE ty_ord( matnr = 'M-1' qty = 3 ) ).

    DATA(ls_stats) = zcl_msgtrace=>get_stats( ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = ls_stats-snaps ).
    cl_abap_unit_assert=>assert_true(
        act = xsdbool( ls_stats-last_snap CS '"MATNR"' ) ).
  ENDMETHOD.


  METHOD ctx_recorded_on_text.                 " it_ctx 必须随条目记录（曾整族丢失）
    zcl_msgtrace=>begin( ).
    zcl_msgtrace=>text( iv_text = 'ctx test'
                        it_ctx  = VALUE #( ( name = 'MATNR' value = '4711' ) ) ).
    cl_abap_unit_assert=>assert_equals(
        exp = 'MATNR=4711' act = zcl_msgtrace=>get_stats( )-last_ctx ).

    zcl_msgtrace=>reset( ).
    zcl_msgtrace=>begin( ).
    zcl_msgtrace=>msg( iv_msgid = 'ZMSGTRACE' iv_msgno = '001'
                       it_ctx   = VALUE #( ( name = 'VBELN' value = '0001' ) ) ).
    cl_abap_unit_assert=>assert_equals(
        exp = 'VBELN=0001' act = zcl_msgtrace=>get_stats( )-last_ctx ).
  ENDMETHOD.


  METHOD different_ctx_not_collapsed.          " 量控不得把不同业务键并成一条
    zcl_msgtrace=>begin( ).
    log_same_line( 'M1' ).
    log_same_line( 'M2' ).
    DATA(ls_stats) = zcl_msgtrace=>get_stats( ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = ls_stats-entries ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = ls_stats-last_repeats ).
    cl_abap_unit_assert=>assert_equals(
        exp = 'MATNR=M2' act = ls_stats-last_ctx ).
  ENDMETHOD.


  METHOD log_same_line.                        " 同一行调 text，保证调用位置一致
    zcl_msgtrace=>text( iv_text = '物料不存在'
                        it_ctx  = VALUE #( ( name = 'MATNR' value = matnr ) ) ).
  ENDMETHOD.


  METHOD teardown.
    zcl_msgtrace=>reset( ).
  ENDMETHOD.

ENDCLASS.
