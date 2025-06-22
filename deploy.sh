#!/bin/bash

# Climate FactCheck AWS 배포 스크립트 (EC2 기반)
# 사용법: ./deploy.sh [environment] [region] [key-pair-name]

set -e

# 기본값 설정
ENVIRONMENT=${1:-production}
REGION=${2:-ap-northeast-2}
KEY_PAIR=${3:-my-key-pair}
STACK_PREFIX="climate-factcheck"

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🌍 Climate FactCheck AWS 배포 시작 (EC2 기반)${NC}"
echo "환경: $ENVIRONMENT"
echo "리전: $REGION"
echo "키페어: $KEY_PAIR"
echo "스택 접두사: $STACK_PREFIX"
echo "========================================"

# AWS CLI 설정 확인
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI가 설치되지 않았습니다${NC}"
    exit 1
fi

# AWS 인증 확인
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS 인증이 설정되지 않았습니다${NC}"
    exit 1
fi

# 키페어 존재 확인
if ! aws ec2 describe-key-pairs --key-names $KEY_PAIR --region $REGION &> /dev/null; then
    echo -e "${RED}❌ 키페어 '$KEY_PAIR'가 존재하지 않습니다. 먼저 키페어를 생성하세요.${NC}"
    echo "키페어 생성 명령어: aws ec2 create-key-pair --key-name $KEY_PAIR --query 'KeyMaterial' --output text > $KEY_PAIR.pem"
    exit 1
fi

# 배포 함수
deploy_stack() {
    local stack_name=$1
    local template_file=$2
    local parameters_file=$3
    
    echo -e "${YELLOW}📦 $stack_name 스택 배포 중...${NC}"
    
    # 스택 존재 여부 확인
    if aws cloudformation describe-stacks --stack-name $stack_name --region $REGION &> /dev/null; then
        echo "기존 스택 업데이트 중..."
        aws cloudformation update-stack \
            --stack-name $stack_name \
            --template-body file://$template_file \
            --parameters file://$parameters_file \
            --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
            --region $REGION
        
        echo "스택 업데이트 완료 대기 중..."
        aws cloudformation wait stack-update-complete \
            --stack-name $stack_name \
            --region $REGION
    else
        echo "새 스택 생성 중..."
        aws cloudformation create-stack \
            --stack-name $stack_name \
            --template-body file://$template_file \
            --parameters file://$parameters_file \
            --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
            --region $REGION
        
        echo "스택 생성 완료 대기 중..."
        aws cloudformation wait stack-create-complete \
            --stack-name $stack_name \
            --region $REGION
    fi
    
    echo -e "${GREEN}✅ $stack_name 스택 배포 완료${NC}"
}

# 매개변수 파일 생성
create_main_parameters_file() {
    local env=$1
    local params_file="cloudformation/parameters-main-${env}.json"
    
    cat > $params_file << EOF
[
  {
    "ParameterKey": "Environment",
    "ParameterValue": "$env"
  },
  {
    "ParameterKey": "KeyPairName",
    "ParameterValue": "$KEY_PAIR"
  }
]
EOF
    
    echo $params_file
}

# 스택 출력값 가져오기
get_stack_output() {
    local stack_name=$1
    local output_key=$2
    
    aws cloudformation describe-stacks \
        --stack-name $stack_name \
        --region $REGION \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text
}

# ECR 로그인 함수
ecr_login() {
    echo -e "${YELLOW}🔐 ECR 로그인 중...${NC}"
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.$REGION.amazonaws.com
}

# Docker 이미지 빌드 및 푸시
build_and_push_image() {
    local ecr_repo=$1
    
    echo -e "${YELLOW}🔨 Docker 이미지 빌드 중...${NC}"
    cd ../backend
    docker build -t climate-factcheck:latest .
    
    # 이미지 태깅
    docker tag climate-factcheck:latest $ecr_repo:latest
    docker tag climate-factcheck:latest $ecr_repo:$(git rev-parse --short HEAD)
    
    echo -e "${YELLOW}📤 ECR에 이미지 푸시 중...${NC}"
    docker push $ecr_repo:latest
    docker push $ecr_repo:$(git rev-parse --short HEAD)
    
    cd ../infrastructure
    echo -e "${GREEN}✅ 이미지 푸시 완료${NC}"
}

