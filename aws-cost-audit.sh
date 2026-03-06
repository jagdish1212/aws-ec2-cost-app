#!/usr/bin/env bash  
  
###############################################  
# AWS Full Cost Audit Script v5.0  
# Fixed: All commands on single lines  
# Usage: bash aws-cost-audit.sh  
###############################################  
  
set -uo pipefail  
  
readonly LOG_FILE="aws-audit-$(date +%Y-%m-%d_%H%M%S).log"  
readonly TIMESTAMP_START=$(date +%s)  
readonly RED='\033[0;31m'  
readonly GREEN='\033[0;32m'  
readonly YELLOW='\033[1;33m'  
readonly BLUE='\033[0;34m'  
readonly NC='\033[0m'  
  
declare -A RESOURCE_COUNT  
TOTAL_ISSUES=0  
  
log() { echo -e "$1" | tee -a "$LOG_FILE"; }  
  
log_header() {  
    log ""  
    log "${BLUE}==========================================${NC}"  
    log "${BLUE}  $1${NC}"  
    log "${BLUE}==========================================${NC}"  
}  
  
log_section() { log "${YELLOW}--- $1 ---${NC}"; }  
  
log_found() {  
    log "${RED}  ⚠️  FOUND: $1${NC}"  
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))  
}  
  
log_clean() { log "${GREEN}  ✅ None found${NC}"; }  
  
has_data() {  
    local output="$1"  
    [ -z "$output" ] && return 1  
    local count  
    count=$(echo "$output" | grep -c '|' 2>/dev/null || echo "0")  
    [ "$count" -gt 1 ] && return 0  
    return 1  
}  
  
check() {  
    local label="$1"  
    local result="$2"  
    local resource_key="$3"  
    local region="$4"  
  
    if has_data "$result"; then  
        log_found "$label in $region"  
        log "$result"  
        RESOURCE_COUNT["$resource_key"]=$(( ${RESOURCE_COUNT["$resource_key"]:-0} + 1 ))  
    else  
        log_clean  
    fi  
}  
  
check_text() {  
    local label="$1"  
    local result="$2"  
    local resource_key="$3"  
    local region="$4"  
  
    if [ -n "$result" ] && [ "$result" != "None" ]; then  
        log_found "$label in $region"  
        log "$result"  
        RESOURCE_COUNT["$resource_key"]=$(( ${RESOURCE_COUNT["$resource_key"]:-0} + 1 ))  
    else  
        log_clean  
    fi  
}  
  
preflight_checks() {  
    log_header "PRE-FLIGHT CHECKS"  
  
    if ! command -v aws &>/dev/null; then  
        log "${RED}❌ AWS CLI is not installed.${NC}"  
        exit 1  
    fi  
    log "${GREEN}✅ AWS CLI found: $(aws --version 2>&1)${NC}"  
  
    local identity  
    if identity=$(aws sts get-caller-identity --output json 2>&1); then  
        local account arn  
        account=$(echo "$identity" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)  
        arn=$(echo "$identity" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)  
        log "${GREEN}✅ Authenticated as: $arn${NC}"  
        log "${GREEN}   Account: $account${NC}"  
    else  
        log "${RED}❌ Not authenticated. Run 'aws configure' first.${NC}"  
        exit 1  
    fi  
  
    if aws ec2 describe-regions --query "Regions[0].RegionName" --output text &>/dev/null; then  
        log "${GREEN}✅ Basic permissions verified${NC}"  
    else  
        log "${YELLOW}⚠️  Limited permissions detected.${NC}"  
    fi  
  
    log ""  
    log "📝 Logging to: $LOG_FILE"  
    log "⏱️  Started at: $(date)"  
}  
  
get_regions() {  
    local regions  
    if regions=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text 2>&1); then  
        echo "$regions"  
    else  
        echo "us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-north-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-northeast-2 ap-northeast-3 ap-south-1 sa-east-1 ca-central-1"  
    fi  
}  
  
check_cost_explorer() {  
    log_header "CURRENT MONTH COSTS (Cost Explorer)"  
  
    local start_date end_date  
    start_date=$(date +%Y-%m-01)  
    end_date=$(date +%Y-%m-%d)  
  
    if [ "$start_date" = "$end_date" ]; then  
        log "${YELLOW}⚠️  First day of month — no cost data yet.${NC}"  
        return 0  
    fi  
  
    local result  
    if result=$(aws ce get-cost-and-usage --time-period "Start=${start_date},End=${end_date}" --granularity MONTHLY --metrics "UnblendedCost" --group-by Type=DIMENSION,Key=SERVICE --output table 2>&1); then  
        if [ -n "$result" ]; then  
            log "$result"  
        else  
            log "${GREEN}✅ No costs found for current month${NC}"  
        fi  
    else  
        log "${YELLOW}⚠️  Cost Explorer not enabled or no permission.${NC}"  
        log "   Error: $result"  
    fi  
}  
  
