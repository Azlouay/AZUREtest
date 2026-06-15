provider "azurerm" {
  features {}
  subscription_id = "084283ec-176d-4aef-94a0-a447bc2240a9"
}

# Create resource group
resource "azurerm_resource_group" "main" {
  name     = "app-sql-infra"
  location = "francecentral"
}

# Generate random suffix for unique resource names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Virtual Networks
resource "azurerm_virtual_network" "app_vnet" {
  name                = "app-vnet-${random_string.suffix.result}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_virtual_network" "sql_vnet" {
  name                = "sql-vnet-${random_string.suffix.result}"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# Subnets for App VNet
resource "azurerm_subnet" "fw_subnet" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.app_vnet.name
  address_prefixes     = ["10.0.100.0/24"]
}

resource "azurerm_subnet" "fw_management_subnet" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.app_vnet.name
  address_prefixes     = ["10.0.101.0/26"]  # /26 is required for management subnet
}

resource "azurerm_subnet" "gw_subnet" {
  name                 = "AppGatewaySubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.app_vnet.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "app_subnet" {
  name                 = "AppServiceSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.app_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
  delegation {
    name = "appServiceDelegation"

    service_delegation {
      actions = [
            "Microsoft.Network/virtualNetworks/subnets/action",
            "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
      name    = "Microsoft.Web/serverFarms"
    }
  }
}

resource "azurerm_subnet" "app_subnet_pep" {
  name                 = "AppServiceSubnetPep"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.app_vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Subnet for SQL VNet
resource "azurerm_subnet" "sql_subnet" {
  name                 = "SQLSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.sql_vnet.name
  address_prefixes     = ["10.1.1.0/24"]
}

# Network Security Groups
resource "azurerm_network_security_group" "app_nsg" {
  name                = "app-vnet-nsg-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowAppService"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowInternal"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/16"
    destination_address_prefix = "10.0.0.0/16"
  }
}

resource "azurerm_network_security_group" "sql_nsg" {
  name                = "sql-vnet-nsg-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowSQL"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "10.0.0.0/16"
    destination_address_prefix = "VirtualNetwork"
  }
}

# Associate NSGs with subnets
resource "azurerm_subnet_network_security_group_association" "app_nsg_assoc" {
  for_each = {
    app = azurerm_subnet.app_subnet.id
    pep = azurerm_subnet.app_subnet_pep.id
  }
  
  subnet_id                 = each.value
  network_security_group_id = azurerm_network_security_group.app_nsg.id
}

resource "azurerm_subnet_network_security_group_association" "sql_nsg_assoc" {
  subnet_id                 = azurerm_subnet.sql_subnet.id
  network_security_group_id = azurerm_network_security_group.sql_nsg.id
}

