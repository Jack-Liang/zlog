REPORT zlog_demo.

* ZCL_LOG 演示：跑完后用 SLG1（对象 ZLOG，外部编号 = 屏幕上输出的 ID）检查

START-OF-SELECTION.

  " 场景 1：出口兜底式一步留痕（B1/B2 最常用形态）
  " 返回的 message 尾部自带 " (log ID)"，可直接覆盖到 msgtx 字段
  DATA(ls_ret2) = zcl_log=>log_now(
      iv_text = |物料 4711 不存在（系统 { sy-sysid }，客户端 { sy-mandt }）|
      it_ctx  = VALUE #( ( name = 'MATNR' value = '4711' ) ) ).
  WRITE / ls_ret2-message.

  " 场景 2：会话式 —— 多条目共享一个 ID（留痕 / 还原完整过程）
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
  zcl_log=>save( ).

  SKIP.
  WRITE / |Log ID        : { lv_id }|.
  WRITE / |Log ID (场景1): { ls_ret2-log_no }|.
  WRITE / 'SLG1 检索     : 对象 ZLOG，外部编号输入以上任一 ID'.