check_s3() {  
    log_header "S3 BUCKETS (Global)"  
  
    local result  
    if result=$(aws s3api list-buckets --query "Buckets[].[Name,CreationDate]" --output table 2>&1); then  
        if has_data "$result"; then  
            log_found "S3 Buckets"  
            log "$result"  
        else  
            log_clean  
        fi  
    else  
        log "${YELLOW}⚠️  Could not list S3 buckets${NC}"  
    fi  
}  
  
scan_region() {  
    local r="$1"  
    local result  
  
    log_header "REGION: $r"  
  
    # ===== COMPUTE =====  
  
    log_section "EC2 Instances (Running/Stopped)"  
    result=$(aws ec2 describe-instances --region "$r" --filters "Name=instance-state-name,Values=running,stopped" --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key=='Name'].Value|[0]]" --output table 2>&1) || result=""  
    check "EC2 Instances" "$result" "EC2 Instances" "$r"  
  
    log_section "Lambda Functions"  
    result=$(aws lambda list-functions --region "$r" --query "Functions[].[FunctionName,Runtime,MemorySize]" --output table 2>&1) || result=""  
    check "Lambda Functions" "$result" "Lambda Functions" "$r"  
  
    log_section "ECS Clusters"  
    result=$(aws ecs list-clusters --region "$r" --query "clusterArns[]" --output text 2>&1) || result=""  
    check_text "ECS Clusters" "$result" "ECS Clusters" "$r"  
  
    log_section "EKS Clusters"  
    result=$(aws eks list-clusters --region "$r" --query "clusters[]" --output text 2>&1) || result=""  
    check_text "EKS Clusters" "$result" "EKS Clusters" "$r"  
  
    log_section "Lightsail Instances"  
    result=$(aws lightsail get-instances --region "$r" --query "instances[].[name,blueprintId,state.name]" --output table 2>&1) || result=""  
    check "Lightsail Instances" "$result" "Lightsail" "$r"  
  
    log_section "SageMaker Endpoints"  
    result=$(aws sagemaker list-endpoints --region "$r" --query "Endpoints[].[EndpointName,EndpointStatus]" --output table 2>&1) || result=""  
    check "SageMaker Endpoints" "$result" "SageMaker" "$r"  
  
    # ===== STORAGE =====  
  
    log_section "EBS Volumes"  
    result=$(aws ec2 describe-volumes --region "$r" --query "Volumes[].[VolumeId,Size,State,VolumeType,Attachments[0].InstanceId]" --output table 2>&1) || result=""  
    check "EBS Volumes" "$result" "EBS Volumes" "$r"  
  
    log_section "EBS Snapshots (Owned by you)"  
    result=$(aws ec2 describe-snapshots --region "$r" --owner-ids self --query "Snapshots[].[SnapshotId,VolumeSize,StartTime]" --output table 2>&1) || result=""  
    check "EBS Snapshots" "$result" "EBS Snapshots" "$r"  
  
    log_section "Custom AMIs"  
    result=$(aws ec2 describe-images --region "$r" --owners self --query "Images[].[ImageId,Name,CreationDate]" --output table 2>&1) || result=""  
    check "Custom AMIs" "$result" "Custom AMIs" "$r"  
  
    log_section "ECR Repositories"  
    result=$(aws ecr describe-repositories --region "$r" --query "repositories[].[repositoryName,repositoryUri]" --output table 2>&1) || result=""  
    check "ECR Repositories" "$result" "ECR Repos" "$r"  
  
    # ===== DATABASES =====  
  
    log_section "RDS Instances"  
    result=$(aws rds describe-db-instances --region "$r" --query "DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,DBInstanceStatus]" --output table 2>&1) || result=""  
    check "RDS Instances" "$result" "RDS Instances" "$r"  
  
    log_section "RDS Manual Snapshots"  
    result=$(aws rds describe-db-snapshots --region "$r" --snapshot-type manual --query "DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,Status]" --output table 2>&1) || result=""  
    check "RDS Manual Snapshots" "$result" "RDS Snapshots" "$r"  
  
    log_section "DynamoDB Tables"  
    result=$(aws dynamodb list-tables --region "$r" --query "TableNames[]" --output text 2>&1) || result=""  
    check_text "DynamoDB Tables" "$result" "DynamoDB" "$r"  
  
    log_section "ElastiCache Clusters"  
    result=$(aws elasticache describe-cache-clusters --region "$r" --query "CacheClusters[].[CacheClusterId,CacheNodeType,Engine]" --output table 2>&1) || result=""  
    check "ElastiCache Clusters" "$result" "ElastiCache" "$r"  
  
    log_section "Redshift Clusters"  
    result=$(aws redshift describe-clusters --region "$r" --query "Clusters[].[ClusterIdentifier,NodeType,ClusterStatus]" --output table 2>&1) || result=""  
    check "Redshift Clusters" "$result" "Redshift" "$r"  
  
    log_section "OpenSearch Domains"  
    result=$(aws opensearch list-domain-names --region "$r" --query "DomainNames[].[DomainName]" --output table 2>&1) || result=""  
    check "OpenSearch Domains" "$result" "OpenSearch" "$r"  
  
    # ===== NETWORKING =====  
  
    log_section "Elastic IPs"  
    result=$(aws ec2 describe-addresses --region "$r" --query "Addresses[].[PublicIp,InstanceId,AllocationId,AssociationId]" --output table 2>&1) || result=""  
    check "Elastic IPs" "$result" "Elastic IPs" "$r"  
  
    log_section "NAT Gateways"  
    result=$(aws ec2 describe-nat-gateways --region "$r" --filter "Name=state,Values=available" --query "NatGateways[].[NatGatewayId,State,SubnetId]" --output table 2>&1) || result=""  
    check "NAT Gateways" "$result" "NAT Gateways" "$r"  
  
    log_section "Load Balancers (ALB/NLB)"  
    result=$(aws elbv2 describe-load-balancers --region "$r" --query "LoadBalancers[].[LoadBalancerName,Type,State.Code]" --output table 2>&1) || result=""  
    check "Load Balancers" "$result" "Load Balancers" "$r"  
  
    log_section "Classic Load Balancers"  
    result=$(aws elb describe-load-balancers --region "$r" --query "LoadBalancerDescriptions[].[LoadBalancerName,DNSName]" --output table 2>&1) || result=""  
    check "Classic Load Balancers" "$result" "Classic LBs" "$r"  
  
    log_section "VPC Endpoints (Interface type)"  
    result=$(aws ec2 describe-vpc-endpoints --region "$r" --filters "Name=vpc-endpoint-type,Values=Interface" --query "VpcEndpoints[].[VpcEndpointId,ServiceName,State]" --output table 2>&1) || result=""  
    check "VPC Endpoints" "$result" "VPC Endpoints" "$r"  
  
    log_section "Transit Gateways"  
    result=$(aws ec2 describe-transit-gateways --region "$r" --query "TransitGateways[].[TransitGatewayId,State]" --output table 2>&1) || result=""  
    check "Transit Gateways" "$result" "Transit GWs" "$r"  
  
    log_section "VPN Connections"  
    result=$(aws ec2 describe-vpn-connections --region "$r" --filters "Name=state,Values=available" --query "VpnConnections[].[VpnConnectionId,State]" --output table 2>&1) || result=""  
    check "VPN Connections" "$result" "VPN Connections" "$r"  
  
    # ===== MESSAGING =====  
  
    log_section "SNS Topics"  
    result=$(aws sns list-topics --region "$r" --query "Topics[].[TopicArn]" --output text 2>&1) || result=""  
    check_text "SNS Topics" "$result" "SNS Topics" "$r"  
  
    log_section "SQS Queues"  
    result=$(aws sqs list-queues --region "$r" --output text 2>&1) || result=""  
    check_text "SQS Queues" "$result" "SQS Queues" "$r"  
  
    log_section "Kinesis Streams"  
    result=$(aws kinesis list-streams --region "$r" --query "StreamNames[]" --output text 2>&1) || result=""  
    check_text "Kinesis Streams" "$result" "Kinesis" "$r"  
  
    # ===== MONITORING & SECURITY =====  
  
    log_section "CloudWatch Log Groups (with stored data)"  
    result=$(aws logs describe-log-groups --region "$r" --query "logGroups[?storedBytes > \`0\`].[logGroupName,storedBytes,retentionInDays]" --output table 2>&1) || result=""  
    check "CloudWatch Log Groups" "$result" "CW Logs" "$r"  
  
    log_section "Secrets Manager"  
    result=$(aws secretsmanager list-secrets --region "$r" --query "SecretList[].[Name,CreatedDate]" --output table 2>&1) || result=""  
    check "Secrets Manager" "$result" "Secrets" "$r"  
  
    log_section "KMS Customer Managed Keys"  
    local kms_keys kms_found=false  
    kms_keys=$(aws kms list-keys --region "$r" --query "Keys[].KeyId" --output text 2>&1) || kms_keys=""  
    if [ -n "$kms_keys" ] && [ "$kms_keys" != "None" ]; then  
        for key_id in $kms_keys; do  
            local key_mgr  
            key_mgr=$(aws kms describe-key --region "$r" --key-id "$key_id" --query "KeyMetadata.KeyManager" --output text 2>/dev/null) || key_mgr=""  
            if [ "$key_mgr" = "CUSTOMER" ]; then  
                if [ "$kms_found" = false ]; then  
                    log_found "KMS Customer Keys in $r"  
                    kms_found=true  
                    RESOURCE_COUNT["KMS Keys"]=$(( ${RESOURCE_COUNT["KMS Keys"]:-0} + 1 ))  
                fi  
                local key_state  
                key_state=$(aws kms describe-key --region "$r" --key-id "$key_id" --query "KeyMetadata.KeyState" --output text 2>/dev/null) || key_state="unknown"  
                log "  Key: $key_id  State: $key_state"  
            fi  
        done  
    fi  
    if [ "$kms_found" = false ]; then  
        log_clean  
    fi  
  
    # ===== INFRASTRUCTURE =====  
  
    log_section "CloudFormation Stacks"  
    result=$(aws cloudformation list-stacks --region "$r" --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE --query "StackSummaries[].[StackName,StackStatus,CreationTime]" --output table 2>&1) || result=""  
    check "CloudFormation Stacks" "$result" "CFN Stacks" "$r"  
}  
  