# Azure Firewall
resource "azurerm_public_ip" "fw_pip" {
  name                = "fw-public-ip-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_firewall_policy" "main" {
  name                = "app-firewall-policy-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
}

resource "azurerm_firewall" "main" {
  name                = "app-firewall-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_tier            = "Standard"
  sku_name            = "AZFW_VNet"
  firewall_policy_id = azurerm_firewall_policy.main.id

    # Data plane configuration
  ip_configuration {
    name                 = "fw-ip-config"
    subnet_id            = azurerm_subnet.fw_subnet.id
    public_ip_address_id = azurerm_public_ip.fw_pip.id
  }

  # Management plane configuration
  management_ip_configuration {
    name                 = "fw-mgmt-config"
    subnet_id            = azurerm_subnet.fw_management_subnet.id
    public_ip_address_id = azurerm_public_ip.fw_mgmt_pip.id
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "main" {
  name               = "app-fw-policy-group"
  firewall_policy_id = azurerm_firewall_policy.main.id
  priority           = 500

  # Application Rules
  application_rule_collection {
    name     = "app-services-rules"
    priority = 500
    action   = "Allow"

    rule {
      name = "allow-azure-services"

      protocols {
        port = 443
        type = "Https"
      }

      protocols {
        port = 80
        type = "Http"
      }

      source_addresses  = ["10.0.0.0/16", "10.1.0.0/16"]
      destination_fqdns = ["*.azure.com", "*.microsoft.com", "*.windows.net"]
    }

    rule {
      name = "allow-app-outbound"

      protocols {
        port = 443
        type = "Https"
      }

      source_addresses  = ["10.0.1.0/24"] # App Service Subnet
      destination_fqdns = ["*"]
    }
  }

  # Network Rules
  network_rule_collection {
    name     = "internal-routing-rules"
    priority = 400
    action   = "Allow"

    rule {
      name                  = "to-load-balancer"
      protocols             = ["TCP"]
      source_addresses      = ["10.0.100.0/24"] # FW Data Subnet
      destination_addresses = ["10.0.0.0/24"] # AGW Subnet
      destination_ports     = ["80", "443"]
    }

    rule {
      name                  = "to-sql-vnet"
      protocols             = ["TCP"]
      source_addresses      = ["10.0.0.0/16"]
      destination_addresses = ["10.1.1.0/24"] # SQL Subnet
      destination_ports     = ["1433"]
    }
  }

  # DNAT Rule Collection for HTTPS traffic
  nat_rule_collection {
    name     = "inbound-https"
    priority = 100
    action   = "Dnat"
    
    rule {
      name                = "https-to-agw"
      source_addresses    = ["*"]  # Or restrict to specific IPs
      destination_address = azurerm_public_ip.fw_pip.ip_address
      destination_ports   = ["80"]
      translated_address  = azurerm_application_gateway.troubleshooting.frontend_ip_configuration[1].private_ip_address
      translated_port     = 80
      protocols           = ["TCP"]
    }
  }
}

resource "azurerm_route_table" "fw_rt" {
  name                = "firewall-route-table-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  route {
    name           = "DefaultToInternet"
    address_prefix = "0.0.0.0/0"
    next_hop_type  = "Internet"
  }
}

# 5. Associate Route Table with Firewall Subnets
resource "azurerm_subnet_route_table_association" "fw_data_rt" {
  subnet_id      = azurerm_subnet.fw_subnet.id
  route_table_id = azurerm_route_table.fw_rt.id
}

resource "azurerm_public_ip" "fw_mgmt_pip" {
  name                = "fw-mgmt-public-ip-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# App Service Plan
resource "azurerm_service_plan" "main" {
  name                = "app-service-plan-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "B1"
}

# App Services with private access disabled
resource "azurerm_linux_web_app" "app1" {
  name                = "app1-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id

  site_config {
    always_on = true
    application_stack {
      php_version = "8.2"  # Use PHP 8.2
    }
    vnet_route_all_enabled = true  # Route all traffic through VNet
    health_check_path = "/"
    health_check_eviction_time_in_min = "2"
  }

  app_settings = {
    # SQL Connection settings
    SQL_SERVER_NAME     = "${azurerm_mssql_server.sql.name}.privatelink.database.windows.net"
    SQL_DATABASE_NAME   = azurerm_mssql_database.main.name
    SQL_UID             = azurerm_mssql_server.sql.administrator_login
    SQL_PWD             = "P@ssw0rd123!"
  }
  identity {
    type = "SystemAssigned"
  }

  public_network_access_enabled = false
}

resource "azurerm_app_service_virtual_network_swift_connection" "app1_vnet_int" {
  app_service_id = azurerm_linux_web_app.app1.id
  subnet_id      = azurerm_subnet.app_subnet.id
}

resource "azurerm_linux_web_app" "app2" {
  name                = "app2-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id

  site_config {
    always_on = true
    application_stack {
      php_version = "8.2"  # Use PHP 8.2
    }
    vnet_route_all_enabled = true  # Route all traffic through VNet
    health_check_path = "/"
    health_check_eviction_time_in_min = "2"
  }

  app_settings = {
    # SQL Connection settings
    SQL_SERVER_NAME     = "${azurerm_mssql_server.sql.name}.privatelink.database.windows.net"
    SQL_DATABASE_NAME   = azurerm_mssql_database.main.name
    SQL_UID             = azurerm_mssql_server.sql.administrator_login
    SQL_PWD             = "P@ssw0rd123!"
  }
  identity {
    type = "SystemAssigned"
  }
  public_network_access_enabled = false
}

resource "azurerm_app_service_virtual_network_swift_connection" "app2_vnet_int" {
  app_service_id = azurerm_linux_web_app.app2.id
  subnet_id      = azurerm_subnet.app_subnet.id
}

resource "azurerm_public_ip" "agw_pip" {
  name                = "agw-public-ip-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_application_gateway" "troubleshooting" {
  name                = "troubleshooting"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku {
    name     = "Basic"
    tier     = "Basic"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.gw_subnet.id
  }

  frontend_port {
    name = "port_80"
    port = 80
  }

  # Public frontend (Internet-facing)
  frontend_ip_configuration {
    name                 = "appGwPublicFrontendIpIPv4"
    public_ip_address_id = azurerm_public_ip.agw_pip.id
  }

  # Private frontend (Internal/VNet)
  frontend_ip_configuration {
    name                          = "appGwPrivateFrontendIpIPv4"
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.4"
    subnet_id                     = azurerm_subnet.gw_subnet.id
  }

  backend_address_pool {
    name  = "troubleshootingBackend"
    fqdns = [azurerm_linux_web_app.app1.default_hostname,azurerm_linux_web_app.app2.default_hostname]
  }

  backend_http_settings {
    name                                = "fgvdfb"
    port                                = 80
    protocol                            = "Http"
    cookie_based_affinity               = "Disabled"
    pick_host_name_from_backend_address = true
    request_timeout                     = 20
    probe_name                          = "hgfdfgh"
  }

  probe {
    name                                      = "hgfdfgh"
    protocol                                  = "Http"
    path                                      = "/"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
    match {
      status_code = ["200-399"]
    }
  }

  http_listener {
    name                           = "gdbhg"
    frontend_ip_configuration_name = "appGwPrivateFrontendIpIPv4"
    frontend_port_name             = "port_80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "gdvrv"
    rule_type                  = "Basic"
    priority                   = 1
    http_listener_name         = "gdbhg"
    backend_address_pool_name  = "troubleshootingBackend"
    backend_http_settings_name = "fgvdfb"
  }

  # Enable HTTP/2
  enable_http2 = true

  # Zones configuration
  zones = ["1", "2", "3"]
}

# SQL Server with private access disabled
resource "azurerm_mssql_server" "sql" {
  name                         = "sql-server-${random_string.suffix.result}"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = "P@ssw0rd123!" # Use Key Vault in production
  public_network_access_enabled = false
}

resource "azurerm_mssql_database" "main" {
  name        = "app-database"
  server_id   = azurerm_mssql_server.sql.id
  sku_name    = "S0"  # Standard tier, 10 DTUs
  max_size_gb = 10
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  transparent_data_encryption_enabled = true
  depends_on = [azurerm_mssql_server.sql]
}

# Private DNS Zones
resource "azurerm_private_dns_zone" "app_services" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone" "sql_server" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

# Link DNS Zones to VNets
resource "azurerm_private_dns_zone_virtual_network_link" "app_dns_link_app" {
  name                  = "app-dns-link-app"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.app_services.name
  virtual_network_id    = azurerm_virtual_network.app_vnet.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "app_dns_link_sql" {
  name                  = "app-dns-link-sql"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.app_services.name
  virtual_network_id    = azurerm_virtual_network.sql_vnet.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql_dns_link_app" {
  name                  = "sql-dns-link-app"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql_server.name
  virtual_network_id    = azurerm_virtual_network.app_vnet.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql_dns_link_sql" {
  name                  = "sql-dns-link-sql"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql_server.name
  virtual_network_id    = azurerm_virtual_network.sql_vnet.id
}

# Private Endpoints
## App Service Private Endpoints
resource "azurerm_private_endpoint" "app1_pe" {
  name                = "app1-private-endpoint"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.app_subnet_pep.id

  private_service_connection {
    name                           = "app1-psc"
    private_connection_resource_id = azurerm_linux_web_app.app1.id
    is_manual_connection           = false
    subresource_names              = ["sites"]
  }

  private_dns_zone_group {
    name                 = "app-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.app_services.id]
  }
}

resource "azurerm_private_endpoint" "app2_pe" {
  name                = "app2-private-endpoint"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.app_subnet_pep.id

  private_service_connection {
    name                           = "app2-psc"
    private_connection_resource_id = azurerm_linux_web_app.app2.id
    is_manual_connection           = false
    subresource_names              = ["sites"]
  }

  private_dns_zone_group {
    name                 = "app-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.app_services.id]
  }
}

## SQL Server Private Endpoint
resource "azurerm_private_endpoint" "sql_pe" {
  name                = "sql-private-endpoint"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.sql_subnet.id

  private_service_connection {
    name                           = "sql-psc"
    private_connection_resource_id = azurerm_mssql_server.sql.id
    is_manual_connection           = false
    subresource_names              = ["sqlServer"]
  }

  private_dns_zone_group {
    name                 = "sql-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql_server.id]
  }
}

# VNet Peering
resource "azurerm_virtual_network_peering" "app_to_sql" {
  name                      = "app-to-sql-peering"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.app_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.sql_vnet.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "sql_to_app" {
  name                      = "sql-to-app-peering"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.sql_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.app_vnet.id
  allow_forwarded_traffic   = true
}

# Outputs
output "app_service1_name" {
  value = azurerm_linux_web_app.app1.name
}

output "app_service2_name" {
  value = azurerm_linux_web_app.app2.name
}

output "sql_server_name" {
  value = azurerm_mssql_server.sql.name
}

output "firewall_private_ip" {
  value = azurerm_firewall.main.ip_configuration[0].private_ip_address
}

output "app_gateway_private_ip" {
  value = azurerm_application_gateway.troubleshooting.frontend_ip_configuration[0].private_ip_address
}

output "private_dns_zone_app" {
  value = azurerm_private_dns_zone.app_services.name
}

output "private_dns_zone_sql" {
  value = azurerm_private_dns_zone.sql_server.name
}