#!/usr/bin/env bash  
  
###############################################################################  
# AWS COST INVENTORY AUDIT SCRIPT  
# Version: 5.2.1  
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
  
# Restrict file creation to owner-only  
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
readonly NC='\033[0m'  
  
declare -A RESOURCE_REGIONS  
TOTAL_RESOURCE_TYPES=0  
TOTAL_SERVICES_CHECKED=0  
  
log() { echo -e "$1" | tee -a "$LOG_FILE"; }  
  
log_header() {  
    log ""  
    log "${BLUE}==========================================${NC}"  
    log "${BLUE}  $1${NC}"  
    log "${BLUE}==========================================${NC}"  
}  
  
log_section() {  
    log "${YELLOW}--- $1 ---${NC}"  
    TOTAL_SERVICES_CHECKED=$((TOTAL_SERVICES_CHECKED + 1))  
}  
  
log_found() {  
    log "${RED}  ⚠️  FOUND:${NC} $1"  
    TOTAL_RESOURCE_TYPES=$((TOTAL_RESOURCE_TYPES + 1))  
}  
  
log_clean() { log "${GREEN}  ✅ None found${NC}"; }  
  
log_skip() { log "${CYAN}  ⏭️  Skipped: $1${NC}"; }  
  
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
  
check_table() {  
    local label="$1" out="$2" key="$3" region="$4"  
    if has_table_data "$out"; then  
        log_found "$label in $region"  
        log "$out"  
        RESOURCE_REGIONS["$key"]=$(( ${RESOURCE_REGIONS["$key"]:-0} + 1 ))  
    else  
        log_clean  
    fi  
}  
  
check_text() {  
    local label="$1" out="$2" key="$3" region="$4"  
    if has_text_data "$out"; then  
        log_found "$label in $region"  
        log "$out"  
        RESOURCE_REGIONS["$key"]=$(( ${RESOURCE_REGIONS["$key"]:-0} + 1 ))  
    else  
        log_clean  
    fi  
}  
  
aws_retry() {  
    local max_attempts=3  
    local attempt=1  
    local result=""  
    local rc=0  
  
    while [ $attempt -le $max_attempts ]; do  
        result=$(aws "$@" 2>&1) && rc=0 || rc=$?  
  
        if echo "$result" | grep -qi "Throttling\|Rate exceeded\|RequestLimitExceeded"; then  
            local wait=$((attempt * 2))  
            log "${CYAN}  ⏳ API throttled, retrying in ${wait}s (attempt $attempt/$max_attempts)${NC}" >&2  
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
    log_header "PRE-FLIGHT CHECKS"  
  
    if ! command -v aws >/dev/null 2>&1; then  
        log "${RED}❌ AWS CLI is not installed.${NC}"  
        exit 1  
    fi  
    log "${GREEN}✅ AWS CLI:${NC} $(aws --version 2>&1)"  
  
    local id_json  
    if ! id_json=$(aws sts get-caller-identity --output json 2>&1); then  
        log "${RED}❌ AWS authentication failed. Run 'aws configure' first.${NC}"  
        log "   Error: $id_json"  
        exit 1  
    fi  
  
    local account arn  
    account=$(echo "$id_json" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)  
    arn=$(echo "$id_json" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)  
    log "${GREEN}✅ Account:${NC}  $account"  
    log "${GREEN}✅ Identity:${NC} $arn"  
  
    if aws ec2 describe-regions --query "Regions[0].RegionName" --output text >/dev/null 2>&1; then  
        log "${GREEN}✅ Basic EC2 permissions verified${NC}"  
    else  
        log "${YELLOW}⚠️  Limited permissions detected — some checks may fail${NC}"  
    fi  
  
    log ""  
    log "${YELLOW}⚠️  SECURITY NOTICE${NC}"  
    log "   The log file contains sensitive AWS metadata:"  
    log "   Account IDs, ARNs, IP addresses, resource names."  
    log "   File permissions: owner-only (600)"  
    log "   Do NOT share, email, or commit this file to source control."  
    log ""  
    log "📝 Log file : $LOG_FILE"  
    log "⏱️  Started  : $(date)"  
}  
  
###############################################################################  
# COST EXPLORER  
###############################################################################  
  
