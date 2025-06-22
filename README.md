# Climate FactCheck AWS 배포 가이드

이 문서는 Climate FactCheck 애플리케이션을 AWS에 EC2 기반으로 배포하는 방법을 설명합니다. CloudFormation을 사용하여 Infrastructure as Code (IaC) 방식으로 안전하고 재현 가능한 배포를 제공합니다.

## 🏗️ 아키텍처 개요

```
┌────────────────────────────────────────────────┐
│                   인터넷                        │
└─────────────────────┬──────────────────────────┘
                      │
                ┌─────▼─────┐
                │    ALB    │
                │  (Public) │
                └─────┬─────┘
                      │
      ┌───────────────▼─────────────────┐
      │              VPC                │
      │ ┌─────────────────────────────┐ │
      │ │       Public Subnet         │ │  
      │ │  ┌─────┐  ┌─────────────┐   │ │
      │ │  │ ALB │  │   Bastion   │   │ │
      │ │  └─────┘  └─────────────┘   │ │
      │ └─────────────────────────────┘ │
      │ ┌─────────────────────────────┐ │
      │ │       Private Subnet        │ │
      │ │ ┌─────────────────────────┐ │ │
      │ │ │    App EC2 Instances    │ │ │
      │ │ │   (Auto Scaling)        │ │ │
      │ │ │    - Backend API        │ │ │
      │ │ │    - Docker Containers  │ │ │
      │ │ └─────────────────────────┘ │ │
      │ │ ┌─────────────────────────┐ │ │
      │ │ │   Database EC2          │ │ │
      │ │ │  - PostgreSQL(Docker)   │ │ │
      │ │ │  - Redis(Docker)        │ │ │
      │ │ │  - EBS Volume(Data)     │ │ │
      │ │ └─────────────────────────┘ │ │
      │ └─────────────────────────────┘ │
      └─────────────────────────────────┘
```

## 🚀 주요 구성 요소

### 네트워킹
- **VPC**: 격리된 네트워크 환경 (10.0.0.0/16)
- **Public Subnets**: ALB 및 Bastion 호스트 배치용 (Multi-AZ)
- **Private Subnets**: 애플리케이션 및 데이터베이스 EC2 배치용 (Multi-AZ)
- **NAT Gateway**: 프라이빗 서브넷의 아웃바운드 인터넷 액세스
- **보안 그룹**: 최소 권한 원칙에 따른 네트워크 액세스 제어

### 컴퓨팅
- **애플리케이션 EC2 인스턴스**: Docker로 백엔드 API 실행 (Auto Scaling)
- **데이터베이스 EC2 인스턴스**: PostgreSQL + Redis Docker 컨테이너
- **Application Load Balancer**: HTTP/HTTPS 트래픽 분산
- **Auto Scaling**: CPU 기반 자동 스케일링
- **Bastion Host**: 프라이빗 서브넷 관리용 접근점

### 데이터베이스 (EC2 기반)
- **PostgreSQL**: Docker 컨테이너로 실행
- **Redis**: Vector Search 지원하는 Redis Stack Server
- **EBS 볼륨**: 데이터 영속성 보장 (암호화)

### 보안
- **AWS Secrets Manager**: 민감 정보 안전 저장
- **IAM 역할**: 최소 권한 원칙
- **VPC 보안 그룹**: 네트워크 레벨 보안
- **EBS 암호화**: 데이터 암호화

### 모니터링 & 알림
- **CloudWatch**: EC2, ALB, Auto Scaling 메트릭 수집
- **SNS**: 알람 알림
- **CloudWatch 대시보드**: 시각화
- **로그 모니터링**: 애플리케이션 에러 추적

### CI/CD
- **CodePipeline**: 배포 파이프라인
- **CodeBuild**: Docker 이미지 빌드
- **CodeDeploy**: EC2 Auto Scaling Group 배포
- **ECR**: 컨테이너 이미지 저장소

## 📋 사전 준비사항

### 1. AWS CLI 설치 및 설정
```bash
# AWS CLI 설치
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# AWS 자격증명 설정
aws configure
```

### 2. Docker 설치
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install docker.io

