FUNCTION z_log_save_rfc.
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
* IV_PAYLOAD 为数据簇（EXPORT ... TO DATA BUFFER），含两个 bapirettab 表：
*   MSGS 行：LOG_NO = 条目序号；TYPE/ID/NUMBER/MESSAGE_V1..4 = 消息内容
*   PARS 行：PARAMETER = 所属条目序号，ID = 参数名，MESSAGE_V1 = 参数值
* （编码方：ZCL_LOG=>save_indep，与 build_transport_tables 保持一致）

  DATA: lt_msgs   TYPE bapirettab,
        lt_pars   TYPE bapirettab,
        lv_handle TYPE balloghndl,
        ls_msg    TYPE bal_s_msg,
        lt_par    TYPE bal_t_par.

  IMPORT msgs = lt_msgs
         pars = lt_pars
         FROM DATA BUFFER iv_payload.

  CALL FUNCTION 'BAL_LOG_CREATE'
    EXPORTING
      i_s_log = VALUE bal_s_log(
          object    = iv_object
          subobject = iv_subobject
          extnumber = iv_extnumber
          aluser    = iv_created_by
          aldate    = iv_created_on
          altime    = iv_created_at )
    IMPORTING
      e_log_handle   = lv_handle
    EXCEPTIONS
      OTHERS         = 1.
  IF sy-subrc <> 0.
    RAISE save_failed.
  ENDIF.

  LOOP AT lt_msgs INTO DATA(ls_m).
    CLEAR: ls_msg, lt_par.
    ls_msg-msgty = ls_m-type.
    ls_msg-msgid = ls_m-id.
    ls_msg-msgno = ls_m-number.
    ls_msg-msgv1 = ls_m-message_v1.
    ls_msg-msgv2 = ls_m-message_v2.
    ls_msg-msgv3 = ls_m-message_v3.
    ls_msg-msgv4 = ls_m-message_v4.
    LOOP AT lt_pars INTO DATA(ls_p) WHERE parameter = ls_m-log_no.
      APPEND VALUE bal_s_par( parname  = ls_p-id
                              parvalue = ls_p-message_v1 ) TO lt_par.
    ENDLOOP.
    ls_msg-params-t_par = lt_par.
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