check_cost_explorer() {  
    log_header "CURRENT MONTH COSTS (AGGREGATED BY SERVICE)"  
    log "${CYAN}   Source: AWS Cost Explorer API (ce:GetCostAndUsage)${NC}"  
  
    local start_date end_date  
    start_date=$(date +%Y-%m-01)  
    end_date=$(date +%Y-%m-%d)  
  
    if [ "$start_date" = "$end_date" ]; then  
        log "${YELLOW}⚠️  First day of month — no cost data available yet${NC}"  
        return 0  
    fi  
  
    local out  
    if out=$(aws_retry ce get-cost-and-usage --time-period "Start=${start_date},End=${end_date}" --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE --output table 2>&1); then  
        if [ -n "$out" ]; then  
            log "$out"  
        else  
            log "${GREEN}✅ No costs reported for current month${NC}"  
        fi  
    else  
        log "${YELLOW}⚠️  Cost Explorer not enabled or permission denied${NC}"  
        log "   Enable at: https://console.aws.amazon.com/cost-management/home"  
    fi  
}  
  
###############################################################################  
# S3 — GLOBAL  
###############################################################################  
  
check_s3() {  
    log_header "S3 BUCKET INVENTORY (GLOBAL)"  
    log "${CYAN}   Note: Bucket names listed; storage size is NOT calculated${NC}"  
    log_section "S3 Buckets"  
  
    local out  
    out=$(aws_retry s3api list-buckets --query "Buckets[].[Name,CreationDate]" --output table 2>&1) || out=""  
    check_table "S3 Buckets" "$out" "S3 Buckets" "global"  
}  
  
###############################################################################  
# ROUTE 53 — GLOBAL  
###############################################################################  
  
check_route53() {  
    log_header "ROUTE 53 (GLOBAL)"  
    log_section "Route 53 Hosted Zones"  
  
    local out  
    out=$(aws_retry route53 list-hosted-zones --query "HostedZones[].[Name,Id,Config.PrivateZone]" --output table 2>&1) || out=""  
    check_table "Route 53 Hosted Zones" "$out" "Route53 Zones" "global"  
}  
  
###############################################################################  
# IAM — GLOBAL  
###############################################################################  
  
