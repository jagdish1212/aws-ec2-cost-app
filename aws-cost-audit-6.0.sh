#!/usr/bin/env bash  
  
###############################################################################  
# AWS COST INVENTORY AUDIT SCRIPT  
# Version: 6.1  
#  
# PURPOSE:  
#   Inventory AWS resources that MAY incur cost across all enabled regions.  
#   Pulls current-month aggregated costs from Cost Explorer.  
#  
# IMPORTANT:  
#   - This script DOES NOT calculate per-resource billing amounts  
#   - This is an INVENTORY AUDIT, not a billing attribution engine  
#   - Absence of resources here does NOT guarantee zero AWS charges  
#   - Services like Data Transfer, Support Plans, Marketplace, Tax,  
#     Route 53 queries, and others may still generate charges  
#  
# SAFETY:  
#   - Read-only AWS API calls only (list / describe / get)  
#   - No create, update, delete, or modify operations  
#   - Log file is restricted to owner-only permissions (chmod 600)  
#  
# NOTE ON set -e:  
#   'set -e' is intentionally omitted. Many AWS API calls may fail due to  
#   regional service availability, opt-in requirements, or IAM permission  
#   boundaries. Each command handles its own failure gracefully.  
#  
# USAGE:  
#   bash aws-cost-audit.sh                 # Scan all regions  
#   bash aws-cost-audit.sh us-east-1       # Scan single region  
#  
###############################################################################  
  
set -uo pipefail  
  
umask 077  
  
readonly LOG_FILE="aws-audit-$(date +%Y-%m-%d_%H%M%S).log"  
touch "$LOG_FILE"  
chmod 600 "$LOG_FILE"  
  
readonly START_TS=$(date +%s)  
  
readonly RED='\033[0;31m'  
readonly GREEN='\033[0;32m'  
readonly YELLOW='\033[1;33m'  
readonly BLUE='\033[0;34m'  
readonly CYAN='\033[0;36m'  
readonly BOLD='\033[1m'  
readonly NC='\033[0m'  
  
declare -A RESOURCE_REGIONS  
TOTAL_RESOURCE_TYPES=0  
  
# ── Findings collector ──────────────────────────────────────────────────────  
# All findings are stored here and printed together at the end  
FINDINGS=""  
COST_REPORT=""  
  
add_finding() {  
    local label="$1"  
    local detail="$2"  
    FINDINGS+="@@FINDING_START@@"  
    FINDINGS+="${RED}⚠️  ${label}${NC}"$'\n'  
    FINDINGS+="${detail}"$'\n'  
    FINDINGS+="@@FINDING_END@@"  
    TOTAL_RESOURCE_TYPES=$((TOTAL_RESOURCE_TYPES + 1))  
}  
  
# ── Progress tracking ───────────────────────────────────────────────────────  
CHECKS_PER_REGION=40  
GLOBAL_CHECKS=5  
TOTAL_CHECKS=0  
COMPLETED_CHECKS=0  
PROGRESS_BAR_WIDTH=40  
  
# ── Logging ─────────────────────────────────────────────────────────────────  
  
log_file() { echo -e "$1" >> "$LOG_FILE"; }  
log_both() { echo -e "$1" | tee -a "$LOG_FILE"; }  
  
# ── Progress bar ────────────────────────────────────────────────────────────  
  
update_progress() {  
    local label="$1"  
    COMPLETED_CHECKS=$((COMPLETED_CHECKS + 1))  
  
    local percent=0  
    if [ "$TOTAL_CHECKS" -gt 0 ]; then  
        percent=$((COMPLETED_CHECKS * 100 / TOTAL_CHECKS))  
    fi  
  
    local filled=$((percent * PROGRESS_BAR_WIDTH / 100))  
    local empty=$((PROGRESS_BAR_WIDTH - filled))  
  
    local bar=""  
    local i  
    for ((i = 0; i < filled; i++)); do bar+="█"; done  
    for ((i = 0; i < empty; i++)); do bar+="░"; done  
  
    printf "\r\033[K  ${CYAN}[%s] %3d%% (%d/%d)${NC} %s" "$bar" "$percent" "$COMPLETED_CHECKS" "$TOTAL_CHECKS" "$label" >&2  
  
    log_file "--- Checked: $label ---"  
}  
  
