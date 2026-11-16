#!/bin/bash
# =============================================================
# 机台问题排查脚本
# 用法：bash scripts/diagnose_machine.sh [machine_id] [时间段] [日期]
#
# 示例：
#   bash scripts/diagnose_machine.sh 1318              # 今天全天
#   bash scripts/diagnose_machine.sh 1318 15:50-16:00  # 今天指定时段
#   bash scripts/diagnose_machine.sh 1318 15:50-16:00 2026-11-16
# =============================================================

MACHINE_ID="${1:-}"
TIME_RANGE="${2:-}"   # 格式 HH:MM-HH:MM，空则不限时段
DATE="${3:-$(date +%F)}"
LOG_DIR="${LOG_DIR:-/www/wwwroot/work.5super9.com/runtime/logs}"

if [ -z "$MACHINE_ID" ]; then
    echo "用法: $0 <machine_id> [HH:MM-HH:MM] [YYYY-MM-DD]"
    echo "示例: $0 1318 15:50-16:00"
    exit 1
fi

# ---- 颜色 ----
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

# ---- 解析时间段 ----
TIME_GREP=""
if [ -n "$TIME_RANGE" ]; then
    START_H=$(echo "$TIME_RANGE" | cut -d- -f1 | cut -d: -f1)
    START_M=$(echo "$TIME_RANGE" | cut -d- -f1 | cut -d: -f2)
    END_H=$(echo "$TIME_RANGE"   | cut -d- -f2 | cut -d: -f1)
    END_M=$(echo "$TIME_RANGE"   | cut -d- -f2 | cut -d: -f2)
    # 生成分钟级列表，用于 grep -E
    minutes=""
    h=$START_H; m=$START_M
    while [ "$h$m" -le "$END_H$END_M" ]; do
        minutes="${minutes}T$(printf '%02d:%02d' $h $m)|"
        m=$((10#$m + 1))
        if [ $m -ge 60 ]; then m=0; h=$((10#$h + 1)); fi
    done
    TIME_GREP=$(echo "$minutes" | sed 's/|$//')
fi

filter_time() {
    if [ -n "$TIME_GREP" ]; then
        grep -E "$TIME_GREP"
    else
        cat
    fi
}

section() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
}

hit() { grep -c "" 2>/dev/null || echo 0; }

# ---- 确定日志文件 ----
CTRL="$LOG_DIR/machine_ctrl-${DATE}.log"
LOTTERY="$LOG_DIR/lottery_machine-${DATE}.log"
DEFAULT="$LOG_DIR/default-${DATE}.log"
STDOUT="$LOG_DIR/stdout.log"

echo ""
echo -e "${GREEN}=================================================="
echo -e "  机台排查  machine_id=${MACHINE_ID}  日期=${DATE}"
[ -n "$TIME_RANGE" ] && echo -e "  时段限制：${TIME_RANGE}"
echo -e "==================================================${NC}"

# ==========================================================
# [1] 完整事件时间线（machine_ctrl，按时间顺序）
# ==========================================================
section "[1] 完整事件时间线（machine_ctrl）"
if [ -f "$CTRL" ]; then
    result=$(grep "\"machine_id\":${MACHINE_ID}" "$CTRL" | filter_time \
        | python3 -c "
import sys, json
lines = sys.stdin.readlines()
for line in lines:
    try:
        d = json.loads(line.strip())
        status = d.get('log_status','')
        action = d.get('action','')
        desc   = d.get('action_desc','')[:120]
        ts     = d.get('datetime','')
        # 颜色前缀
        if status == 'error':   prefix = '\033[0;31m[ERR]\033[0m'
        elif status == 'warning': prefix = '\033[1;33m[WRN]\033[0m'
        else:                     prefix = '\033[0;32m[OK ]\033[0m'
        print(f'{prefix} {ts}  {action:<28} {desc}')
    except:
        print(line.rstrip())
" 2>/dev/null || grep "\"machine_id\":${MACHINE_ID}" "$CTRL" | filter_time \
        | awk -F'"' '{
            for(i=1;i<=NF;i++){
                if($i=="datetime") dt=$(i+2)
                if($i=="log_status") st=$(i+2)
                if($i=="action") ac=$(i+2)
                if($i=="action_desc") {sub(/.*action_desc":"/,""); sub(/".*/,""); ad=$0}
            }
            printf "[%s] %s  %-25s\n", st, dt, ac
        }')
    count=$(grep -c "\"machine_id\":${MACHINE_ID}" "$CTRL" | filter_time 2>/dev/null || echo "?")
    echo -e "\n  共 ${count} 条记录"
else
    echo -e "  ${YELLOW}文件不存在: $CTRL${NC}"
fi

# ==========================================================
# [2] 仅显示 error / warning
# ==========================================================
section "[2] 异常记录（error + warning）"
if [ -f "$CTRL" ]; then
    grep "\"machine_id\":${MACHINE_ID}" "$CTRL" | filter_time \
        | grep -E '"log_status":"(error|warning)"' \
        | while IFS= read -r line; do
            ts=$(echo "$line"    | grep -o '"datetime":"[^"]*"' | head -1 | cut -d'"' -f4)
            action=$(echo "$line" | grep -o '"action":"[^"]*"'  | head -1 | cut -d'"' -f4)
            desc=$(echo "$line"   | grep -o '"action_desc":"[^"]*"' | head -1 | cut -d'"' -f4)
            status=$(echo "$line" | grep -o '"log_status":"[^"]*"'  | head -1 | cut -d'"' -f4)
            if [ "$status" = "error" ]; then
                echo -e "  ${RED}[ERR]${NC} $ts  $action"
            else
                echo -e "  ${YELLOW}[WRN]${NC} $ts  $action"
            fi
            echo "        $desc" | cut -c1-200
        done
else
    echo -e "  ${YELLOW}跳过（文件不存在）${NC}"
fi

# ==========================================================
# [3] 下珠相关（score_to_point）
# ==========================================================
section "[3] 下珠指令追踪（score_to_point）"
if [ -f "$CTRL" ]; then
    grep "\"machine_id\":${MACHINE_ID}" "$CTRL" | filter_time \
        | grep '"action":"score_to_point"' \
        | while IFS= read -r line; do
            ts=$(echo "$line"    | grep -o '"datetime":"[^"]*"' | head -1 | cut -d'"' -f4)
            status=$(echo "$line" | grep -o '"log_status":"[^"]*"' | head -1 | cut -d'"' -f4)
            dir=$(echo "$line"    | grep -o '"log_direction":"[^"]*"' | head -1 | cut -d'"' -f4)
            desc=$(echo "$line"   | grep -o '"action_desc":"[^"]*"'  | head -1 | cut -d'"' -f4)
            echo "  [$status/$dir] $ts  $desc"
        done
    cnt=$(grep "\"machine_id\":${MACHINE_ID}" "$CTRL" | filter_time | grep -c '"action":"score_to_point"')
    [ "$cnt" -eq 0 ] && echo -e "  ${RED}⚠ 未找到任何 score_to_point 记录（下珠可能从未触发）${NC}"
else
    echo -e "  ${YELLOW}跳过（文件不存在）${NC}"
fi

# ==========================================================
# [4] 彩金/开奖后处理（reward_post_process）
# ==========================================================
section "[4] 开奖后处理（reward_post_process）"
if [ -f "$CTRL" ]; then
    out=$(grep "\"machine_id\":${MACHINE_ID}" "$CTRL" | filter_time \
        | grep '"action":"reward_post_process"')
    if [ -z "$out" ]; then
        echo "  无记录（新版代码上线后才会有此 action）"
    else
        echo "$out" | while IFS= read -r line; do
            ts=$(echo "$line"   | grep -o '"datetime":"[^"]*"' | head -1 | cut -d'"' -f4)
            status=$(echo "$line"| grep -o '"log_status":"[^"]*"' | head -1 | cut -d'"' -f4)
            desc=$(echo "$line"  | grep -o '"action_desc":"[^"]*"' | head -1 | cut -d'"' -f4)
            echo -e "  ${RED}[$status]${NC} $ts"
            echo "    $desc" | cut -c1-300
        done
    fi
else
    echo -e "  ${YELLOW}跳过（文件不存在）${NC}"
fi

# ==========================================================
# [5] 彩金队列消费日志
# ==========================================================
section "[5] 彩金队列（lottery_machine）"
if [ -f "$LOTTERY" ]; then
    grep "\"machine_id\":${MACHINE_ID}" "$LOTTERY" 2>/dev/null | filter_time \
        | while IFS= read -r line; do
            ts=$(echo "$line"   | grep -o '"datetime":"[^"]*"' | head -1 | cut -d'"' -f4)
            level=$(echo "$line" | grep -o '"level":"[^"]*"'    | head -1 | cut -d'"' -f4)
            msg=$(echo "$line"   | grep -o '"message":"[^"]*"'  | head -1 | cut -d'"' -f4)
            echo "  [$level] $ts  $msg"
        done || grep "1318" "$LOTTERY" | filter_time | head -20
else
    echo -e "  ${YELLOW}文件不存在: $LOTTERY${NC}"
fi

# ==========================================================
# [6] 外层异常（default.log / stdout.log）
# ==========================================================
section "[6] 外层异常（default.log / stdout）"
for logfile in "$DEFAULT" "$STDOUT"; do
    [ -f "$logfile" ] || continue
    result=$(grep -i "1318\|machine_id.*1318" "$logfile" 2>/dev/null | filter_time | head -20)
    if [ -n "$result" ]; then
        echo -e "  ${YELLOW}── $logfile ──${NC}"
        echo "$result"
    fi
done

# ==========================================================
# [7] 机台当前缓存状态（需 Redis 访问）
# ==========================================================
section "[7] Redis 机台缓存（machine_cache:1318）"
# 尝试从 .env 读取 Redis 配置
REDIS_HOST="127.0.0.1"; REDIS_PORT="6379"; REDIS_DB="0"; REDIS_PASS=""
if [ -f /www/wwwroot/work.5super9.com/.env ]; then
    _h=$(grep '^REDIS_HOST='    /www/wwwroot/work.5super9.com/.env | cut -d= -f2 | tr -d '"')
    _p=$(grep '^REDIS_PORT='    /www/wwwroot/work.5super9.com/.env | cut -d= -f2 | tr -d '"')
    _d=$(grep '^REDIS_DB='      /www/wwwroot/work.5super9.com/.env | cut -d= -f2 | tr -d '"')
    _pw=$(grep '^REDIS_PASSWORD=' /www/wwwroot/work.5super9.com/.env | cut -d= -f2 | tr -d '"')
    [ -n "$_h" ] && REDIS_HOST=$_h
    [ -n "$_p" ] && REDIS_PORT=$_p
    [ -n "$_d" ] && REDIS_DB=$_d
    [ -n "$_pw" ] && REDIS_PASS=$_pw
fi
REDIS_CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT -n $REDIS_DB"
[ -n "$REDIS_PASS" ] && REDIS_CMD="$REDIS_CMD -a $REDIS_PASS"

if command -v redis-cli &>/dev/null; then
    keys=$($REDIS_CMD KEYS "machine_cache:${MACHINE_ID}" 2>/dev/null)
    if [ -n "$keys" ]; then
        echo "  Key: machine_cache:${MACHINE_ID}"
        $REDIS_CMD GET "machine_cache:${MACHINE_ID}" 2>/dev/null \
            | python3 -m json.tool 2>/dev/null \
            | grep -E '"score"|"reward_status"|"gaming_user_id"|"win_number"|"rush_status"|"bb_status"' \
            | sed 's/^/  /'
    else
        # 尝试 HGETALL
        result=$($REDIS_CMD HGETALL "machine_cache:${MACHINE_ID}" 2>/dev/null)
        [ -n "$result" ] && echo "$result" | head -30 | sed 's/^/  /' || echo "  未找到 machine_cache:${MACHINE_ID}"
    fi
else
    echo -e "  ${YELLOW}redis-cli 不可用，跳过${NC}"
fi

echo ""
echo -e "${GREEN}════════════════ 排查完成 ════════════════${NC}"
echo ""
echo "诊断提示："
echo "  - [3] score_to_point 无记录 → 下珠指令从未发出（查 [2][4] 找原因）"
echo "  - [2] message_handle 报错   → 被外层 catch 捕获，下珠被跳过（旧代码问题）"
echo "  - [3] score_to_point 嘗試耗盡 → 指令发出但机台未响应（机台离线或故障）"
echo "  - [7] score > 0             → 机台缓存中仍有待出珠数，需手动触发弃台"
