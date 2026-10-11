REPORT zmsgtrace_cleanup.

* ZMSGTRACE_CTX 快照清理（A8 配套，随 SLG2 作业一起排班）
* 按年龄清理：最长保留期(AUDIT 365 天)+缓冲；孤儿行（父日志已删）同样到期消失

PARAMETERS:
  p_days TYPE i DEFAULT 400 OBLIGATORY.   " 天数（> 最长保留期 365）

START-OF-SELECTION.
  DATA lv_cutoff TYPE sydatum.
  lv_cutoff = sy-datum - p_days.
  DELETE FROM zmsgtrace_ctx WHERE created_on < lv_cutoff.
  MESSAGE |已清理 { sy-dbcnt } 条 { p_days } 天前的快照记录| TYPE 'S'.
