#!/bin/bash
# =============================================================================
# W6 Demo — PHẦN CÒN LẠI (sau khi costa-04..10 + sec-04 đã xong)
# Chạy: bash scripts/demo_remaining.sh
# =============================================================================
set -e

REGION="us-east-1"
SEC_GUARD_FN="geekbrain-security-guard-dev"
KB_SYNC_FN="geekbrain-kb-auto-sync-dev"
KB_BUCKET="geekbrain-kb-dev"
SCREENSHOT_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/w6_screenshots"
OUT_DIR="/tmp/w6_evidence"

# Tắt pager để tránh bị kẹt trong less/more
export AWS_PAGER=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$OUT_DIR" "$SCREENSHOT_DIR"

pause() {
  echo ""
  echo -e "${YELLOW}📸 CHỤP ẢNH: $1${NC}"
  echo -e "${CYAN}   File: $2${NC}"
  echo -e "   Nhấn ENTER khi đã chụp xong..."
  read -r
}

section() {
  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}  $1${NC}"
  echo -e "${GREEN}============================================================${NC}"
  echo ""
}

# =============================================================================
# SEC-05/06/07 — Chụp kết quả Security Guard đã chạy
# (Lambda đã fix bucket lúc nãy — chỉ cần chụp ảnh)
# =============================================================================

section "SEC 07 — CloudTrail PutBucketPublicAccessBlock"

echo "Lấy CloudTrail PutBucketPublicAccessBlock event..."
aws cloudtrail lookup-events \
  --region "$REGION" \
  --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketPublicAccessBlock \
  --max-results 3 \
  --query "Events[*].{EventName:EventName,EventTime:EventTime,Username:Username}" \
  --output table

pause \
  "CloudTrail: Event history → Filter: PutBucketPublicAccessBlock → click event → thấy bucketName=geekbrain-kb-dev và userAgent chứa lambda" \
  "sec-07-cloudtrail-put-public-access-block.png"

# =============================================================================
# SEC 08/09/10 — KMS CMK
# =============================================================================

section "SEC 08/09/10 — KMS CMK Preventive Control"

pause \
  "KMS Console: KMS → Customer managed keys → key geekbrain-s3-kb-prod → Status=Enabled, Auto rotation=Enabled" \
  "sec-08-kms-cmk-overview.png"

pause \
  "S3 Console: S3 → geekbrain-kb-dev → Properties → Default encryption → SSE-KMS, Key=geekbrain-s3-kb-prod ARN" \
  "sec-09-s3-kms-encryption.png"

echo "Upload file test để trigger KMS GenerateDataKey..."
echo "kms-verify-$(date +%s)" | aws s3 cp - "s3://$KB_BUCKET/kms-verify.txt" --region "$REGION"
echo "   ✅ File uploaded"
echo ""
echo "Đợi 30 giây để CloudTrail ghi event..."
sleep 30

echo "CloudTrail GenerateDataKey events:"
aws cloudtrail lookup-events \
  --region "$REGION" \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GenerateDataKey \
  --max-results 3 \
  --query "Events[*].{EventName:EventName,EventTime:EventTime,Username:Username}" \
  --output table

pause \
  "CloudTrail: Event history → Filter GenerateDataKey → click event có userAgent chứa 's3' → thấy keyId=CMK ARN" \
  "sec-10-cloudtrail-kms-generate-data-key.png"

# =============================================================================
# OBS 01/02/03 — CloudWatch Dashboard & Custom Metrics
# =============================================================================

section "OBS 01/02/03 — Dashboard + Custom Metrics"

echo "Push custom metrics vào GeekBrain/Application..."
for i in {1..5}; do
  VALUE=$((150 + RANDOM % 300))
  aws cloudwatch put-metric-data \
    --region "$REGION" \
    --namespace "GeekBrain/Application" \
    --metric-name "BedrockQueryLatencyMs" \
    --dimensions Name=Service,Value=geekbrain-backend \
    --value "$VALUE" --unit Milliseconds
  aws cloudwatch put-metric-data \
    --region "$REGION" \
    --namespace "GeekBrain/Application" \
    --metric-name "KBSyncItemsCount" \
    --dimensions Name=Service,Value=geekbrain-backend \
    --value "$i" --unit Count
  echo "   [$i/5] BedrockQueryLatencyMs=$VALUE, KBSyncItemsCount=$i"
  sleep 5