check_iam() {  
    log_header "IAM SUMMARY (GLOBAL — informational)"  
  
    log_section "IAM Users"  
    local out  
    out=$(aws_retry iam list-users --query "Users[].[UserName,CreateDate,PasswordLastUsed]" --output table 2>&1) || out=""  
    check_table "IAM Users" "$out" "IAM Users" "global"  
  
    log_section "IAM Roles (Customer-created)"  
    out=$(aws_retry iam list-roles --query "Roles[?starts_with(RoleName,'aws-') == \`false\`].[RoleName,CreateDate]" --output table 2>&1) || out=""  
    check_table "IAM Roles" "$out" "IAM Roles" "global"  
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
# PER-REGION SCAN  
###############################################################################  
  
scan_region() {  
    local r="$1"  
    local out  
  
    log_header "REGION: $r"  
  
    # ═══ COMPUTE ═══  
  
    log_section "EC2 Instances (Running/Stopped)"  
    out=$(aws_retry ec2 describe-instances --region "$r" --filters "Name=instance-state-name,Values=running,stopped" --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key=='Name'].Value|[0]]" --output table 2>&1) || out=""  
    check_table "EC2 Instances" "$out" "EC2 Instances" "$r"  
  
    log_section "Lambda Functions"  
    out=$(aws_retry lambda list-functions --region "$r" --query "Functions[].[FunctionName,Runtime,MemorySize]" --output table 2>&1) || out=""  
    check_table "Lambda Functions" "$out" "Lambda Functions" "$r"  
  
    log_section "ECS Clusters"  
    out=$(aws_retry ecs list-clusters --region "$r" --query "clusterArns[]" --output text 2>&1) || out=""  
    check_text "ECS Clusters" "$out" "ECS Clusters" "$r"  
  
    log_section "EKS Clusters"  
    out=$(aws_retry eks list-clusters --region "$r" --query "clusters[]" --output text 2>&1) || out=""  
    check_text "EKS Clusters" "$out" "EKS Clusters" "$r"  
  
    log_section "Lightsail Instances"  
    out=$(aws_retry lightsail get-instances --region "$r" --query "instances[].[name,blueprintId,state.name]" --output table 2>&1) || out=""  
    check_table "Lightsail Instances" "$out" "Lightsail" "$r"  
  
    log_section "SageMaker Endpoints"  
    out=$(aws_retry sagemaker list-endpoints --region "$r" --query "Endpoints[].[EndpointName,EndpointStatus]" --output table 2>&1) || out=""  
    check_table "SageMaker Endpoints" "$out" "SageMaker Endpoints" "$r"  
  
    log_section "SageMaker Notebook Instances"  
    out=$(aws_retry sagemaker list-notebook-instances --region "$r" --query "NotebookInstances[].[NotebookInstanceName,NotebookInstanceStatus,InstanceType]" --output table 2>&1) || out=""  
    check_table "SageMaker Notebooks" "$out" "SageMaker Notebooks" "$r"  
  
    log_section "EMR Clusters (Active)"  
    out=$(aws_retry emr list-clusters --region "$r" --active --query "Clusters[].[Id,Name,Status.State]" --output table 2>&1) || out=""  
    check_table "EMR Clusters" "$out" "EMR Clusters" "$r"  
  
    log_section "Glue Jobs"  
    out=$(aws_retry glue get-jobs --region "$r" --query "Jobs[].[Name,Command.Name]" --output table 2>&1) || out=""  
    check_table "Glue Jobs" "$out" "Glue Jobs" "$r"  
  
    log_section "WorkSpaces"  
    out=$(aws_retry workspaces describe-workspaces --region "$r" --query "Workspaces[].[WorkspaceId,BundleId,State]" --output table 2>&1) || out=""  
    check_table "WorkSpaces" "$out" "WorkSpaces" "$r"  
  
    # ═══ STORAGE ═══  
  
    log_section "EBS Volumes"  
    out=$(aws_retry ec2 describe-volumes --region "$r" --query "Volumes[].[VolumeId,Size,State,VolumeType,Attachments[0].InstanceId]" --output table 2>&1) || out=""  
    check_table "EBS Volumes" "$out" "EBS Volumes" "$r"  
  
    log_section "EBS Snapshots (Owned by you)"  
    out=$(aws_retry ec2 describe-snapshots --region "$r" --owner-ids self --query "Snapshots[].[SnapshotId,VolumeSize,StartTime]" --output table 2>&1) || out=""  
    check_table "EBS Snapshots" "$out" "EBS Snapshots" "$r"  
  
    log_section "Custom AMIs (Owned by you)"  
    out=$(aws_retry ec2 describe-images --region "$r" --owners self --query "Images[].[ImageId,Name,CreationDate]" --output table 2>&1) || out=""  
    check_table "Custom AMIs" "$out" "Custom AMIs" "$r"  
  
    log_section "ECR Repositories"  
    out=$(aws_retry ecr describe-repositories --region "$r" --query "repositories[].[repositoryName,repositoryUri]" --output table 2>&1) || out=""  
    check_table "ECR Repositories" "$out" "ECR Repos" "$r"  
  
    log_section "EFS File Systems"  
    out=$(aws_retry efs describe-file-systems --region "$r" --query "FileSystems[].[FileSystemId,Name,SizeInBytes.Value,LifeCycleState]" --output table 2>&1) || out=""  
    check_table "EFS File Systems" "$out" "EFS" "$r"  
  
    log_section "FSx File Systems"  
    out=$(aws_retry fsx describe-file-systems --region "$r" --query "FileSystems[].[FileSystemId,FileSystemType,StorageCapacity,Lifecycle]" --output table 2>&1) || out=""  
    check_table "FSx File Systems" "$out" "FSx" "$r"  
  
    log_section "AWS Backup Vaults"  
    out=$(aws_retry backup list-backup-vaults --region "$r" --query "BackupVaultList[].[BackupVaultName,NumberOfRecoveryPoints]" --output table 2>&1) || out=""  
    check_table "Backup Vaults" "$out" "Backup Vaults" "$r"  
  
    # ═══ DATABASES ═══  
  
    log_section "RDS Instances"  
    out=$(aws_retry rds describe-db-instances --region "$r" --query "DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,DBInstanceStatus]" --output table 2>&1) || out=""  
    check_table "RDS Instances" "$out" "RDS Instances" "$r"  
  
    log_section "RDS Manual Snapshots"  
    out=$(aws_retry rds describe-db-snapshots --region "$r" --snapshot-type manual --query "DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,Status]" --output table 2>&1) || out=""  
    check_table "RDS Manual Snapshots" "$out" "RDS Snapshots" "$r"  
  
    log_section "RDS Aurora Clusters"  
    out=$(aws_retry rds describe-db-clusters --region "$r" --query "DBClusters[].[DBClusterIdentifier,Engine,Status]" --output table 2>&1) || out=""  
    check_table "Aurora Clusters" "$out" "Aurora Clusters" "$r"  
  
    log_section "DynamoDB Tables"  
    out=$(aws_retry dynamodb list-tables --region "$r" --query "TableNames[]" --output text 2>&1) || out=""  
    check_text "DynamoDB Tables" "$out" "DynamoDB" "$r"  
  
    log_section "ElastiCache Clusters"  
    out=$(aws_retry elasticache describe-cache-clusters --region "$r" --query "CacheClusters[].[CacheClusterId,CacheNodeType,Engine]" --output table 2>&1) || out=""  
    check_table "ElastiCache Clusters" "$out" "ElastiCache" "$r"  
  
    log_section "Redshift Clusters"  
    out=$(aws_retry redshift describe-clusters --region "$r" --query "Clusters[].[ClusterIdentifier,NodeType,ClusterStatus]" --output table 2>&1) || out=""  
    check_table "Redshift Clusters" "$out" "Redshift" "$r"  
  
    log_section "OpenSearch Domains"  
    out=$(aws_retry opensearch list-domain-names --region "$r" --query "DomainNames[].[DomainName]" --output table 2>&1) || out=""  
    check_table "OpenSearch Domains" "$out" "OpenSearch" "$r"  
  
    log_section "Neptune Clusters"  
    out=$(aws_retry neptune describe-db-clusters --region "$r" --query "DBClusters[].[DBClusterIdentifier,Engine,Status]" --output table 2>&1) || out=""  
    check_table "Neptune Clusters" "$out" "Neptune" "$r"  
  
    log_section "DocumentDB Clusters"  
    out=$(aws_retry docdb describe-db-clusters --region "$r" --query "DBClusters[].[DBClusterIdentifier,Engine,Status]" --output table 2>&1) || out=""  
    check_table "DocumentDB Clusters" "$out" "DocumentDB" "$r"  
  
    log_section "MSK (Kafka) Clusters"  
    out=$(aws_retry kafka list-clusters --region "$r" --query "ClusterInfoList[].[ClusterName,State]" --output table 2>&1) || out=""  
    check_table "MSK Clusters" "$out" "MSK" "$r"  
  
    # ═══ NETWORKING ═══  
  
    log_section "Elastic IPs"  
    out=$(aws_retry ec2 describe-addresses --region "$r" --query "Addresses[].[PublicIp,InstanceId,AllocationId,AssociationId]" --output table 2>&1) || out=""  
    check_table "Elastic IPs" "$out" "Elastic IPs" "$r"  
  
    log_section "NAT Gateways"  
    out=$(aws_retry ec2 describe-nat-gateways --region "$r" --filter "Name=state,Values=available" --query "NatGateways[].[NatGatewayId,State,SubnetId]" --output table 2>&1) || out=""  
    check_table "NAT Gateways" "$out" "NAT Gateways" "$r"  
  
    log_section "Load Balancers (ALB/NLB)"  
    out=$(aws_retry elbv2 describe-load-balancers --region "$r" --query "LoadBalancers[].[LoadBalancerName,Type,State.Code]" --output table 2>&1) || out=""  
    check_table "Load Balancers (v2)" "$out" "ALB/NLB" "$r"  
  
    log_section "Classic Load Balancers"  
    out=$(aws_retry elb describe-load-balancers --region "$r" --query "LoadBalancerDescriptions[].[LoadBalancerName,DNSName]" --output table 2>&1) || out=""  
    check_table "Classic Load Balancers" "$out" "Classic LBs" "$r"  
  
    log_section "VPC Endpoints (Interface type — billed)"  
    out=$(aws_retry ec2 describe-vpc-endpoints --region "$r" --filters "Name=vpc-endpoint-type,Values=Interface" --query "VpcEndpoints[].[VpcEndpointId,ServiceName,State]" --output table 2>&1) || out=""  
    check_table "VPC Endpoints" "$out" "VPC Endpoints" "$r"  
  
    log_section "Transit Gateways"  
    out=$(aws_retry ec2 describe-transit-gateways --region "$r" --query "TransitGateways[].[TransitGatewayId,State]" --output table 2>&1) || out=""  
    check_table "Transit Gateways" "$out" "Transit GWs" "$r"  
  
    log_section "VPN Connections"  
    out=$(aws_retry ec2 describe-vpn-connections --region "$r" --filters "Name=state,Values=available" --query "VpnConnections[].[VpnConnectionId,State]" --output table 2>&1) || out=""  
    check_table "VPN Connections" "$out" "VPN Connections" "$r"  
  
    log_section "Global Accelerator"  
    if [ "$r" = "us-west-2" ]; then  
        out=$(aws_retry globalaccelerator list-accelerators --region "$r" --query "Accelerators[].[Name,Status,DnsName]" --output table 2>&1) || out=""  
        check_table "Global Accelerators" "$out" "Global Accelerator" "$r"  
    else  
        log_skip "Global Accelerator only checked in us-west-2"  
    fi  
  
    log_section "Transfer Family Servers (SFTP/FTPS)"  
    out=$(aws_retry transfer list-servers --region "$r" --query "Servers[].[ServerId,State,EndpointType]" --output table 2>&1) || out=""  
    check_table "Transfer Family" "$out" "Transfer Family" "$r"  
  
    # ═══ MESSAGING & STREAMING ═══  
  
    log_section "SNS Topics"  
    out=$(aws_retry sns list-topics --region "$r" --query "Topics[].[TopicArn]" --output text 2>&1) || out=""  
    check_text "SNS Topics" "$out" "SNS Topics" "$r"  
  
    log_section "SQS Queues"  
    out=$(aws_retry sqs list-queues --region "$r" --output text 2>&1) || out=""  
    check_text "SQS Queues" "$out" "SQS Queues" "$r"  
  
    log_section "Kinesis Data Streams"  
    out=$(aws_retry kinesis list-streams --region "$r" --query "StreamNames[]" --output text 2>&1) || out=""  
    check_text "Kinesis Streams" "$out" "Kinesis Streams" "$r"  
  
    log_section "Kinesis Firehose Delivery Streams"  
    out=$(aws_retry firehose list-delivery-streams --region "$r" --query "DeliveryStreamNames[]" --output text 2>&1) || out=""  
    check_text "Firehose Streams" "$out" "Firehose" "$r"  
  
    # ═══ MONITORING, LOGGING & SECURITY ═══  
  
    log_section "CloudWatch Log Groups (with stored data)"  
    out=$(aws_retry logs describe-log-groups --region "$r" --query "logGroups[?storedBytes > \`0\`].[logGroupName,storedBytes,retentionInDays]" --output table 2>&1) || out=""  
    check_table "CloudWatch Log Groups" "$out" "CW Log Groups" "$r"  
  
    log_section "CloudWatch Alarms"  
    out=$(aws_retry cloudwatch describe-alarms --region "$r" --query "MetricAlarms[].[AlarmName,StateValue,MetricName]" --output table 2>&1) || out=""  
    check_table "CloudWatch Alarms" "$out" "CW Alarms" "$r"  
  
    log_section "Secrets Manager Secrets"  
    out=$(aws_retry secretsmanager list-secrets --region "$r" --query "SecretList[].[Name,CreatedDate]" --output table 2>&1) || out=""  
    check_table "Secrets Manager" "$out" "Secrets" "$r"  
  
    log_section "KMS Customer Managed Keys"  
    local kms_keys kms_found=false  
    kms_keys=$(aws_retry kms list-keys --region "$r" --query "Keys[].KeyId" --output text 2>&1) || kms_keys=""  
  
    if has_text_data "$kms_keys"; then  
        for key_id in $kms_keys; do  
            local key_mgr  
            key_mgr=$(aws_retry kms describe-key --region "$r" --key-id "$key_id" --query "KeyMetadata.KeyManager" --output text 2>/dev/null) || key_mgr=""  
  
            if [ "$key_mgr" = "CUSTOMER" ]; then  
                if [ "$kms_found" = false ]; then  
                    log_found "KMS Customer Keys in $r"  
                    kms_found=true  
                    RESOURCE_REGIONS["KMS Keys"]=$(( ${RESOURCE_REGIONS["KMS Keys"]:-0} + 1 ))  
                fi  
                local key_state key_desc  
                key_state=$(aws_retry kms describe-key --region "$r" --key-id "$key_id" --query "KeyMetadata.KeyState" --output text 2>/dev/null) || key_state="unknown"  
                key_desc=$(aws_retry kms describe-key --region "$r" --key-id "$key_id" --query "KeyMetadata.Description" --output text 2>/dev/null) || key_desc=""  
                log "    Key: $key_id  State: $key_state  Desc: $key_desc"  
            fi  
        done  
    fi  
    if [ "$kms_found" = false ]; then  
        log_clean  
    fi  
  
    log_section "AWS Config Recorders"  
    out=$(aws_retry configservice describe-configuration-recorders --region "$r" --query "ConfigurationRecorders[].[name,recordingGroup.allSupported]" --output table 2>&1) || out=""  
    check_table "Config Recorders" "$out" "AWS Config" "$r"  
  
    # ═══ INFRASTRUCTURE AS CODE ═══  
  
    log_section "CloudFormation Stacks"  
    out=$(aws_retry cloudformation list-stacks --region "$r" --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE --query "StackSummaries[].[StackName,StackStatus,CreationTime]" --output table 2>&1) || out=""  
    check_table "CloudFormation Stacks" "$out" "CFN Stacks" "$r"  
  
    # Pause between regions to reduce throttle risk  
    sleep 1  
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
  
    log ""  
    log "${BLUE}══════════════════════════════════════════${NC}"  
    log "${BLUE}           AUDIT SUMMARY                  ${NC}"  
    log "${BLUE}══════════════════════════════════════════${NC}"  
    log ""  
    log "⏱️  Duration          : ${minutes}m ${seconds}s"  
    log "📝 Log file          : $LOG_FILE"  
    log "🔍 Service checks run: $TOTAL_SERVICES_CHECKED"  
    log ""  
  
    if [ "$TOTAL_RESOURCE_TYPES" -gt 0 ]; then  
        log "${RED}⚠️  Resource types detected: $TOTAL_RESOURCE_TYPES finding(s)${NC}"  
        log ""  
        log "Resources by type (region count):"  
        log "──────────────────────────────────"  
        for k in $(echo "${!RESOURCE_REGIONS[@]}" | tr ' ' '\n' | sort); do  
            log "  ${YELLOW}$k${NC}: present in ${RESOURCE_REGIONS[$k]} region(s)"  
        done  
    else  
        log "${GREEN}✅ No resources detected among the $TOTAL_SERVICES_CHECKED service checks.${NC}"  
    fi  
  
    log ""  
    log "${YELLOW}⚠️  This does NOT guarantee zero AWS charges.${NC}"  
    log ""  
    log "${BLUE}IMPORTANT LIMITATIONS${NC}"  
    log "──────────────────────────────────"  
    log "• This is an inventory audit, NOT a billing engine"  
    log "• Per-resource cost is NOT calculated"  
    log "• Services NOT checked include (but are not limited to):"  
    log "    - Data Transfer costs"  
    log "    - AWS Support plans"  
    log "    - AWS Marketplace subscriptions"  
    log "    - Route 53 query charges"  
    log "    - CloudFront distributions"  
    log "    - S3 storage size / request costs"  
    log "    - Savings Plans / Reserved Instance fees"  
    log "    - Tax"  
    log ""  
    log "${BLUE}RECOMMENDED NEXT STEPS${NC}"  
    log "──────────────────────────────────"  
    log "1. Review this log       : less $LOG_FILE"  
    log "2. Cost Explorer console : https://console.aws.amazon.com/cost-management/home"  
    log "3. Set up AWS Budgets    : https://console.aws.amazon.com/billing/home#/budgets"  
    log "4. Enable Cost Anomaly Detection"  
    log "5. Delete/stop unused resources identified above"  
    log ""  
    log "${BLUE}══════════════════════════════════════════${NC}"  
    log "${BLUE}  Audit complete — $(date)${NC}"  
    log "${BLUE}══════════════════════════════════════════${NC}"  
}  
  
###############################################################################  
# MAIN  
###############################################################################  
  
main() {  
    log_header "AWS COST INVENTORY AUDIT v5.2.1"  
    log "${CYAN}Comprehensive read-only resource scan${NC}"  
  
    preflight  
    check_cost_explorer  
    check_s3  
    check_route53  
    check_iam  
  
    local regions region_count=0  
    if [ $# -gt 0 ]; then  
        regions="$*"  
        log ""  
        log "${CYAN}🎯 Scanning specified region(s): $regions${NC}"  
    else  
        regions=$(get_regions)  
        log ""  
        log "${CYAN}🌐 Scanning all enabled regions${NC}"  
    fi  
  
    local total_regions  
    total_regions=$(echo "$regions" | wc -w | tr -d ' ')  
    log "${CYAN}   Regions to scan: $total_regions${NC}"  
    log "${CYAN}   Estimated time : ~$((total_regions * 2)) minutes${NC}"  
    log ""  
  
    for r in $regions; do  
        region_count=$((region_count + 1))  
        log ""  
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"  
        log "${BLUE}  [$region_count/$total_regions] Scanning: $r${NC}"  
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"  
        scan_region "$r"  
    done  
  
    print_summary  
}  
  
main "$@"  