finish_progress() {  
    printf "\r\033[K" >&2  
}  
  
# ── Output parsing ──────────────────────────────────────────────────────────  
  
has_table_data() {  
    local out="$1"  
    [ -z "$out" ] && return 1  
    local data_lines  
    data_lines=$(echo "$out" | grep -c '^|' 2>/dev/null || echo "0")  
    [ "$data_lines" -gt 0 ]  
}  
  
has_text_data() {  
    local out="$1"  
    [ -z "$out" ] && return 1  
    [ "$out" = "None" ] && return 1  
    [ "$out" = "null" ] && return 1  
    local trimmed  
    trimmed=$(echo "$out" | tr -d '[:space:]')  
    [ -n "$trimmed" ]  
}  
  
# ── Check helpers (collect findings, don't print) ──────────────────────────  
  
check_table() {  
    local label="$1" out="$2" key="$3" region="$4"  
    if has_table_data "$out"; then  
        add_finding "$label in $region" "$out"  
        log_file "  ⚠️  FOUND: $label in $region"  
        log_file "$out"  
        RESOURCE_REGIONS["$key"]=$(( ${RESOURCE_REGIONS["$key"]:-0} + 1 ))  
    else  
        log_file "  ✅ None found: $label in $region"  
    fi  
}  
  
check_text() {  
    local label="$1" out="$2" key="$3" region="$4"  
    if has_text_data "$out"; then  
        add_finding "$label in $region" "$out"  
        log_file "  ⚠️  FOUND: $label in $region"  
        log_file "$out"  
        RESOURCE_REGIONS["$key"]=$(( ${RESOURCE_REGIONS["$key"]:-0} + 1 ))  
    else  
        log_file "  ✅ None found: $label in $region"  
    fi  
}  
  
# ── AWS CLI wrapper with retry ──────────────────────────────────────────────  
  
aws_retry() {  
    local max_attempts=3  
    local attempt=1  
    local result=""  
    local rc=0  
  
    while [ $attempt -le $max_attempts ]; do  
        result=$(aws "$@" 2>&1) && rc=0 || rc=$?  
  
        if echo "$result" | grep -qi "Throttling\|Rate exceeded\|RequestLimitExceeded"; then  
            local wait=$((attempt * 2))  
            sleep "$wait"  
            attempt=$((attempt + 1))  
        else  
            echo "$result"  
            return $rc  
        fi  
    done  
  
    echo "$result"  
    return $rc  
}  
  
###############################################################################  
# PRE-FLIGHT CHECKS  
###############################################################################  
  
preflight() {  
    log_both ""  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
    log_both "${BLUE}  AWS COST INVENTORY AUDIT v6.1${NC}"  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
    log_both ""  
  
    if ! command -v aws >/dev/null 2>&1; then  
        log_both "${RED}❌ AWS CLI is not installed.${NC}"  
        exit 1  
    fi  
    log_both "${GREEN}✅ AWS CLI:${NC} $(aws --version 2>&1)"  
  
    local id_json  
    if ! id_json=$(aws sts get-caller-identity --output json 2>&1); then  
        log_both "${RED}❌ AWS authentication failed. Run 'aws configure' first.${NC}"  
        exit 1  
    fi  
  
    local account arn  
    account=$(echo "$id_json" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)  
    arn=$(echo "$id_json" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)  
    log_both "${GREEN}✅ Account:${NC}  $account"  
    log_both "${GREEN}✅ Identity:${NC} $arn"  
  
    if aws ec2 describe-regions --query "Regions[0].RegionName" --output text >/dev/null 2>&1; then  
        log_both "${GREEN}✅ Permissions verified${NC}"  
    else  
        log_both "${YELLOW}⚠️  Limited permissions — some checks may fail${NC}"  
    fi  
  
    log_both ""  
    log_both "${YELLOW}⚠️  Log file contains sensitive AWS metadata. Do NOT share.${NC}"  
    log_both "📝 Log: $LOG_FILE (permissions: 600)"  
    log_both "⏱️  Started: $(date)"  
    log_both ""  
}  
  
