#!/usr/bin/env bash
# 练习 10 · 一次性基础设施：SA + WIF 池/provider + 权限绑定 + AR 仓库
# 用法：
#   PROJECT=lukechengtest REGION=us-central1 REPO_SLUG=lukecheng-csu/gcp-ops-labs bash scripts/setup-wif.sh
#
# 幂等：重复跑不会报错（已存在就跳过）。跑完会打印要填到 GitHub 的两个值。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PROJECT="${PROJECT:-lukechengtest}"
REGION="${REGION:-us-central1}"
REPO_SLUG="${REPO_SLUG:-lukecheng-csu/gcp-ops-labs}"
SA_NAME="${SA_NAME:-lab10-deployer}"
POOL="${POOL:-github-pool}"
PROVIDER="${PROVIDER:-github-provider}"
AR_REPO="${AR_REPO:-lab10}"

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "== 0. 取项目号 =="
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')"
echo "project=${PROJECT} number=${PROJECT_NUMBER}"

echo "== 1. 开必要的 API =="
gcloud services enable \
  run.googleapis.com artifactregistry.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com \
  --project="${PROJECT}" --quiet

echo "== 2. 建部署专用 SA（不用默认计算 SA）=="
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "  已存在：${SA_EMAIL}"
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="lab10 GitHub Actions deployer" --project="${PROJECT}"
fi

echo "== 3. 给 SA 最小权限（部署要的三条，别多给）=="
for ROLE in roles/run.admin roles/iam.serviceAccountUser roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${SA_EMAIL}" --role="${ROLE}" \
    --condition=None --quiet >/dev/null
  echo "  授予 ${ROLE}"
done

echo "== 4. WIF 池 =="
if gcloud iam workload-identity-pools describe "${POOL}" --location=global --project="${PROJECT}" >/dev/null 2>&1; then
  echo "  已存在：${POOL}"
else
  gcloud iam workload-identity-pools create "${POOL}" \
    --location=global --display-name="GitHub Actions" --project="${PROJECT}"
fi

echo "== 5. OIDC provider（限制只有你的仓库能换到凭证）=="
if gcloud iam workload-identity-pools providers describe "${PROVIDER}" \
     --workload-identity-pool="${POOL}" --location=global --project="${PROJECT}" >/dev/null 2>&1; then
  echo "  已存在：${PROVIDER}"
else
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER}" \
    --workload-identity-pool="${POOL}" --location=global --project="${PROJECT}" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository=='${REPO_SLUG}'"
fi

echo "== 6. 绑定：只允许 ${REPO_SLUG} 的 workflow 冒充这个 SA =="
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT}" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO_SLUG}" \
  --quiet >/dev/null
echo "  绑定完成"

echo "== 7. AR 仓库 =="
if gcloud artifacts repositories describe "${AR_REPO}" --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "  已存在：${AR_REPO}"
else
  gcloud artifacts repositories create "${AR_REPO}" \
    --repository-format=docker --location="${REGION}" --project="${PROJECT}"
fi

echo
echo "================ 填到 GitHub 的两个值 ================"
echo "Settings → Secrets and variables → Actions → New repository secret"
echo
echo "WIF_PROVIDER"
echo "  projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
echo
echo "WIF_SERVICE_ACCOUNT"
echo "  ${SA_EMAIL}"
echo "====================================================="
