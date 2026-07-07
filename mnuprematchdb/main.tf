terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  # Your configured remote backend vault
  backend "azurerm" {
    resource_group_name  = "rg-terraform-backend"
    storage_account_name = "samanutdtfstate2307" 
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# 1. The main Resource Group for your dashboard
resource "azurerm_resource_group" "rg" {
  name     = "rg-manutd-dashboard-prod"
  location = "centralindia"
}

# Generate random text for unique storage naming
resource "random_id" "suffix" {
  byte_length = 4
}

# 2. Storage Account for the Function App & Azure Tables
resource "azurerm_storage_account" "sa" {
  name                     = "samanutddash${random_id.suffix.hex}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# 3. The App Service Plan (Free/Consumption Tier)
resource "azurerm_service_plan" "asp" {
  name                = "asp-manutd-function"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Windows"
  sku_name            = "Y1"
}

# 4. The PowerShell Azure Function App
resource "azurerm_windows_function_app" "func" {
  name                       = "func-manutd-datafetcher-2307"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key
  service_plan_id            = azurerm_service_plan.asp.id

  site_config {
    application_stack {
      powershell_core_version = "7.2"
    }
  }

  app_settings = {
    # We will inject the API key via DevOps later so it isn't hardcoded in GitHub
    "API_FOOTBALL_KEY" = "" 
  }
}

# 5. The Frontend Hosting (Static Web App)
resource "azurerm_static_web_app" "swa" {
  name                = "swa-manutd-frontend"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "eastasia" # Required region for Static Web Apps
  sku_tier            = "Free"
  sku_size            = "Free"
}