###############################################################################  
# REGION ENUMERATION  
###############################################################################  
  
get_regions() {  
    local regions  
    if regions=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text 2>/dev/null); then  
        echo "$regions"  
    else  
        echo "us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-north-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-northeast-2 ap-south-1 sa-east-1 ca-central-1"  
    fi  
}  
  
###############################################################################  
# GLOBAL CHECKS  
###############################################################################  
  
check_global() {  
    local out  
  
    log_file ""  
    log_file "========== GLOBAL CHECKS =========="  
  
    # 1. Cost Explorer  
    update_progress "Cost Explorer"  
    local start_date end_date  
    start_date=$(date +%Y-%m-01)  
    end_date=$(date +%Y-%m-%d)  
    if [ "$start_date" != "$end_date" ]; then  
        out=$(aws_retry ce get-cost-and-usage --time-period "Start=${start_date},End=${end_date}" --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE --output table 2>&1) || out=""  
        if has_table_data "$out"; then  
            COST_REPORT="$out"  
            log_file "Cost Explorer data retrieved"  
            log_file "$out"  
        fi  
    fi  
  
    # 2. S3 Buckets  
    update_progress "S3 Buckets (global)"  
    out=$(aws_retry s3api list-buckets --query "Buckets[].[Name,CreationDate]" --output table 2>&1) || out=""  
    check_table "S3 Buckets" "$out" "S3 Buckets" "global"  
  
    # 3. Route 53  
    update_progress "Route 53 (global)"  
    out=$(aws_retry route53 list-hosted-zones --query "HostedZones[].[Name,Id,Config.PrivateZone]" --output table 2>&1) || out=""  
    check_table "Route 53 Hosted Zones" "$out" "Route53 Zones" "global"  
  
    # 4. IAM Users  
    update_progress "IAM Users (global)"  
    out=$(aws_retry iam list-users --query "Users[].[UserName,CreateDate,PasswordLastUsed]" --output table 2>&1) || out=""  
    check_table "IAM Users" "$out" "IAM Users" "global"  
  
    # 5. IAM Roles  
    update_progress "IAM Roles (global)"  
    out=$(aws_retry iam list-roles --query "Roles[?starts_with(RoleName,'aws-') == \`false\`].[RoleName,CreateDate]" --output table 2>&1) || out=""  
    check_table "IAM Roles" "$out" "IAM Roles" "global"  
}  
  
###############################################################################  
# PER-REGION SCAN  
###############################################################################  
  
