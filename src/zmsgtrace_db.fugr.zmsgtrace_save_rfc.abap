FUNCTION zmsgtrace_save_rfc.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_OBJECT) TYPE  BALOBJ_D
*"     VALUE(IV_SUBOBJECT) TYPE  BALSUBOBJ
*"     VALUE(IV_EXTNUMBER) TYPE  BALNREXT
*"     VALUE(IV_CREATED_BY) TYPE  SYUNAME
*"     VALUE(IV_CREATED_ON) TYPE  SYDATUM
*"     VALUE(IV_CREATED_AT) TYPE  SYUZEIT
*"     VALUE(IV_PAYLOAD) TYPE  XSTRING
*"  EXCEPTIONS
*"      SAVE_FAILED
*"----------------------------------------------------------------------
* 经 DESTINATION 'NONE' 调用：在独立会话/独立 LUW 中落盘并提交，
* 调用方后续 ROLLBACK WORK 不影响已保存的日志。
*
* IV_PAYLOAD 为数据簇（EXPORT msgs ... TO DATA BUFFER），一张 bapirettab 表：
*   行 = 消息本身（TYPE/ID/NUMBER/MESSAGE_V1..4）；每条目两行——
*   本体行 + I 级追溯行（"at INCL line N; K=V"，由编码方拼接）
* （编码方：ZCL_MSGTRACE=>build_transport_tables；纯消息路径，无 BAL 参数）

  TYPES: BEGIN OF ty_snap,              " A8 快照（与 ZCL_MSGTRACE=>ty_snap 布局一致）
           name     TYPE c LENGTH 30,
           data_str TYPE string,
         END OF ty_snap,
         ty_snap_t TYPE STANDARD TABLE OF ty_snap WITH EMPTY KEY.

  DATA: lt_msgs   TYPE bapirettab,
        lt_snaps  TYPE ty_snap_t,
        lv_handle TYPE balloghndl,
        ls_msg    TYPE bal_s_msg,
        lv_ret    TYPE i,
        lv_seq    TYPE n LENGTH 4.

  IMPORT msgs  = lt_msgs
         snaps = lt_snaps
         FROM DATA BUFFER iv_payload.

  " A8：快照写侧表（独立 LUW 内，随日志一起提交）
  LOOP AT lt_snaps INTO DATA(ls_s).
    lv_seq = sy-tabix.
    INSERT zmsgtrace_ctx FROM @( VALUE #(
        log_id     = iv_extnumber(20)
        seq        = lv_seq
        name       = ls_s-name
        data_str   = ls_s-data_str
        created_by = iv_created_by
        created_on = iv_created_on ) ).
  ENDLOOP.

  " D5 保留期：按子对象映射（与 ZCL_MSGTRACE 常量一致），SLG2 自动尊重
  CASE iv_subobject.
    WHEN zcl_msgtrace=>c_subobject_aud.
      lv_ret = zcl_msgtrace=>c_retention_aud.
    WHEN zcl_msgtrace=>c_subobject_trc.
      lv_ret = zcl_msgtrace=>c_retention_trc.
    WHEN OTHERS.
      lv_ret = zcl_msgtrace=>c_retention_err.
  ENDCASE.

  CALL FUNCTION 'BAL_LOG_CREATE'
    EXPORTING
      i_s_log = VALUE bal_s_log(
          object    = iv_object
          subobject = iv_subobject
          extnumber = iv_extnumber
          aluser    = iv_created_by
          aldate    = iv_created_on
          altime    = iv_created_at
          aldate_del = iv_created_on + lv_ret )
    IMPORTING
      e_log_handle   = lv_handle
    EXCEPTIONS
      OTHERS         = 1.
  IF sy-subrc <> 0.
    RAISE save_failed.
  ENDIF.

  LOOP AT lt_msgs INTO DATA(ls_m).
    CLEAR ls_msg.
    ls_msg-msgty = ls_m-type.
    ls_msg-msgid = ls_m-id.
    ls_msg-msgno = ls_m-number.
    ls_msg-msgv1 = ls_m-message_v1.
    ls_msg-msgv2 = ls_m-message_v2.
    ls_msg-msgv3 = ls_m-message_v3.
    ls_msg-msgv4 = ls_m-message_v4.
    CALL FUNCTION 'BAL_LOG_MSG_ADD'
      EXPORTING
        i_log_handle = lv_handle
        i_s_msg      = ls_msg
      EXCEPTIONS
        OTHERS       = 1.
  ENDLOOP.

  CALL FUNCTION 'BAL_DB_SAVE'
    EXPORTING
      i_save_all = abap_true
    EXCEPTIONS
      OTHERS      = 1.
  IF sy-subrc <> 0.
    ROLLBACK WORK.
    RAISE save_failed.
  ENDIF.

  COMMIT WORK.

ENDFUNCTION.
