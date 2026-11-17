using './main.bicep'

// Values come from environment variables set by scripts/deploy.ps1 so that the
// client IP, object ID, and generated password never land in a committed file.
param location = readEnvironmentVariable('LAB_LOCATION', 'centralus')
param clientIp = readEnvironmentVariable('LAB_CLIENT_IP')
param userObjectId = readEnvironmentVariable('LAB_USER_OBJECT_ID')
param sqlAdminPassword = readEnvironmentVariable('LAB_SQL_ADMIN_PASSWORD')
param deploySparkPool = bool(readEnvironmentVariable('LAB_DEPLOY_SPARK', 'false'))
param deployBudget = bool(readEnvironmentVariable('LAB_DEPLOY_BUDGET', 'true'))

// Synapse Git integration (D9). Committed on purpose: the repo is public, so owner/repo are not secret.
param gitAccountName = 'ryanosborne142980-cpu'
param gitRepositoryName = 'medallion-synapse-lab'