scan_region() {  
    local r="$1"  
    local out  
  
    log_file ""  
    log_file "========== REGION: $r =========="  
  
    # ═══ COMPUTE ═══  
  
    update_progress "$r → EC2 Instances"  
    out=$(aws_retry ec2 describe-instances --region "$r" --filters "Name=instance-state-name,Values=running,stopped" --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key=='Name'].Value|[0]]" --output table 2>&1) || out=""  
    check_table "EC2 Instances" "$out" "EC2 Instances" "$r"  
  
    update_progress "$r → Lambda Functions"  
    out=$(aws_retry lambda list-functions --region "$r" --query "Functions[].[FunctionName,Runtime,MemorySize]" --output table 2>&1) || out=""  
    check_table "Lambda Functions" "$out" "Lambda Functions" "$r"  
  
    update_progress "$r → ECS Clusters"  
    out=$(aws_retry ecs list-clusters --region "$r" --query "clusterArns[]" --output text 2>&1) || out=""  
    check_text "ECS Clusters" "$out" "ECS Clusters" "$r"  
  
    update_progress "$r → EKS Clusters"  
    out=$(aws_retry eks list-clusters --region "$r" --query "clusters[]" --output text 2>&1) || out=""  
    check_text "EKS Clusters" "$out" "EKS Clusters" "$r"  
  
    update_progress "$r → Lightsail"  
    out=$(aws_retry lightsail get-instances --region "$r" --query "instances[].[name,blueprintId,state.name]" --output table 2>&1) || out=""  
    check_table "Lightsail Instances" "$out" "Lightsail" "$r"  
  
    update_progress "$r → SageMaker Endpoints"  
    out=$(aws_retry sagemaker list-endpoints --region "$r" --query "Endpoints[].[EndpointName,EndpointStatus]" --output table 2>&1) || out=""  
    check_table "SageMaker Endpoints" "$out" "SageMaker Endpoints" "$r"  
  
    update_progress "$r → SageMaker Notebooks"  
    out=$(aws_retry sagemaker list-notebook-instances --region "$r" --query "NotebookInstances[].[NotebookInstanceName,NotebookInstanceStatus,InstanceType]" --output table 2>&1) || out=""  
    check_table "SageMaker Notebooks" "$out" "SageMaker Notebooks" "$r"  
  
    update_progress "$r → EMR Clusters"  
    out=$(aws_retry emr list-clusters --region "$r" --active --query "Clusters[].[Id,Name,Status.State]" --output table 2>&1) || out=""  
    check_table "EMR Clusters" "$out" "EMR Clusters" "$r"  
  
    update_progress "$r → Glue Jobs"  
    out=$(aws_retry glue get-jobs --region "$r" --query "Jobs[].[Name,Command.Name]" --output table 2>&1) || out=""  
    check_table "Glue Jobs" "$out" "Glue Jobs" "$r"  
  
    update_progress "$r → WorkSpaces"  
    out=$(aws_retry workspaces describe-workspaces --region "$r" --query "Workspaces[].[WorkspaceId,BundleId,State]" --output table 2>&1) || out=""  
    check_table "WorkSpaces" "$out" "WorkSpaces" "$r"  
  
    # ═══ STORAGE ═══  
  
    update_progress "$r → EBS Volumes"  
    out=$(aws_retry ec2 describe-volumes --region "$r" --query "Volumes[].[VolumeId,Size,State,VolumeType,Attachments[0].InstanceId]" --output table 2>&1) || out=""  
    check_table "EBS Volumes" "$out" "EBS Volumes" "$r"  
  
    update_progress "$r → EBS Snapshots"  
    out=$(aws_retry ec2 describe-snapshots --region "$r" --owner-ids self --query "Snapshots[].[SnapshotId,VolumeSize,StartTime]" --output table 2>&1) || out=""  
    check_table "EBS Snapshots" "$out" "EBS Snapshots" "$r"  
  
    update_progress "$r → Custom AMIs"  
    out=$(aws_retry ec2 describe-images --region "$r" --owners self --query "Images[].[ImageId,Name,CreationDate]" --output table 2>&1) || out=""  
    check_table "Custom AMIs" "$out" "Custom AMIs" "$r"  
  
    update_progress "$r → ECR Repos"  
    out=$(aws_retry ecr describe-repositories --region "$r" --query "repositories[].[repositoryName,repositoryUri]" --output table 2>&1) || out=""  
    check_table "ECR Repositories" "$out" "ECR Repos" "$r"  
  
    update_progress "$r → EFS"  
    out=$(aws_retry efs describe-file-systems --region "$r" --query "FileSystems[].[FileSystemId,Name,SizeInBytes.Value,LifeCycleState]" --output table 2>&1) || out=""  
    check_table "EFS File Systems" "$out" "EFS" "$r"  
  
    update_progress "$r → FSx"  
    out=$(aws_retry fsx describe-file-systems --region "$r" --query "FileSystems[].[FileSystemId,FileSystemType,StorageCapacity,Lifecycle]" --output table 2>&1) || out=""  
    check_table "FSx File Systems" "$out" "FSx" "$r"  
  
    update_progress "$r → Backup Vaults"  
    out=$(aws_retry backup list-backup-vaults --region "$r" --query "BackupVaultList[].[BackupVaultName,NumberOfRecoveryPoints]" --output table 2>&1) || out=""  
    check_table "Backup Vaults" "$out" "Backup Vaults" "$r"  
  
    # ═══ DATABASES ═══  
  
    update_progress "$r → RDS Instances"  
    out=$(aws_retry rds describe-db-instances --region "$r" --query "DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,DBInstanceStatus]" --output table 2>&1) || out=""  
    check_table "RDS Instances" "$out" "RDS Instances" "$r"  
  
    update_progress "$r → RDS Snapshots"  
    out=$(aws_retry rds describe-db-snapshots --region "$r" --snapshot-type manual --query "DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,Status]" --output table 2>&1) || out=""  
    check_table "RDS Manual Snapshots" "$out" "RDS Snapshots" "$r"  
  
    update_progress "$r → Aurora Clusters"  
    out=$(aws_retry rds describe-db-clusters --region "$r" --query "DBClusters[].[DBClusterIdentifier,Engine,Status]" --output table 2>&1) || out=""  
    check_table "Aurora Clusters" "$out" "Aurora Clusters" "$r"  
  
    update_progress "$r → DynamoDB"  
    out=$(aws_retry dynamodb list-tables --region "$r" --query "TableNames[]" --output text 2>&1) || out=""  
    check_text "DynamoDB Tables" "$out" "DynamoDB" "$r"  
  
    update_progress "$r → ElastiCache"  
    out=$(aws_retry elasticache describe-cache-clusters --region "$r" --query "CacheClusters[].[CacheClusterId,CacheNodeType,Engine]" --output table 2>&1) || out=""  
    check_table "ElastiCache Clusters" "$out" "ElastiCache" "$r"  
  
    update_progress "$r → Redshift"  
    out=$(aws_retry redshift describe-clusters --region "$r" --query "Clusters[].[ClusterIdentifier,NodeType,ClusterStatus]" --output table 2>&1) || out=""  
    check_table "Redshift Clusters" "$out" "Redshift" "$r"  
  
    update_progress "$r → OpenSearch"  
    out=$(aws_retry opensearch list-domain-names --region "$r" --query "DomainNames[].[DomainName]" --output table 2>&1) || out=""  
    check_table "OpenSearch Domains" "$out" "OpenSearch" "$r"  
  
    update_progress "$r → Neptune"  
    out=$(aws_retry neptune describe-db-clusters --region "$r" --query "DBClusters[].[DBClusterIdentifier,Engine,Status]" --output table 2>&1) || out=""  
    check_table "Neptune Clusters" "$out" "Neptune" "$r"  
  
    update_progress "$r → DocumentDB"  
    out=$(aws_retry docdb describe-db-clusters --region "$r" --query "DBClusters[].[DBClusterIdentifier,Engine,Status]" --output table 2>&1) || out=""  
    check_table "DocumentDB Clusters" "$out" "DocumentDB" "$r"  
  
    update_progress "$r → MSK"  
    out=$(aws_retry kafka list-clusters --region "$r" --query "ClusterInfoList[].[ClusterName,State]" --output table 2>&1) || out=""  
    check_table "MSK Clusters" "$out" "MSK" "$r"  
  
    # ═══ NETWORKING ═══  
  
    update_progress "$r → Elastic IPs"  
    out=$(aws_retry ec2 describe-addresses --region "$r" --query "Addresses[].[PublicIp,InstanceId,AllocationId,AssociationId]" --output table 2>&1) || out=""  
    check_table "Elastic IPs" "$out" "Elastic IPs" "$r"  
  
    update_progress "$r → NAT Gateways"  
    out=$(aws_retry ec2 describe-nat-gateways --region "$r" --filter "Name=state,Values=available" --query "NatGateways[].[NatGatewayId,State,SubnetId]" --output table 2>&1) || out=""  
    check_table "NAT Gateways" "$out" "NAT Gateways" "$r"  
  
    update_progress "$r → ALB/NLB"  
    out=$(aws_retry elbv2 describe-load-balancers --region "$r" --query "LoadBalancers[].[LoadBalancerName,Type,State.Code]" --output table 2>&1) || out=""  
    check_table "Load Balancers (v2)" "$out" "ALB/NLB" "$r"  
  
    update_progress "$r → Classic LBs"  
    out=$(aws_retry elb describe-load-balancers --region "$r" --query "LoadBalancerDescriptions[].[LoadBalancerName,DNSName]" --output table 2>&1) || out=""  
    check_table "Classic Load Balancers" "$out" "Classic LBs" "$r"  
  
    update_progress "$r → VPC Endpoints"  
    out=$(aws_retry ec2 describe-vpc-endpoints --region "$r" --filters "Name=vpc-endpoint-type,Values=Interface" --query "VpcEndpoints[].[VpcEndpointId,ServiceName,State]" --output table 2>&1) || out=""  
    check_table "VPC Endpoints" "$out" "VPC Endpoints" "$r"  
  
    update_progress "$r → Transit Gateways"  
    out=$(aws_retry ec2 describe-transit-gateways --region "$r" --query "TransitGateways[].[TransitGatewayId,State]" --output table 2>&1) || out=""  
    check_table "Transit Gateways" "$out" "Transit GWs" "$r"  
  
    update_progress "$r → VPN Connections"  
    out=$(aws_retry ec2 describe-vpn-connections --region "$r" --filters "Name=state,Values=available" --query "VpnConnections[].[VpnConnectionId,State]" --output table 2>&1) || out=""  
    check_table "VPN Connections" "$out" "VPN Connections" "$r"  
  
    update_progress "$r → Global Accelerator"  
    if [ "$r" = "us-west-2" ]; then  
        out=$(aws_retry globalaccelerator list-accelerators --region "$r" --query "Accelerators[].[Name,Status,DnsName]" --output table 2>&1) || out=""  
        check_table "Global Accelerators" "$out" "Global Accelerator" "$r"  
    fi  
  
    update_progress "$r → Transfer Family"  
    out=$(aws_retry transfer list-servers --region "$r" --query "Servers[].[ServerId,State,EndpointType]" --output table 2>&1) || out=""  
    check_table "Transfer Family" "$out" "Transfer Family" "$r"  
  
    # ═══ MESSAGING ═══  
  
    update_progress "$r → SNS Topics"  
    out=$(aws_retry sns list-topics --region "$r" --query "Topics[].[TopicArn]" --output text 2>&1) || out=""  
    check_text "SNS Topics" "$out" "SNS Topics" "$r"  
  
    update_progress "$r → SQS Queues"  
    out=$(aws_retry sqs list-queues --region "$r" --output text 2>&1) || out=""  
    check_text "SQS Queues" "$out" "SQS Queues" "$r"  
  
    update_progress "$r → Kinesis Streams"  
    out=$(aws_retry kinesis list-streams --region "$r" --query "StreamNames[]" --output text 2>&1) || out=""  
    check_text "Kinesis Streams" "$out" "Kinesis Streams" "$r"  
  
    update_progress "$r → Firehose"  
    out=$(aws_retry firehose list-delivery-streams --region "$r" --query "DeliveryStreamNames[]" --output text 2>&1) || out=""  
    check_text "Firehose Streams" "$out" "Firehose" "$r"  
  
    # ═══ MONITORING & SECURITY ═══  
  
    update_progress "$r → CloudWatch Logs"  
    out=$(aws_retry logs describe-log-groups --region "$r" --query "logGroups[?storedBytes > \`0\`].[logGroupName,storedBytes,retentionInDays]" --output table 2>&1) || out=""  
    check_table "CloudWatch Log Groups" "$out" "CW Log Groups" "$r"  
  
    update_progress "$r → CloudWatch Alarms"  
    out=$(aws_retry cloudwatch describe-alarms --region "$r" --query "MetricAlarms[].[AlarmName,StateValue,MetricName]" --output table 2>&1) || out=""  
    check_table "CloudWatch Alarms" "$out" "CW Alarms" "$r"  
  
    update_progress "$r → Secrets Manager"  
    out=$(aws_retry secretsmanager list-secrets --region "$r" --query "SecretList[].[Name,CreatedDate]" --output table 2>&1) || out=""  
    check_table "Secrets Manager" "$out" "Secrets" "$r"  
  
    update_progress "$r → KMS Keys"  
    local kms_keys kms_found=false  
    kms_keys=$(aws_retry kms list-keys --region "$r" --query "Keys[].KeyId" --output text 2>&1) || kms_keys=""  
    if has_text_data "$kms_keys"; then  
        local kms_detail=""  
        for key_id in $kms_keys; do  
            local key_mgr  
            key_mgr=$(aws_retry kms describe-key --region "$r" --key-id "$key_id" --query "KeyMetadata.KeyManager" --output text 2>/dev/null) || key_mgr=""  
            if [ "$key_mgr" = "CUSTOMER" ]; then  
                kms_found=true  
                local key_state  
                key_state=$(aws_retry kms describe-key --region "$r" --key-id "$key_id" --query "KeyMetadata.KeyState" --output text 2>/dev/null) || key_state="unknown"  
                kms_detail+="    Key: $key_id  State: $key_state"$'\n'  
            fi  
        done  
        if [ "$kms_found" = true ]; then  
            add_finding "KMS Customer Keys in $r" "$kms_detail"  
            log_file "  ⚠️  FOUND: KMS Customer Keys in $r"  
            log_file "$kms_detail"  
            RESOURCE_REGIONS["KMS Keys"]=$(( ${RESOURCE_REGIONS["KMS Keys"]:-0} + 1 ))  
        fi  
    fi  
  
    update_progress "$r → AWS Config"  
    out=$(aws_retry configservice describe-configuration-recorders --region "$r" --query "ConfigurationRecorders[].[name,recordingGroup.allSupported]" --output table 2>&1) || out=""  
    check_table "Config Recorders" "$out" "AWS Config" "$r"  
  
    update_progress "$r → CloudFormation"  
    out=$(aws_retry cloudformation list-stacks --region "$r" --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE --query "StackSummaries[].[StackName,StackStatus,CreationTime]" --output table 2>&1) || out=""  
    check_table "CloudFormation Stacks" "$out" "CFN Stacks" "$r"  
  
    sleep 1  
}  
  
