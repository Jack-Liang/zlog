REPORT zlog_demo.

* ZCL_LOG 演示：跑完后用 ZLOG_QUERY（SA38，粘 ID）或 SLG1（对象 ZLOG）检查

START-OF-SELECTION.

  " ---- 场景 1：一行式迁移（text_now）—— 存量代码替换的标准形态 ----
  " 原来：ls_return-msgtx = |物料 4711 不存在|.
  " 现在：文本尾部自动带 (log ID)，前端零改造
  WRITE / zcl_log=>text_now( |物料 4711 不存在| ).

  " ---- 场景 2：双字段（log_parts）—— msgtx 干净文本 + logid 独立字段 ----
  zcl_log=>log_parts(
      EXPORTING iv_text   = |库存不足：需 100 有 37|
                 it_ctx    = VALUE #( ( name = 'MATNR' value = '4711' ) )
      IMPORTING ev_text   = DATA(lv_clean)
                ev_log_id = DATA(lv_id2) ).
  WRITE: / lv_clean.
  WRITE / |  logid = { lv_id2 }|.

  " ---- 场景 3：会话式，多条目共享一个 ID ----
  DATA(lv_id) = zcl_log=>begin( iv_subobject = zcl_log=>c_subobject_aud ).
  zcl_log=>text( iv_text = |用户 { sy-uname } 执行了库存盘点导入|
                 iv_msgty = 'I' ).
  zcl_log=>msg( iv_msgid = 'ZLOG'
                iv_msgno = '001'
                iv_msgv1 = '盘点凭证'
                iv_msgv2 = '5000012345'
                iv_msgv3 = '已锁定，需先解锁再重试' ).
  TRY.
      RAISE EXCEPTION TYPE cx_sy_zerodivide.
    CATCH cx_sy_zerodivide INTO DATA(lx).
      zcl_log=>exception( lx ).        " 自动记录 RAISE 点的 程序/行号
  ENDTRY.

  " ---- 量控演示：同文本同位置循环 3 次，自动合并为一条（追溯行标 x3）----
  DO 3 TIMES.
    zcl_log=>text( iv_text = |行项目校验重复失败| ).
  ENDDO.
  zcl_log=>save( ).

  SKIP.
  WRITE / |场景 3 的 Log ID: { lv_id }|.
  WRITE / '验证：SA38 跑 ZLOG_QUERY 粘任一 ID；或 SLG1（对象 ZLOG + 外部编号）。'.
  WRITE / '双击追溯行（at ... line N; K=V）可直接跳到报错源码行。'.
