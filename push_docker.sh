#!/bin/bash
set -e

# Region and Repository Name
REGION="ap-southeast-1"
REPO_NAME="xrestaurant-backend"

# Fetch AWS Account ID dynamically
ACCOUNT_ID=$(aws sts get-caller-identity --region $REGION --query Account --output text)
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "=================================================="
echo "🚀 ĐĂNG NHẬP VÀO AMAZON ECR"
echo "=================================================="
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URL

echo "=================================================="
echo "🐳 BUILD DOCKER IMAGE"
echo "=================================================="
cd 5XRestaurant/server
docker build -t $REPO_NAME .

echo "=================================================="
echo "🏷️ GẮN TAG CHO IMAGE"
echo "=================================================="
docker tag $REPO_NAME:latest $ECR_URL/$REPO_NAME:latest

echo "=================================================="
echo "☁️ PUSH IMAGE LÊN ECR"
echo "=================================================="
docker push $ECR_URL/$REPO_NAME:latest

echo "=================================================="
echo "✅ HOÀN TẤT!"
echo "=================================================="