###############################################################################  
# PRINT ALL FINDINGS AT THE END  
###############################################################################  
  
print_findings() {  
    log_both ""  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
    log_both "${BLUE}       DETAILED FINDINGS                   ${NC}"  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
  
    # ── Cost report ─────────────────────────────────────────────────────────  
    if [ -n "$COST_REPORT" ]; then  
        log_both ""  
        log_both "${BOLD}📊 CURRENT MONTH COSTS (by service):${NC}"  
        log_both "$COST_REPORT"  
    fi  
  
    # ── Resource findings ───────────────────────────────────────────────────  
    if [ "$TOTAL_RESOURCE_TYPES" -gt 0 ]; then  
        log_both ""  
        log_both "${BOLD}🔍 RESOURCES FOUND:${NC}"  
        log_both ""  
  
        # Split findings by the delimiter and print each one  
        local finding_num=0  
        local IFS_OLD="$IFS"  
  
        # Replace delimiter with newline-based split  
        echo "$FINDINGS" | while IFS= read -r line; do  
            if [ "$line" = "@@FINDING_START@@" ]; then  
                finding_num=$((finding_num + 1))  
                echo "" | tee -a "$LOG_FILE"  
                printf "  ${BOLD}[%d]${NC} " "$finding_num" | tee -a "$LOG_FILE"  
            elif [ "$line" = "@@FINDING_END@@" ]; then  
                continue  
            else  
                echo -e "$line" | tee -a "$LOG_FILE"  
            fi  
        done  
    else  
        log_both ""  
        log_both "${GREEN}✅ No resources detected across $COMPLETED_CHECKS checks.${NC}"  
    fi  
}  
  