# 사용자를 docker 그룹에 추가
sudo usermod -aG docker $USER
```

### 3. EC2 키페어 생성
```bash
# 키페어 생성
aws ec2 create-key-pair --key-name my-climate-key --query 'KeyMaterial' --output text > my-climate-key.pem
chmod 400 my-climate-key.pem
```

### 4. Git 설정
```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

## 🛠️ 배포 방법

### 1. 빠른 배포 (권장)
```bash
# 실행 권한 부여
chmod +x deploy.sh

# Production 환경으로 배포
./deploy.sh production ap-northeast-2 my-climate-key

# Development 환경으로 배포
./deploy.sh development ap-northeast-2 my-dev-key
```

### 2. 수동 배포
```bash
# 메인 인프라 스택 배포
aws cloudformation create-stack \
  --stack-name climate-factcheck-production-main \
  --template-body file://cloudformation/main-ec2.yml \
  --parameters ParameterKey=Environment,ParameterValue=production ParameterKey=KeyPairName,ParameterValue=my-climate-key \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --region ap-northeast-2

# 스택 생성 완료 대기
aws cloudformation wait stack-create-complete \
  --stack-name climate-factcheck-production-main \
  --region ap-northeast-2
```

## ⚙️ 환경별 설정

### Development
- **애플리케이션 EC2**: t3.medium, 1개 인스턴스
- **데이터베이스 EC2**: t3.small, Single-AZ
- **EBS 볼륨**: 20GB
- **Auto Scaling**: 최소 1, 최대 3

### Production
- **애플리케이션 EC2**: t3.medium, 2개 인스턴스
- **데이터베이스 EC2**: t3.small, 고가용성 설정
- **EBS 볼륨**: 100GB
- **Auto Scaling**: 최소 2, 최대 6

## 🔐 보안 설정

### 1. Secrets Manager 설정
배포 후 다음 시크릿을 업데이트해야 합니다:

```bash
# 애플리케이션 시크릿 업데이트
aws secretsmanager update-secret \
  --secret-id production/climate-factcheck/application \
  --secret-string '{
    "SECRET_KEY": "your-secret-key-here",
    "OPENAI_API_KEY": "sk-...",
    "BRAVE_AI_API_KEY": "your-brave-key",
    "GOOGLE_API_KEY": "your-google-key",
    "POSTGRES_PASSWORD": "your-postgres-password",
    "REDIS_PASSWORD": "your-redis-password"
  }'
```

### 2. SSH 접근
```bash
# Bastion 호스트를 통한 접근
ssh -i my-climate-key.pem ec2-user@<bastion-public-ip>

# 데이터베이스 서버 접근 (Bastion에서)
ssh ec2-user@<database-private-ip>

# PostgreSQL 접근
docker exec -it postgres psql -U imfact_user -d imfact

# Redis 접근
docker exec -it redis redis-cli -a <redis-password>
```

## 📊 모니터링 설정

### CloudWatch 대시보드
배포 완료 후 CloudWatch 콘솔에서 다음 대시보드에 액세스할 수 있습니다:
- `production-climate-factcheck-dashboard`

### 주요 모니터링 메트릭
- **ALB**: 요청 수, 응답 시간, 에러율
- **애플리케이션 EC2**: CPU, 메모리, 네트워크
- **데이터베이스 EC2**: CPU, 디스크, 네트워크
- **Auto Scaling**: 인스턴스 수, 스케일링 이벤트

### 알람 설정
다음 알람이 자동으로 설정됩니다:
- ALB 높은 응답 시간 (>2초)
- ALB 5XX 에러율 (>10개/5분)
- EC2 높은 CPU 사용률 (>80%)
- 데이터베이스 EC2 높은 디스크 사용률 (>85%)
- 헬스체크 실패
- Auto Scaling 인스턴스 시작 실패

## 🔄 애플리케이션 배포

### 자동 배포 (CI/CD)
GitHub에 코드 푸시 시 자동으로 배포됩니다:
1. CodePipeline이 GitHub 변경사항 감지
2. CodeBuild가 Docker 이미지 빌드 및 ECR 푸시
3. CodeDeploy가 Auto Scaling Group의 인스턴스 교체

