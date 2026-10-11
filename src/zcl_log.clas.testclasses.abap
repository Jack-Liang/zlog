" 单元测试只覆盖纯逻辑（ID 生成、ret2 组装、文本拆分、缓冲管理）。
" 持久化路径（save_luw / save_indep → RFC 'NONE'）有数据库副作用，
" 不在 ABAP Unit 中执行，由演示程序 ZLOG_DEMO + SLG1 人工验证。

CLASS ltcl_log DEFINITION DEFERRED.
CLASS zcl_log DEFINITION LOCAL FRIENDS ltcl_log.

CLASS ltcl_log DEFINITION FINAL FOR TESTING
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
      teardown.

ENDCLASS.


CLASS ltcl_log IMPLEMENTATION.

  METHOD begin_returns_unique_id.
    DATA(lv_id1) = zcl_log=>begin( ).
    cl_abap_unit_assert=>assert_not_initial( lv_id1 ).
    zcl_log=>reset( ).
    DATA(lv_id2) = zcl_log=>begin( ).
    cl_abap_unit_assert=>assert_differs( exp = lv_id1 act = lv_id2 ).
  ENDMETHOD.


  METHOD text_ret2_carries_log_id.
    zcl_log=>begin( ).
    DATA(ls_ret2) = zcl_log=>text( '物料 4711 不存在' ).
    cl_abap_unit_assert=>assert_equals( exp = zcl_log=>get_id( )
                                        act = ls_ret2-log_no ).
    cl_abap_unit_assert=>assert_true(
        act = xsdbool( ls_ret2-message CS ' (log ' ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'ZLOG' act = ls_ret2-id ).
    cl_abap_unit_assert=>assert_equals( exp = '001' act = ls_ret2-number ).
  ENDMETHOD.


  METHOD text_is_split_into_msg_vars.
    zcl_log=>begin( ).
    zcl_log=>text( repeat( val = `x` occ = 120 ) ).
    DATA(ls_entry) = zcl_log=>gs_buffer-entries[ 1 ].
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv1 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv2 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 20 act = strlen( ls_entry-msgv3 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 0  act = strlen( ls_entry-msgv4 ) ).
  ENDMETHOD.


  METHOD text_truncated_at_200_chars.
    zcl_log=>begin( ).
    zcl_log=>text( repeat( val = `y` occ = 250 ) ).
    DATA(ls_entry) = zcl_log=>gs_buffer-entries[ 1 ].
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv1 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv2 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv3 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv4 ) ).
  ENDMETHOD.


  METHOD auto_begin_when_missing.
    zcl_log=>reset( ).
    cl_abap_unit_assert=>assert_false( zcl_log=>is_active( ) ).
    zcl_log=>text( '未显式 begin 也应能记录' ).
    cl_abap_unit_assert=>assert_true( zcl_log=>is_active( ) ).
    cl_abap_unit_assert=>assert_not_initial( zcl_log=>get_id( ) ).
  ENDMETHOD.


  METHOD duplicates_collapsed.                 " 量控 D3：降噪
    zcl_log=>begin( ).
    DO 3 TIMES.
      zcl_log=>text( 'same message' ).
    ENDDO.
    zcl_log=>text( 'different message' ).
    cl_abap_unit_assert=>assert_equals(
        exp = 2 act = lines( zcl_log=>gs_buffer-entries ) ).
    cl_abap_unit_assert=>assert_equals(
        exp = 3 act = zcl_log=>gs_buffer-entries[ 1 ]-repeats ).
    cl_abap_unit_assert=>assert_equals(
        exp = 1 act = zcl_log=>gs_buffer-entries[ 2 ]-repeats ).
  ENDMETHOD.


  METHOD overflow_capped.                      " 量控 D3：上限保护
    zcl_log=>begin( ).
    DO 250 TIMES.
      zcl_log=>text( |msg no { sy-index }| ).
    ENDDO.
    cl_abap_unit_assert=>assert_equals(
        exp = zcl_log=>c_max_entries
        act = lines( zcl_log=>gs_buffer-entries ) ).
    cl_abap_unit_assert=>assert_equals(
        exp = 50 act = gs_buffer-overflow ).
  ENDMETHOD.


  METHOD stack_recorded_when_enabled.          " A6 调用链开关
    zcl_log=>begin( iv_stack = abap_true ).
    zcl_log=>text( 'with stack' ).
    cl_abap_unit_assert=>assert_true(
        act = xsdbool( zcl_log=>gs_buffer-entries[ 1 ]-stack CS '(' ) ).

    zcl_log=>reset( ).
    zcl_log=>begin( ).
    zcl_log=>text( 'without stack' ).
    cl_abap_unit_assert=>assert_equals(
        exp = `` act = zcl_log=>gs_buffer-entries[ 1 ]-stack ).
  ENDMETHOD.


  METHOD teardown.
    zcl_log=>reset( ).
  ENDMETHOD.

ENDCLASS.