print_summary() {  
    local timestamp_end duration minutes seconds  
    timestamp_end=$(date +%s)  
    duration=$(( timestamp_end - TIMESTAMP_START ))  
    minutes=$(( duration / 60 ))  
    seconds=$(( duration % 60 ))  
  
    log ""  
    log "${BLUE}==========================================${NC}"  
    log "${BLUE}           AUDIT SUMMARY                  ${NC}"  
    log "${BLUE}==========================================${NC}"  
    log ""  
    log "⏱️  Duration: ${minutes}m ${seconds}s"  
    log "📝 Log file: $LOG_FILE"  
    log ""  
  
    if [ "$TOTAL_ISSUES" -gt 0 ]; then  
        log "${RED}⚠️  Total resource types found: $TOTAL_ISSUES${NC}"  
        log ""  
        log "Resources found by type:"  
        log "------------------------"  
        for resource in "${!RESOURCE_COUNT[@]}"; do  
            log "${YELLOW}  $resource: ${RESOURCE_COUNT[$resource]} region(s)${NC}"  
        done  
    else  
        log "${GREEN}✅ No chargeable resources found! Your account looks clean.${NC}"  
    fi  
  
    log ""  
    log "${BLUE}==========================================${NC}"  
    log "${BLUE}  RECOMMENDED NEXT STEPS                  ${NC}"  
    log "${BLUE}==========================================${NC}"  
    log ""  
    log "1. Review log: less $LOG_FILE"  
    log "2. Cost Explorer: https://console.aws.amazon.com/cost-management/home"  
    log "3. Delete unwanted resources"  
    log "4. Set up Budgets: https://console.aws.amazon.com/billing/home#/budgets"  
    log ""  
}  
  
main() {  
    log_header "AWS FULL COST AUDIT v5.0"  
    log "Date: $(date)"  
  
    preflight_checks  
    check_cost_explorer  
    check_s3  
  
    log_header "FETCHING ENABLED REGIONS"  
    local regions region_count current  
    regions=$(get_regions)  
    region_count=$(echo "$regions" | wc -w | tr -d ' ')  
    log "Found $region_count regions to scan"  
  
    current=0  
    for region in $regions; do  
        current=$((current + 1))  
        log ""  
        log "${BLUE}[$current/$region_count] Scanning $region...${NC}"  
        scan_region "$region"  
    done  
  
    print_summary  
}  
  
main "$@"  
