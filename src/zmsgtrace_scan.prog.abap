REPORT zmsgtrace_scan.

* ---------------------------------------------------------------------
* ZLOG 基线扫描（开发计划 E1：存量消息点清单 → 热点替换排期）
*
* 扫描一个开发包内 PROG / FUGR（函数 include）/ CLAS（方法 include）
* 的源码，找"未走 ZCL_MSGTRACE 的裸消息点"（默认模式：MESSAGE、msgtx）。
* 输出 = 候选清单（含误报，人工确认），作为出口兜底运行后的
* 热点替换排期输入。
*
* 用法（生产系统）：SA38 运行，包 = 目标自研包；或逐包跑。
* ---------------------------------------------------------------------

PARAMETERS:
  p_pack TYPE devclass OBLIGATORY,
  p_pat1 TYPE c LENGTH 30 DEFAULT 'MESSAGE',
  p_pat2 TYPE c LENGTH 30 DEFAULT 'msgtx',
  p_sinc TYPE datum,                  " 只扫该日期后改动的对象（E3：评审/运输前检查；空=全量基线）
  p_maxh TYPE i DEFAULT 500.          " 最多输出多少条命中

TYPES: BEGIN OF ty_hit,
         objtype TYPE trobjtype,
         objname TYPE sobj_name,
         include TYPE sobj_name,
         line    TYPE i,
         text    TYPE c LENGTH 255,
         pattern TYPE c LENGTH 30,
       END OF ty_hit,
       ty_hits TYPE STANDARD TABLE OF ty_hit WITH EMPTY KEY,
       ty_src_t TYPE STANDARD TABLE OF abaptxt255 WITH EMPTY KEY.

DATA gt_hits TYPE ty_hits.


CLASS lcl_events DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS on_double_click FOR EVENT double_click OF cl_salv_events_table
      IMPORTING row column.
ENDCLASS.

CLASS lcl_events IMPLEMENTATION.

  METHOD on_double_click.
    READ TABLE gt_hits INTO DATA(ls_hit) INDEX row.
    IF sy-subrc <> 0 OR ls_hit-include IS INITIAL.
      RETURN.
    ENDIF.

    CALL FUNCTION 'RS_TOOL_ACCESS'
      EXPORTING
        operation   = 'SHOW'
        object_type = 'PROG'
        object_name = ls_hit-include
        position    = ls_hit-line
      EXCEPTIONS
        OTHERS      = 0.
  ENDMETHOD.

ENDCLASS.

START-OF-SELECTION.
  PERFORM scan_package USING p_pack.
  PERFORM display.