### 수동 배포
```bash
# ECR 로그인
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.ap-northeast-2.amazonaws.com

# 이미지 빌드 및 푸시
cd backend
docker build -t climate-factcheck:latest .
docker tag climate-factcheck:latest <ecr-repo>:latest
docker push <ecr-repo>:latest

# 인스턴스 교체 트리거
aws autoscaling start-instance-refresh --auto-scaling-group-name production-climate-factcheck-asg
```

## 🚨 트러블슈팅

### 일반적인 문제들

#### 1. 스택 생성 실패
```bash
# 스택 이벤트 확인
aws cloudformation describe-stack-events \
  --stack-name climate-factcheck-production-main

# 키페어 문제
aws ec2 describe-key-pairs --key-names my-climate-key
```

#### 2. 애플리케이션 연결 실패
```bash
# 애플리케이션 로그 확인
aws logs get-log-events \
  --log-group-name /aws/ec2/climate-factcheck \
  --log-stream-name application

# 인스턴스 상태 확인
aws ec2 describe-instances --filters "Name=tag:Name,Values=*climate-factcheck-app*"
```

#### 3. 데이터베이스 연결 문제
```bash
# 데이터베이스 서버 SSH 접근
ssh -i my-climate-key.pem ec2-user@<bastion-ip>
ssh ec2-user@<database-private-ip>

# PostgreSQL 컨테이너 상태 확인
docker ps
docker logs postgres

# Redis 컨테이너 상태 확인
docker logs redis
```

#### 4. Auto Scaling 문제
```bash
# Auto Scaling 이벤트 확인
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name production-climate-factcheck-asg

# Launch Template 확인
aws ec2 describe-launch-templates
```

### 로그 확인
```bash
# 애플리케이션 로그
aws logs filter-log-events \
  --log-group-name /aws/ec2/climate-factcheck \
  --start-time $(date -d '1 hour ago' +%s)000

# 시스템 로그 (EC2)
sudo journalctl -u climate-factcheck -f
```

## 🧹 정리 (Clean Up)

### 스택 삭제
```bash
# 역순으로 삭제 (CI/CD -> 모니터링 -> 메인)
aws cloudformation delete-stack --stack-name climate-factcheck-production-cicd
aws cloudformation delete-stack --stack-name climate-factcheck-production-monitoring
aws cloudformation delete-stack --stack-name climate-factcheck-production-main

# EBS 스냅샷 확인 및 삭제
aws ec2 describe-snapshots --owner-ids self
aws ec2 delete-snapshot --snapshot-id snap-xxxxxxxx

# S3 버킷 수동 삭제
aws s3 rm s3://production-climate-factcheck-artifacts-123456789012 --recursive
aws s3 rb s3://production-climate-factcheck-artifacts-123456789012
```

## 💰 비용 최적화

### Development 환경
- Spot 인스턴스 사용 가능
- 야간/주말 자동 종료 스케줄링
- 최소 리소스 할당
- EBS 볼륨 크기 최적화

### Production 환경
- Reserved Instance 고려
- CloudWatch 로그 보존 기간 최적화
- 불필요한 EBS 스냅샷 정리
- Auto Scaling 정책 최적화

## 🔧 운영 가이드

### 정기 유지보수
```bash
# Docker 이미지 정리 (각 EC2에서)
docker system prune -f

# EBS 스냅샷 생성 (백업)
aws ec2 create-snapshot --volume-id vol-xxxxxxxx --description "Manual backup"

# 로그 파일 로테이션 확인
sudo logrotate -d /etc/logrotate.conf
```

### 스케일링 조정
```bash
# Auto Scaling 정책 업데이트
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name production-climate-factcheck-asg \
  --desired-capacity 3
```

## 📚 추가 참고 자료

- [AWS EC2 모범 사례](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-best-practices.html)
- [Auto Scaling 사용자 가이드](https://docs.aws.amazon.com/autoscaling/ec2/userguide/)
- [CloudFormation 템플릿 참조](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-reference.html)
- [AWS Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/)

## 🆘 지원

문제가 발생하면 다음을 확인하세요:
1. CloudFormation 이벤트 로그
2. EC2 인스턴스 시스템 로그
3. 애플리케이션 Docker 컨테이너 로그
4. CloudWatch 메트릭 및 알람
5. 보안 그룹 및 네트워크 설정
6. 이 README의 트러블슈팅 섹션 