###############################################################################  
# SUMMARY  
###############################################################################  
  
print_summary() {  
    local end_ts duration minutes seconds  
    end_ts=$(date +%s)  
    duration=$((end_ts - START_TS))  
    minutes=$((duration / 60))  
    seconds=$((duration % 60))  
  
    log_both ""  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
    log_both "${BLUE}           AUDIT SUMMARY                  ${NC}"  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
    log_both ""  
    log_both "⏱️  Duration : ${minutes}m ${seconds}s"  
    log_both "📝 Log file : $LOG_FILE"  
    log_both "🔍 API calls: $COMPLETED_CHECKS"  
    log_both ""  
  
    if [ "$TOTAL_RESOURCE_TYPES" -gt 0 ]; then  
        log_both "${RED}⚠️  Total findings: $TOTAL_RESOURCE_TYPES${NC}"  
        log_both ""  
        log_both "${BOLD}Resource types found (by region count):${NC}"  
        log_both "──────────────────────────────────────────"  
        for k in $(echo "${!RESOURCE_REGIONS[@]}" | tr ' ' '\n' | sort); do  
            log_both "  ${YELLOW}▸ $k${NC} — ${RESOURCE_REGIONS[$k]} region(s)"  
        done  
    else  
        log_both "${GREEN}✅ No resources detected across $COMPLETED_CHECKS checks.${NC}"  
    fi  
  
    log_both ""  
    log_both "${YELLOW}⚠️  This does NOT guarantee zero AWS charges.${NC}"  
    log_both ""  
    log_both "${BOLD}Not checked:${NC} Data Transfer, Support Plans, Marketplace,"  
    log_both "  CloudFront, S3 storage size, Savings Plans, Tax, and others."  
    log_both ""  
    log_both "${BOLD}Next steps:${NC}"  
    log_both "  1. Review log    : ${CYAN}less $LOG_FILE${NC}"  
    log_both "  2. Cost Explorer : ${CYAN}https://console.aws.amazon.com/cost-management/home${NC}"  
    log_both "  3. AWS Budgets   : ${CYAN}https://console.aws.amazon.com/billing/home#/budgets${NC}"  
    log_both ""  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
    log_both "${BLUE}  Complete — $(date)${NC}"  
    log_both "${BLUE}══════════════════════════════════════════${NC}"  
}  
  
###############################################################################  
# MAIN  
###############################################################################  
  
main() {  
    preflight  
  
    local regions  
    if [ $# -gt 0 ]; then  
        regions="$*"  
        log_both "${CYAN}🎯 Scanning: $regions${NC}"  
    else  
        regions=$(get_regions)  
        log_both "${CYAN}🌐 Scanning all enabled regions${NC}"  
    fi  
  
    local total_regions  
    total_regions=$(echo "$regions" | wc -w | tr -d ' ')  
  
    TOTAL_CHECKS=$(( GLOBAL_CHECKS + (total_regions * CHECKS_PER_REGION) ))  
    log_both "${CYAN}   Regions: $total_regions | Checks: ~$TOTAL_CHECKS | Est: ~$((total_regions * 2))min${NC}"  
    log_both ""  
    log_both "${CYAN}Scanning...${NC}"  
  
    # Run all checks (progress bar shows during this)  
    check_global  
    for r in $regions; do  
        scan_region "$r"  
    done  
  
    # Clear progress bar  
    finish_progress  
  
    # Print everything found — all at the end  
    print_findings  
    print_summary  
}  
  
main "$@"  