done
echo "   ✅ Metrics pushed"

pause \
  "CloudWatch: Metrics → All metrics → search 'GeekBrain/Application' → thấy BedrockQueryLatencyMs + KBSyncItemsCount" \
  "obs-03-custom-metric-namespace.png"

pause \
  "CloudWatch: Dashboards → geekbrain-w6-ops → chụp toàn màn hình dashboard" \
  "obs-01-dashboard-full.png"

pause \
  "CloudWatch: Zoom widget 'Bedrock Query Latency' → thấy data points (không phải No data)" \
  "obs-02-custom-metric-widget.png"

# =============================================================================
# OBS 04/05/06 — Alarm ALARM → OK
# =============================================================================

section "OBS 04/05/06 — Alarm State Demo"

echo "Invoke Lambda 6 lần với force_error để trigger alarm..."
for i in {1..6}; do
  aws lambda invoke \
    --function-name "$KB_SYNC_FN" \
    --region "$REGION" \
    --cli-binary-format raw-in-base64-out \
    --payload '{"force_error": true}' \
    "$OUT_DIR/err_$i.json" 2>/dev/null || true
  echo "   [$i/6] Error invocation sent"
  sleep 5
done

echo ""
echo -e "${YELLOW}⏳ Đợi 2 phút để alarm chuyển ALARM...${NC}"
sleep 120

pause \
  "CloudWatch: Alarms → geekbrain-lambda-errors → State = IN ALARM (đỏ)" \
  "obs-04-alarm-in-ALARM-state.png"

echo -e "${YELLOW}⏳ Đợi thêm 6 phút để alarm về OK (không có error mới)...${NC}"
sleep 360

pause \
  "CloudWatch: Alarms → geekbrain-lambda-errors → State = OK (xanh)" \
  "obs-05-alarm-back-to-OK.png"

pause \
  "CloudWatch: Alarms → All alarms → không có alarm nào ở INSUFFICIENT_DATA" \
  "obs-06-all-alarms-no-insufficient-data.png"

# =============================================================================
# OBS 07/08/09 — Log Insights + Code Snippet
# =============================================================================

section "OBS 07/08/09 — Log Insights + Code"

pause \
  "CloudWatch: Logs Insights → Saved queries → thấy danh sách GeekBrain/... queries" \
  "obs-07-log-insights-saved-queries.png"

pause \
  "CloudWatch: Click GeekBrain/ECS-Error-Spikes → Run → thấy query text + ≥5 result rows" \
  "obs-08-log-insights-query-results.png"

pause \
  "VS Code / GitHub: Mở kb_auto_sync_lambda.py → zoom vào _put_metric() function" \
  "obs-09-putmetricdata-code-snippet.png"

# =============================================================================
# HOÀN THÀNH
# =============================================================================

section "✅ SCRIPT HOÀN THÀNH"

echo "Screenshots còn cần chụp THỦ CÔNG (không cần script):"
echo ""
echo "  MH-COST-V (chụp từ console):"
echo "    costv-01: Lambda Tags (4 keys)"
echo "    costv-02: S3 Tags (4 keys)"
echo "    costv-03: ECS Tags (4 keys)"
echo "    costv-04: Billing → Cost Allocation Tags → Owner+Application = Active"
echo "    costv-05: Budgets → geekbrain-w6-cost-cap config"
echo "    costv-06: Cost Explorer → Group by Tag:Application"
echo "    costv-07: Cost Explorer → Group by Service (baseline breakdown)"
echo ""
echo "  MH-COST-A manual (overview, không cần demo lại):"
echo "    costa-01: Lambda geekbrain-cost-guard-dev overview"
echo "    costa-02: IAM role policy"
echo "    costa-03: EventBridge schedule cron(0 20 * * ? *)"
echo ""
echo "  MH-SEC manual:"
echo "    sec-01: Lambda geekbrain-security-guard-dev overview"
echo "    sec-02: IAM role policy"
echo "    sec-03: EventBridge CloudTrail rule"
echo ""
echo "📁 Screenshots folder: $SCREENSHOT_DIR"
ls -1 "$SCREENSHOT_DIR" 2>/dev/null | wc -l | xargs echo "   Hiện có ảnh:"
