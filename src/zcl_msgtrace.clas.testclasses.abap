" sync marker: force test include into system via abapGit pull 2026-10-12
" 单元测试只覆盖纯逻辑（ID 生成、ret2 组装、文本拆分、缓冲管理）。
" 持久化路径（save_luw / save_indep → RFC 'NONE'）有数据库副作用，
" 不在 ABAP Unit 中执行，由演示程序 ZMSGTRACE_DEMO + SLG1 人工验证。

CLASS ltcl_log DEFINITION DEFERRED.
CLASS zcl_msgtrace DEFINITION LOCAL FRIENDS ltcl_log.

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
      snap_serializes_json FOR TESTING,
      teardown.

ENDCLASS.


CLASS ltcl_log IMPLEMENTATION.

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
    zcl_msgtrace=>text( repeat( val = `x` occ = 120 ) ).
    DATA(ls_entry) = zcl_msgtrace=>gs_buffer-entries[ 1 ].
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv1 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv2 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 20 act = strlen( ls_entry-msgv3 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 0  act = strlen( ls_entry-msgv4 ) ).
  ENDMETHOD.


  METHOD text_truncated_at_200_chars.
    zcl_msgtrace=>begin( ).
    zcl_msgtrace=>text( repeat( val = `y` occ = 250 ) ).
    DATA(ls_entry) = zcl_msgtrace=>gs_buffer-entries[ 1 ].
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv1 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv2 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv3 ) ).
    cl_abap_unit_assert=>assert_equals( exp = 50 act = strlen( ls_entry-msgv4 ) ).
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
    zcl_msgtrace=>text( 'different message' ).
    cl_abap_unit_assert=>assert_equals(
        exp = 2 act = lines( zcl_msgtrace=>gs_buffer-entries ) ).
    cl_abap_unit_assert=>assert_equals(
        exp = 3 act = zcl_msgtrace=>gs_buffer-entries[ 1 ]-repeats ).
    cl_abap_unit_assert=>assert_equals(
        exp = 1 act = zcl_msgtrace=>gs_buffer-entries[ 2 ]-repeats ).
  ENDMETHOD.


  METHOD overflow_capped.                      " 量控 D3：上限保护
    zcl_msgtrace=>begin( ).
    DO 250 TIMES.
      zcl_msgtrace=>text( |msg no { sy-index }| ).
    ENDDO.
    cl_abap_unit_assert=>assert_equals(
        exp = zcl_msgtrace=>c_max_entries
        act = lines( zcl_msgtrace=>gs_buffer-entries ) ).
    cl_abap_unit_assert=>assert_equals(
        exp = 50 act = gs_buffer-overflow ).
  ENDMETHOD.


  METHOD stack_recorded_when_enabled.          " A6 调用链开关
    zcl_msgtrace=>begin( iv_stack = abap_true ).
    zcl_msgtrace=>text( 'with stack' ).
    cl_abap_unit_assert=>assert_true(
        act = xsdbool( zcl_msgtrace=>gs_buffer-entries[ 1 ]-stack CS '(' ) ).

    zcl_msgtrace=>reset( ).
    zcl_msgtrace=>begin( ).
    zcl_msgtrace=>text( 'without stack' ).
    cl_abap_unit_assert=>assert_equals(
        exp = `` act = zcl_msgtrace=>gs_buffer-entries[ 1 ]-stack ).
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

    cl_abap_unit_assert=>assert_equals(
        exp = 1 act = lines( zcl_msgtrace=>gs_buffer-snaps ) ).
    cl_abap_unit_assert=>assert_true(
        act = xsdbool( zcl_msgtrace=>gs_buffer-snaps[ 1 ]-data_str CS '"MATNR"' ) ).
  ENDMETHOD.


  METHOD teardown.
    zcl_msgtrace=>reset( ).
  ENDMETHOD.

ENDCLASS.