FORM scan_package USING iv_pack TYPE devclass.

  DATA: lt_src   TYPE ty_src_t,
        lt_tadir TYPE STANDARD TABLE OF tadir,
        lt_fdir  TYPE STANDARD TABLE OF tfdir.

  SELECT * FROM tadir INTO TABLE lt_tadir
    WHERE devclass = iv_pack
      AND object IN ('PROG','FUGR','CLAS').
  SORT lt_tadir BY object obj_name.

  " TFDIR 一次加载、内表 CP 过滤：SQL LIKE 有列长限制（30），
  " 长组名的 "L<组名>U%" 模式会 dump（SAPSQL_LIKE_PATTERN_TOO_LONG）
  SELECT * FROM tfdir INTO TABLE lt_fdir.

  LOOP AT lt_tadir INTO DATA(ls_tadir).

    " E3：限定"该日期后改动的对象"——评审/运输前只查新碰过的代码（PROGDIR-UDAT）
    DATA: lv_ok   TYPE abap_bool,
          lv_main TYPE c LENGTH 40.
    CLEAR lv_ok.
    IF ls_tadir-object = 'FUGR'.
      lv_main = |SAPL{ ls_tadir-obj_name }|.
    ELSE.
      lv_main = ls_tadir-obj_name.
    ENDIF.
    PERFORM obj_changed_after USING lv_main p_sinc CHANGING lv_ok.
    CHECK lv_ok = abap_true.

    CASE ls_tadir-object.

      WHEN 'PROG'.
        READ REPORT ls_tadir-obj_name INTO lt_src.
        PERFORM scan_source USING 'PROG' ls_tadir-obj_name
                                  ls_tadir-obj_name lt_src.

      WHEN 'FUGR'.
        " 组内函数 include：L<组名>U<nn>（CP 匹配，规避 LIKE 长度限制）
        DATA(lv_cp) = |L{ ls_tadir-obj_name }U*|.
        LOOP AT lt_fdir INTO DATA(ls_fdir)
             WHERE include CP lv_cp.
          READ REPORT ls_fdir-include INTO lt_src.
          PERFORM scan_source USING 'FUNC' ls_fdir-funcname
                                    ls_fdir-include lt_src.
        ENDLOOP.

      WHEN 'CLAS'.
        TRY.
            DATA(lt_inc) = cl_oo_classname_service=>get_all_method_includes(
                               CONV #( ls_tadir-obj_name ) ).
            DATA lv_inc_c TYPE sobj_name.
            LOOP AT lt_inc INTO DATA(lv_inc).
              lv_inc_c = lv_inc.              " string → char
              READ REPORT lv_inc_c INTO lt_src.
              PERFORM scan_source USING 'CLAS' ls_tadir-obj_name
                                        lv_inc_c lt_src.
            ENDLOOP.
          CATCH cx_root ##NO_HANDLER.   " 类读取失败（如本地类残余）跳过
        ENDTRY.

    ENDCASE.

    IF lines( gt_hits ) >= p_maxh.
      EXIT.
    ENDIF.
  ENDLOOP.

ENDFORM.


FORM obj_changed_after USING iv_main TYPE clike
                             iv_sinc TYPE datum
                    CHANGING cv_yes TYPE abap_bool.
  " 主程序的 PROGDIR-UDAT >= iv_sinc 视为"改过"；iv_sinc 空 = 不过滤（全量基线）
  DATA lv_udat TYPE datum.
  CLEAR cv_yes.
  IF iv_sinc IS INITIAL.
    cv_yes = abap_true.
    RETURN.
  ENDIF.
  SELECT SINGLE udat FROM progdir INTO lv_udat
    WHERE name = iv_main.
  IF sy-subrc = 0 AND lv_udat >= iv_sinc.
    cv_yes = abap_true.
  ENDIF.
ENDFORM.


FORM scan_source USING iv_type    TYPE trobjtype
                       iv_obj     TYPE c
                       iv_include TYPE c
                       it_src     TYPE ty_src_t.

  DATA: lv_up   TYPE string,
        lv_pat1 TYPE string,
        lv_pat2 TYPE string.
  lv_pat1 = to_upper( p_pat1 ).
  lv_pat2 = to_upper( p_pat2 ).

  LOOP AT it_src INTO DATA(lv_line).
    lv_up = lv_line.
    TRANSLATE lv_up TO UPPER CASE.
    " 已走 ZCL_MSGTRACE 的行不算裸消息
    CHECK lv_up NS 'ZCL_MSGTRACE'.

    IF p_pat1 IS NOT INITIAL
       AND lv_up CS lv_pat1.
      APPEND VALUE ty_hit( objtype = iv_type
                           objname = iv_obj
                           include = iv_include
                           line    = sy-tabix
                           text    = lv_line
                           pattern = p_pat1 ) TO gt_hits.
    ENDIF.

    IF p_pat2 IS NOT INITIAL
       AND lv_up CS lv_pat2.
      APPEND VALUE ty_hit( objtype = iv_type
                           objname = iv_obj
                           include = iv_include
                           line    = sy-tabix
                           text    = lv_line
                           pattern = p_pat2 ) TO gt_hits.
    ENDIF.

    IF lines( gt_hits ) >= p_maxh.
      RETURN.
    ENDIF.
  ENDLOOP.

ENDFORM.


FORM display.

  IF gt_hits IS INITIAL.
    MESSAGE |包 { p_pack } 内未发现裸消息点| TYPE 'S'.
    RETURN.
  ENDIF.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = DATA(lo_alv)
        CHANGING  t_table      = gt_hits ).

      lo_alv->get_columns( )->set_optimize( abap_true ).
      DATA(lo_handler) = NEW lcl_events( ).   " 须持有引用，防止被 GC
      SET HANDLER lo_handler->on_double_click FOR lo_alv->get_event( ).
      lo_alv->display( ).

    CATCH cx_root.
      MESSAGE 'ALV 显示失败' TYPE 'E'.
  ENDTRY.

  MESSAGE |命中 { lines( gt_hits ) } 条（候选清单，含误报需人工确认）| TYPE 'S'.

ENDFORM.
