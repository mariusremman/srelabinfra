using 'main.bicep'

// Verdier hentes fra miljøvariabler satt av workflowen, med fornuftige standarder lokalt.
param namePrefix = readEnvironmentVariable('NAME_PREFIX', 'srelab')
param environmentName = readEnvironmentVariable('ENVIRONMENT_NAME', 'dev')
param location = readEnvironmentVariable('AZURE_LOCATION', 'swedencentral')
param containerImage = readEnvironmentVariable('CONTAINER_IMAGE', '')
param containerPort = int(readEnvironmentVariable('CONTAINER_PORT', '8080'))
param healthProbePath = readEnvironmentVariable('HEALTH_PROBE_PATH', '/')
param postgresAdminPassword = readEnvironmentVariable('POSTGRES_ADMIN_PASSWORD')