# 메인 배포 로직
main() {
    # 매개변수 파일 생성
    MAIN_PARAMS_FILE=$(create_main_parameters_file $ENVIRONMENT)
    
    # 1. 메인 인프라 스택 배포 (EC2 기반)
    echo -e "${YELLOW}📋 Step 1: EC2 기반 메인 인프라 배포${NC}"
    deploy_stack "${STACK_PREFIX}-${ENVIRONMENT}-main" \
                 "cloudformation/main.yml" \
                 $MAIN_PARAMS_FILE
    
    # ECR 리포지토리 URI 가져오기
    ECR_REPO=$(get_stack_output "${STACK_PREFIX}-${ENVIRONMENT}-main" "ECRRepository")
    echo "ECR 리포지토리: $ECR_REPO"
    
    # 2. Docker 이미지 빌드 및 푸시
    if [ "$ECR_REPO" != "" ]; then
        ecr_login
        build_and_push_image $ECR_REPO
    else
        echo -e "${RED}❌ ECR 리포지토리 URI를 가져올 수 없습니다${NC}"
        exit 1
    fi
    
    # 3. 스택 출력값들 가져오기
    AUTO_SCALING_GROUP=$(get_stack_output "${STACK_PREFIX}-${ENVIRONMENT}-main" "AutoScalingGroupName")
    DATABASE_INSTANCE_ID=$(get_stack_output "${STACK_PREFIX}-${ENVIRONMENT}-main" "DatabaseServerIP")
    LOAD_BALANCER_URL=$(get_stack_output "${STACK_PREFIX}-${ENVIRONMENT}-main" "LoadBalancerURL")
    
    # ALB와 Target Group 이름 동적으로 가져오기 (실제 배포에서는 추가 로직 필요)
    ALB_NAME="${ENVIRONMENT}-climate-factcheck-alb"
    TG_NAME="${ENVIRONMENT}-climate-factcheck-tg"
    
    echo -e "${YELLOW}📋 Step 2: 모니터링 스택 배포${NC}"
    # 모니터링 스택용 매개변수 파일 생성
    MONITORING_PARAMS="cloudformation/parameters-monitoring-${ENVIRONMENT}.json"
    cat > $MONITORING_PARAMS << EOF
[
  {
    "ParameterKey": "Environment",
    "ParameterValue": "$ENVIRONMENT"
  },
  {
    "ParameterKey": "AutoScalingGroupName",
    "ParameterValue": "$AUTO_SCALING_GROUP"
  },
  {
    "ParameterKey": "LoadBalancerFullName",
    "ParameterValue": "app/$ALB_NAME/1234567890123456"
  },
  {
    "ParameterKey": "TargetGroupFullName",
    "ParameterValue": "targetgroup/$TG_NAME/1234567890123456"
  },
  {
    "ParameterKey": "DatabaseInstanceId",
    "ParameterValue": "$DATABASE_INSTANCE_ID"
  },
  {
    "ParameterKey": "NotificationEmail",
    "ParameterValue": "admin@example.com"
  }
]
EOF
    
    deploy_stack "${STACK_PREFIX}-${ENVIRONMENT}-monitoring" \
                 "cloudformation/monitoring.yml" \
                 $MONITORING_PARAMS
    
    # 4. CI/CD 스택 배포
    echo -e "${YELLOW}📋 Step 3: CI/CD 스택 배포${NC}"
    CICD_PARAMS="cloudformation/parameters-cicd-${ENVIRONMENT}.json"
    cat > $CICD_PARAMS << EOF
[
  {
    "ParameterKey": "Environment",
    "ParameterValue": "$ENVIRONMENT"
  },
  {
    "ParameterKey": "AutoScalingGroupName",
    "ParameterValue": "$AUTO_SCALING_GROUP"
  },
  {
    "ParameterKey": "GitHubOwner",
    "ParameterValue": "your-github-username"
  },
  {
    "ParameterKey": "GitHubRepo",
    "ParameterValue": "climate-factcheck"
  },
  {
    "ParameterKey": "GitHubBranch",
    "ParameterValue": "main"
  }
]
EOF
    
    deploy_stack "${STACK_PREFIX}-${ENVIRONMENT}-cicd" \
                 "cloudformation/ci-cd.yml" \
                 $CICD_PARAMS
    
    # 5. 배포 완료 정보 출력
    echo -e "${GREEN}🎉 EC2 기반 배포 완료!${NC}"
    echo "========================================"
    
    # 주요 출력값들 표시
    DATABASE_SERVER_IP=$(get_stack_output "${STACK_PREFIX}-${ENVIRONMENT}-main" "DatabaseServerIP")
    BASTION_INSTANCE_ID=$(get_stack_output "${STACK_PREFIX}-${ENVIRONMENT}-main" "BastionInstanceId")
    
    echo "🌐 애플리케이션 URL: $LOAD_BALANCER_URL"
    echo "🗄️ 데이터베이스 서버 IP: $DATABASE_SERVER_IP"
    echo "🔧 Bastion 호스트 ID: $BASTION_INSTANCE_ID"
    echo "📊 CloudWatch 대시보드: AWS 콘솔에서 확인"
    echo "🚀 Auto Scaling Group: $AUTO_SCALING_GROUP"
    
    echo ""
    echo -e "${YELLOW}⚠️ 중요 설정 사항:${NC}"
    echo "1. Secrets Manager에서 API 키들을 실제 값으로 업데이트하세요:"
    echo "   aws secretsmanager update-secret --secret-id $ENVIRONMENT/climate-factcheck/application --secret-string '{\"SECRET_KEY\":\"your-key\",\"OPENAI_API_KEY\":\"sk-...\"}'"
    echo ""
    echo "2. GitHub 토큰을 Secrets Manager에 설정하세요:"
    echo "   aws secretsmanager update-secret --secret-id $ENVIRONMENT/climate-factcheck/github-webhook --secret-string '{\"token\":\"your-github-token\"}'"
    echo ""
    echo "3. Bastion 호스트를 통한 데이터베이스 접근:"
    echo "   ssh -i $KEY_PAIR.pem ec2-user@<bastion-public-ip>"
    echo "   ssh <database-private-ip>  # Bastion에서 실행"
    echo ""
    echo "4. 모니터링 이메일 주소를 확인하세요"
    echo ""
    echo "5. 애플리케이션 배포는 인스턴스 교체 방식으로 이루어집니다"
    
    # 임시 파일 정리
    rm -f $MAIN_PARAMS_FILE $MONITORING_PARAMS $CICD_PARAMS
}

# 도움말 출력
show_help() {
    echo "사용법: $0 [environment] [region] [key-pair-name]"
    echo ""
    echo "매개변수:"
    echo "  environment     배포 환경 (development|staging|production) [기본값: production]"
    echo "  region         AWS 리전 [기본값: ap-northeast-2]"
    echo "  key-pair-name  EC2 키페어 이름 [기본값: my-key-pair]"
    echo ""
    echo "예시:"
    echo "  $0 production ap-northeast-2 my-production-key"
    echo "  $0 development us-west-2 my-dev-key"
    echo ""
    echo "사전 준비사항:"
    echo "1. AWS CLI 설치 및 설정"
    echo "2. Docker 설치"
    echo "3. EC2 키페어 생성"
    echo "4. 적절한 AWS IAM 권한"
}

# 매개변수 검증
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    show_help
    exit 0
fi

# 스크립트 실행
main 
